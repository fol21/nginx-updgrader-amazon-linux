<#
.SYNOPSIS
    Updates nginx to a target version on AWS EC2 instances via SSH.

.DESCRIPTION
    Lists running EC2 instances with the AWS CLI (or targets a single IP), then
    runs a verification stage (SSH read-only: current nginx version vs target),
    asks for confirmation, and only then writes the embedded remote script
    to a temp file and copies it over SSH to install/upgrade nginx (default: 1.30.6).

    Requires:
      - AWS CLI authenticated with permissions for ec2:DescribeInstances
      - OpenSSH client (ssh + scp) available in PATH
      - PEM private key that can reach the instances (-i)
      - Network path from this machine to the instances (public IP or VPN)

.PARAMETER InstanceIp
    Optional. When set, only this IP is updated.

.PARAMETER PemFile
    Path to the SSH private key (.pem). Passed to ssh/scp -i.

.PARAMETER SshUser
    SSH username. Default: ec2-user (Amazon Linux). Use ubuntu for Ubuntu AMIs.

.PARAMETER Region
    AWS region for describe-instances. Falls back to your AWS CLI default
    (env / config — same priority chain as the AWS CLI).

.PARAMETER NginxVersion
    Target nginx version. Default: 1.30.6

.PARAMETER UsePublicIp
    Connect via public IP instead of private (default is private IP).

.PARAMETER SkipAwsLookup
    With -InstanceIp, skip AWS CLI and SSH straight to that IP.

.PARAMETER DryRun
    Run verification (SSH version check) and stop before any update.

.PARAMETER Force
    Skip the interactive confirmation after the verification table.

.PARAMETER Restart
    After a successful update/repair, restart nginx on the host (systemctl restart).

.PARAMETER LogPath
    Optional path for the verification log. Default: .\logs\nginx-verify-<timestamp>.log

.EXAMPLE
    .\Update-Nginx.ps1 -PemFile C:\keys\my-key.pem

.EXAMPLE
    .\Update-Nginx.ps1 -PemFile ./my-key.pem -InstanceIp 54.1.2.3 -SshUser ubuntu

.EXAMPLE
    .\Update-Nginx.ps1 -PemFile ./my-key.pem -Region us-east-1 -DryRun
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$InstanceIp,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
            if (-not (Test-Path -LiteralPath $_)) {
                throw "PEM file not found: $_"
            }
            $true
        })]
    [string]$PemFile,

    [Parameter()]
    [string]$SshUser = "ec2-user",

    [Parameter()]
    [string]$Region = "sa-east-1",

    [Parameter()]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$NginxVersion = "1.30.6",

    [Parameter()]
    [switch]$UsePublicIp,

    [Parameter()]
    [switch]$SkipAwsLookup,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$Restart,

    [Parameter()]
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-EmbeddedRemoteUpdateScript {
    # Bash payload for the remote host (single-quoted here-string: no PS expansion)
    return @'
#!/usr/bin/env bash
# Installs/upgrades nginx to a specific version on Debian/Ubuntu or RHEL/Amazon Linux.
# Keep in sync with .ebextensions/upgrade-nginx.sh (Elastic Beanstalk uses that copy).
# Usage: sudo bash remote-update-nginx.sh [VERSION] [restart|norestart] (written to temp by Update-Nginx.ps1)
set -euo pipefail

TARGET="${1:-1.30.6}"
DO_RESTART="${2:-norestart}"

echo "=== Host: $(hostname) ==="
echo "=== Target nginx version: ${TARGET} ==="
echo "=== Current nginx (if any) ==="
nginx -v 2>&1 || true

# shellcheck source=/dev/null
. /etc/os-release

write_nginx_apt_repo() {
  local channel="$1" # stable | mainline
  local distro="${ID:-ubuntu}"
  local codename="${VERSION_CODENAME:-}"
  if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -cs)"
  fi
  codename="${codename:-jammy}"

  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

  local packages_distro="ubuntu"
  if [[ "$distro" == "debian" ]]; then
    packages_distro="debian"
  fi

  local path_prefix=""
  if [[ "$channel" == "mainline" ]]; then
    path_prefix="mainline/"
  fi

  cat > /etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${path_prefix}${packages_distro} ${codename} nginx
EOF
}

install_debian() {
  export DEBIAN_FRONTEND=noninteractive

  try_apt_install() {
    apt-get update -qq
    local candidate
    candidate="$(apt-cache madison nginx 2>/dev/null | awk -v v="$TARGET" '$2 ~ "^"v {print $2; exit}')"
    if [[ -z "$candidate" ]]; then
      return 1
    fi
    echo "Installing nginx=${candidate}"
    apt-get install -y "nginx=${candidate}"
  }

  echo "Configuring nginx.org apt repository (stable)..."
  write_nginx_apt_repo stable
  if try_apt_install; then
    return 0
  fi

  echo "nginx ${TARGET} not in stable apt repo - retrying with mainline..."
  write_nginx_apt_repo mainline
  if try_apt_install; then
    return 0
  fi

  echo "ERROR: nginx ${TARGET} not found in apt cache (stable + mainline). Available:" >&2
  apt-cache madison nginx 2>/dev/null | head -20 >&2 || true
  exit 2
}

# Resolve nginx.org yum base paths for this OS.
# AL2023 packages live under amzn/2023/ (stable has 1.30.x).
nginx_yum_urls() {
  local channel="$1" # stable | mainline
  local prefix=""
  if [[ "$channel" == "mainline" ]]; then
    prefix="mainline/"
  fi

  case "${ID:-}" in
    amzn)
      if [[ "${VERSION_ID:-}" == 2 ]]; then
        echo "https://nginx.org/packages/${prefix}amzn2/\$releasever/\$basearch/"
      else
        # Pin major (2023) - $releasever is unreliable on some AL2023 images
        local ver="${VERSION_ID%%.*}"
        ver="${ver:-2023}"
        echo "https://nginx.org/packages/${prefix}amzn/${ver}/\$basearch/"
      fi
      ;;
    rhel|centos|rocky|almalinux|ol)
      echo "https://nginx.org/packages/${prefix}rhel/\$releasever/\$basearch/"
      ;;
    *)
      echo "https://nginx.org/packages/${prefix}centos/\$releasever/\$basearch/"
      ;;
  esac
}

write_nginx_yum_repo() {
  local enable_mainline="${1:-0}"
  local stable_url mainline_url
  stable_url="$(nginx_yum_urls stable)"
  mainline_url="$(nginx_yum_urls mainline)"

  cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=${stable_url}
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=${mainline_url}
gpgcheck=1
enabled=${enable_mainline}
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
  echo "Wrote /etc/yum.repos.d/nginx.repo (mainline enabled=${enable_mainline})"
  echo "  stable:   ${stable_url}"
  echo "  mainline: ${mainline_url}"
}

# Amazon Linux ships nginx-core / nginx-mimetypes which conflict with nginx.org's nginx
# (package Provides + file /etc/nginx/mime.types). Remove them before nginx.org install.
dnf_install_flags() {
  echo "--allowerasing"
}

NGINX_CFG_BACKUP=""

backup_nginx_config() {
  if [[ ! -d /etc/nginx ]]; then
    NGINX_CFG_BACKUP=""
    return 0
  fi
  NGINX_CFG_BACKUP="/var/tmp/nginx-cfg-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$NGINX_CFG_BACKUP"
  cp -a /etc/nginx/. "$NGINX_CFG_BACKUP/"
  echo "Backed up /etc/nginx -> ${NGINX_CFG_BACKUP}"
}

# nginx.org ships conf.d/default.conf (welcome page) which steals :80 from proxy.conf.
repair_nginx_site_config() {
  local backup="${1:-${NGINX_CFG_BACKUP:-}}"

  echo "Restoring site config and removing nginx.org welcome page..."

  if [[ -n "$backup" && -d "$backup" ]]; then
    if [[ -f "$backup/nginx.conf" ]]; then
      cp -a "$backup/nginx.conf" /etc/nginx/nginx.conf
    fi
    local dir
    for dir in conf.d default.d sites-enabled sites-available conf.http.d; do
      if [[ -d "$backup/$dir" ]]; then
        mkdir -p "/etc/nginx/$dir"
        cp -a "$backup/$dir/." "/etc/nginx/$dir/"
      fi
    done
  elif [[ -f /etc/nginx/nginx.conf.rpmsave ]]; then
    echo "Restoring nginx.conf from nginx.conf.rpmsave"
    cp -a /etc/nginx/nginx.conf.rpmsave /etc/nginx/nginx.conf
  fi

  if [[ -d /etc/nginx/conf.d ]]; then
    local f
    for f in /etc/nginx/conf.d/*.rpmsave; do
      [[ -e "$f" ]] || continue
      local live="${f%.rpmsave}"
      if [[ ! -f "$live" ]]; then
        echo "Restoring $(basename "$live") from rpmsave"
        cp -a "$f" "$live"
      fi
    done
  fi

  # Always drop the stock welcome vhost so proxy.conf / custom vhosts win
  rm -f /etc/nginx/conf.d/default.conf

  if command -v nginx >/dev/null 2>&1; then
    nginx -t
  fi
}

remove_amazon_nginx_pkgs() {
  local pkg_mgr="$1"
  # Only strip amazonlinux-split packages (file conflict on /etc/nginx/mime.types)
  local to_remove=()
  local pkg
  for pkg in nginx nginx-core nginx-mimetypes nginx-filesystem; do
    if "$pkg_mgr" list installed "$pkg" >/dev/null 2>&1; then
      to_remove+=("$pkg")
    fi
  done

  if [[ ${#to_remove[@]} -eq 0 ]]; then
    return 0
  fi

  echo "Removing Amazon Linux nginx packages to avoid file conflicts: ${to_remove[*]}"
  "$pkg_mgr" remove -y "${to_remove[@]}" || true
}

# nginx.org amzn2023 RPMs need libssl.so.3(OPENSSL_3.5.0); older AL2023 images ship 3.0/3.2.
ensure_openssl_for_nginx_org() {
  local pkg_mgr="$1"

  if [[ "${ID:-}" != "amzn" || "${VERSION_ID:-}" == "2" ]]; then
    return 0
  fi

  if rpm -q --provides openssl-libs 2>/dev/null | grep -q 'OPENSSL_3\.5\.0'; then
    echo "openssl-libs already provides OPENSSL_3.5.0"
    return 0
  fi

  echo "nginx.org needs OPENSSL_3.5.0 - updating openssl / openssl-libs from Amazon Linux repos..."
  if ! "$pkg_mgr" update -y openssl openssl-libs; then
    echo "WARNING: openssl update failed" >&2
    return 1
  fi

  if rpm -q --provides openssl-libs 2>/dev/null | grep -q 'OPENSSL_3\.5\.0'; then
    echo "openssl-libs now provides OPENSSL_3.5.0"
    return 0
  fi

  echo "WARNING: OPENSSL_3.5.0 still missing after update (refresh the AL2023 AMI / repos)" >&2
  return 1
}

# Stay on amazonlinux packages when possible (nginx / nginx-core).
try_amazon_nginx() {
  local pkg_mgr="$1"
  local flags
  flags="$(dnf_install_flags "$pkg_mgr")"

  echo "Trying Amazon Linux packages for nginx ${TARGET}..."
  local spec
  for spec in "nginx-core-${TARGET}*" "nginx-${TARGET}*" "nginx-core-${TARGET}" "nginx-${TARGET}"; do
    if "$pkg_mgr" list available "$spec" 2>/dev/null | grep -qiE 'nginx'; then
      echo "Installing ${spec} from distro repos..."
      # shellcheck disable=SC2086
      if "$pkg_mgr" install -y $flags "$spec"; then
        return 0
      fi
    fi
  done
  return 1
}

try_dnf_install() {
  local pkg_mgr="$1"
  local flags
  flags="$(dnf_install_flags "$pkg_mgr")"
  local spec=""

  # Prefer wildcard NEVRA match (nginx-1.30.6-1.amzn2023.ngx.x86_64)
  if "$pkg_mgr" list available "nginx-${TARGET}*" 2>/dev/null | grep -qiE 'nginx'; then
    spec="nginx-${TARGET}*"
  else
    spec="nginx-${TARGET}"
  fi

  echo "Resolving deps for ${spec} (downloadonly, before removing distro nginx)..."
  # shellcheck disable=SC2086
  if ! "$pkg_mgr" install -y --downloadonly $flags "$spec"; then
    echo "Cannot install ${spec} (deps unresolved - often OPENSSL_3.5.0 on old AL2023)" >&2
    return 1
  fi

  remove_amazon_nginx_pkgs "$pkg_mgr"

  echo "Installing ${spec} from nginx.org..."
  # shellcheck disable=SC2086
  if "$pkg_mgr" install -y $flags "$spec"; then
    return 0
  fi
  return 1
}

# Last resort: install the RPM straight from nginx.org (AL2023 / RHEL9 patterns).
try_direct_rpm() {
  local pkg_mgr="$1"
  local flags
  flags="$(dnf_install_flags "$pkg_mgr")"
  local arch
  arch="$(uname -m)"
  local candidates=()

  case "${ID:-}" in
    amzn)
      if [[ "${VERSION_ID:-}" != 2 ]]; then
        local ver="${VERSION_ID%%.*}"
        ver="${ver:-2023}"
        candidates+=(
          "https://nginx.org/packages/amzn/${ver}/${arch}/RPMS/nginx-${TARGET}-1.amzn${ver}.ngx.${arch}.rpm"
          "https://nginx.org/packages/mainline/amzn/${ver}/${arch}/RPMS/nginx-${TARGET}-1.amzn${ver}.ngx.${arch}.rpm"
        )
      fi
      ;;
    *)
      candidates+=(
        "https://nginx.org/packages/rhel/9/${arch}/RPMS/nginx-${TARGET}-1.el9.ngx.${arch}.rpm"
        "https://nginx.org/packages/mainline/rhel/9/${arch}/RPMS/nginx-${TARGET}-1.el9.ngx.${arch}.rpm"
      )
      ;;
  esac

  local url
  for url in "${candidates[@]}"; do
    echo "Trying direct RPM: ${url}"
    if ! curl -fsI "$url" >/dev/null 2>&1; then
      continue
    fi
    # Resolve deps before removing distro nginx
    # shellcheck disable=SC2086
    if ! "$pkg_mgr" install -y --downloadonly $flags "$url"; then
      echo "Direct RPM deps unresolved for ${url}" >&2
      continue
    fi
    remove_amazon_nginx_pkgs "$pkg_mgr"
    # shellcheck disable=SC2086
    if "$pkg_mgr" install -y $flags "$url"; then
      return 0
    fi
  done
  return 1
}

install_rhel() {
  local pkg_mgr
  pkg_mgr="$(command -v dnf || command -v yum)"

  backup_nginx_config

  # 1) Prefer distro package (amazonlinux nginx-core) when TARGET exists there
  if try_amazon_nginx "$pkg_mgr"; then
    repair_nginx_site_config "$NGINX_CFG_BACKUP"
    return 0
  fi

  # 2) nginx.org amzn2023 builds need OPENSSL_3.5.0
  ensure_openssl_for_nginx_org "$pkg_mgr" || true

  # 3) nginx.org stable - replace conflicting nginx-core via --allowerasing
  echo "Configuring nginx.org yum repository (stable)..."
  write_nginx_yum_repo 0
  "$pkg_mgr" -q makecache --refresh || "$pkg_mgr" makecache -q || true

  if try_dnf_install "$pkg_mgr"; then
    repair_nginx_site_config "$NGINX_CFG_BACKUP"
    return 0
  fi

  echo "nginx ${TARGET} not found via stable - enabling official mainline repo and retrying..."
  write_nginx_yum_repo 1
  "$pkg_mgr" -q makecache --refresh || "$pkg_mgr" makecache -q || true

  if try_dnf_install "$pkg_mgr"; then
    repair_nginx_site_config "$NGINX_CFG_BACKUP"
    return 0
  fi

  echo "Repo install failed - trying direct RPM from nginx.org..."
  if try_direct_rpm "$pkg_mgr"; then
    repair_nginx_site_config "$NGINX_CFG_BACKUP"
    return 0
  fi

  echo "ERROR: could not install nginx ${TARGET} via ${pkg_mgr}" >&2
  if [[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" != "2" ]]; then
    echo "Hint: nginx.org 1.30.x for AL2023 needs libssl OPENSSL_3.5.0 (dnf update openssl openssl-libs, or a newer AL2023 AMI)." >&2
  fi
  echo "Available nginx packages (sample):" >&2
  "$pkg_mgr" list available 'nginx*' 2>/dev/null | head -40 >&2 || true
  exit 2
}

# If already on target version, only fix site config (welcome page / lost includes).
already_on_target() {
  command -v nginx >/dev/null 2>&1 || return 1
  local installed
  installed="$(nginx -v 2>&1 | sed -n 's/.*nginx\///p')"
  [[ "$installed" == ${TARGET}* ]]
}

if already_on_target; then
  echo "nginx ${TARGET} already installed - repairing site config only"
  backup_nginx_config
  repair_nginx_site_config "$NGINX_CFG_BACKUP"
else
  if command -v apt-get >/dev/null 2>&1; then
    install_debian
    rm -f /etc/nginx/conf.d/default.conf
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    install_rhel
  else
    echo "ERROR: unsupported OS (need apt-get or yum/dnf)" >&2
    exit 3
  fi
fi

echo "=== Installed version ==="
nginx -v 2>&1

INSTALLED="$(nginx -v 2>&1 | sed -n 's/.*nginx\///p')"
if [[ "$INSTALLED" != ${TARGET}* ]]; then
  echo "ERROR: expected nginx ${TARGET}*, got ${INSTALLED:-unknown}" >&2
  exit 4
fi

if [[ "$DO_RESTART" == "restart" ]]; then
  echo "=== Restarting nginx (-Restart) ==="
  if nginx -t && systemctl restart nginx && systemctl is-active nginx; then
    echo "nginx restarted OK"
  else
    echo "WARNING: nginx restart failed - package/config update still succeeded" >&2
  fi
else
  echo "=== Skipping nginx restart (pass restart / use -Restart to enable) ==="
fi

echo "OK"
'@
}

function New-TempRemoteUpdateScript {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-update-nginx-{0}.sh" -f [guid]::NewGuid().ToString('N'))
    $content = Get-EmbeddedRemoteUpdateScript
    # Force LF with char codes (avoid `r/`n escapes that break when this .ps1 is regenerated)
    $lf = [string][char]10
    $cr = [string][char]13
    $normalized = $content.Replace($cr + $lf, $lf).Replace($cr, $lf)
    if (-not $normalized.EndsWith($lf)) { $normalized += $lf }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllBytes($path, $utf8NoBom.GetBytes($normalized))
    return $path
}

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-WarnStep {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-ErrStep {
    param([string]$Message)
    Write-Host "[-] $Message" -ForegroundColor Red
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-AwsExtraArgs {
    # No --profile: aws CLI uses its normal chain (AWS_PROFILE, default profile, SSO, etc.)
    $extra = [System.Collections.Generic.List[string]]::new()
    if ($Region) {
        $extra.Add("--region")
        $extra.Add($Region)
    }
    return $extra
}

function Get-Ec2Targets {
    param(
        [string]$FilterIp,
        [bool]$PreferPublicIp
    )

    $awsArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($a in (Get-AwsExtraArgs)) { $awsArgs.Add($a) }

    $awsArgs.Add("ec2")
    $awsArgs.Add("describe-instances")
    $awsArgs.Add("--filters")
    $awsArgs.Add("Name=instance-state-name,Values=running")
    $awsArgs.Add("--query")
    # Object shape avoids PS 5.1 unwrapping a single nested array into scalars (null[0] crash)
    $awsArgs.Add("Reservations[].Instances[].{InstanceId:InstanceId,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress,Name:Tags[?Key=='Name']|[0].Value,Platform:PlatformDetails}")
    $awsArgs.Add("--output")
    $awsArgs.Add("json")

    Write-Step "Querying running EC2 instances via AWS CLI..."
    $raw = & aws @($awsArgs.ToArray()) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "aws ec2 describe-instances failed:`n$raw"
    }

    $jsonText = if ($raw -is [System.Array]) { ($raw | ForEach-Object { "$_" }) -join "`n" } else { "$raw" }
    if ([string]::IsNullOrWhiteSpace($jsonText) -or $jsonText.Trim() -eq "null") {
        return @()
    }

    $parsed = $jsonText | ConvertFrom-Json
    $rows = @($parsed)
    if ($rows.Count -eq 0) {
        return @()
    }

    $targets = foreach ($row in $rows) {
        if ($null -eq $row) { continue }

        $id = [string]$row.InstanceId
        $publicIp = if ($null -ne $row.PublicIp -and "$($row.PublicIp)" -ne "") { [string]$row.PublicIp } else { $null }
        $privateIp = if ($null -ne $row.PrivateIp -and "$($row.PrivateIp)" -ne "") { [string]$row.PrivateIp } else { $null }
        $name = if ($null -ne $row.Name -and "$($row.Name)" -ne "") { [string]$row.Name } else { "(unnamed)" }
        $platform = if ($null -ne $row.Platform -and "$($row.Platform)" -ne "") { [string]$row.Platform } else { "unknown" }

        # Default: private IP (VPN / same VPC). Public only with -UsePublicIp.
        $connectIp = if ($PreferPublicIp) {
            if ($publicIp) { $publicIp } elseif ($privateIp) { $privateIp } else { $null }
        }
        else {
            if ($privateIp) { $privateIp } elseif ($publicIp) { $publicIp } else { $null }
        }

        if (-not $connectIp) {
            Write-WarnStep "Skipping $id ($name): no reachable IP"
            continue
        }

        if (-not $PreferPublicIp -and $connectIp -eq $publicIp -and $privateIp -eq $null) {
            Write-WarnStep "$id ($name): no private IP; falling back to public $publicIp"
        }

        [PSCustomObject]@{
            InstanceId = $id
            Name       = $name
            PublicIp   = $publicIp
            PrivateIp  = $privateIp
            ConnectIp  = $connectIp
            Platform   = $platform
        }
    }

    if ($FilterIp) {
        $matched = @($targets | Where-Object {
                $_.ConnectIp -eq $FilterIp -or
                $_.PublicIp -eq $FilterIp -or
                $_.PrivateIp -eq $FilterIp
            })
        if ($matched.Count -eq 0) {
            throw "No running instance found with IP '$FilterIp'. Use -SkipAwsLookup to SSH anyway."
        }
        return $matched
    }

    return @($targets)
}

function Get-SshBaseArgs {
    param([string]$KeyPath)
    return @(
        "-i", $KeyPath,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=15",
        "-o", "BatchMode=yes"
    )
}

function Get-RemoteNginxVersion {
    param(
        [PSCustomObject]$Target,
        [string]$KeyPath,
        [string]$User
    )

    $sshBase = Get-SshBaseArgs -KeyPath $KeyPath
    $dest = "${User}@$($Target.ConnectIp)"
    # Read-only: report installed version or mark missing/unreachable
    $remoteCmd = 'if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1; else echo nginx-not-installed; fi'

    try {
        $output = & ssh @($sshBase + @($dest, $remoteCmd)) 2>&1
        $exit = $LASTEXITCODE
        $text = (($output | Out-String) -replace "`r", "").Trim()

        if ($exit -ne 0) {
            return [PSCustomObject]@{
                CurrentVersion = "(unreachable)"
                Reachable      = $false
                Raw            = $text
            }
        }

        if ($text -match 'nginx-not-installed') {
            return [PSCustomObject]@{
                CurrentVersion = "(not installed)"
                Reachable      = $true
                Raw            = $text
            }
        }

        if ($text -match 'nginx/([\d.]+)') {
            $version = $Matches[1]
            return [PSCustomObject]@{
                CurrentVersion = $version
                Reachable      = $true
                Raw            = $text
            }
        }

        return [PSCustomObject]@{
            CurrentVersion = "(unknown)"
            Reachable      = $true
            Raw            = $text
        }
    }
    catch {
        return [PSCustomObject]@{
            CurrentVersion = "(unreachable)"
            Reachable      = $false
            Raw            = "$_"
        }
    }
}

function Get-UpdateAction {
    param(
        [string]$CurrentVersion,
        [string]$TargetVersion,
        [bool]$Reachable
    )

    if (-not $Reachable) { return "SkipUnreachable" }
    if ($CurrentVersion -eq "(not installed)") { return "Install" }
    if ($CurrentVersion -eq "(unknown)") { return "Upgrade" }
    if ($CurrentVersion -eq $TargetVersion) { return "AlreadyCurrent" }
    return "Upgrade"
}

function Invoke-VerificationStage {
    param(
        [object[]]$Targets,
        [string]$KeyPath,
        [string]$User,
        [string]$TargetVersion,
        [string]$VerificationLogPath
    )

    Write-Step "Verification stage: probing current nginx version on each host..."

    $rows = @(foreach ($t in $Targets) {
        Write-Host "  probing $($t.ConnectIp) ..." -ForegroundColor DarkGray
        $probe = Get-RemoteNginxVersion -Target $t -KeyPath $KeyPath -User $User
        $action = Get-UpdateAction -CurrentVersion $probe.CurrentVersion -TargetVersion $TargetVersion -Reachable:$probe.Reachable

        [PSCustomObject]@{
            InstanceId     = $t.InstanceId
            Name           = $t.Name
            Ip             = $t.ConnectIp
            CurrentVersion = $probe.CurrentVersion
            TargetVersion  = $TargetVersion
            Action         = $action
            Reachable      = $probe.Reachable
            Target         = $t
        }
    })

    Write-Host ""
    Write-Host "Verification — current vs target nginx:" -ForegroundColor White
    # Out-Host: Format-Table must not enter the function return pipeline
    $rows | Format-Table Ip, Name, CurrentVersion, TargetVersion, Action -AutoSize | Out-Host

    $logDir = Split-Path -Parent $VerificationLogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLines = @(
        "nginx upgrade verification — $stamp"
        "target version: $TargetVersion"
        "hosts: $($rows.Count)"
        ""
        ("{0,-16} {1,-24} {2,-16} {3,-14} {4}" -f "IP", "Name", "Current", "Target", "Action")
        ("{0,-16} {1,-24} {2,-16} {3,-14} {4}" -f ("-" * 15), ("-" * 23), ("-" * 15), ("-" * 13), ("-" * 16))
    )
    foreach ($r in $rows) {
        $logLines += ("{0,-16} {1,-24} {2,-16} {3,-14} {4}" -f $r.Ip, $r.Name, $r.CurrentVersion, $r.TargetVersion, $r.Action)
    }
    $logLines | Set-Content -LiteralPath $VerificationLogPath -Encoding UTF8
    Write-Ok "Verification log: $VerificationLogPath"

    return ,$rows
}

function Confirm-UpgradeExecution {
    param(
        [object[]]$VerificationRows,
        [bool]$SkipPrompt
    )

    $rows = @($VerificationRows | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Action'] })
    $toUpdate = @($rows | Where-Object { $_.Action -in @("Install", "Upgrade", "AlreadyCurrent") })
    $already = @($rows | Where-Object { $_.Action -eq "AlreadyCurrent" })
    $unreachable = @($rows | Where-Object { $_.Action -eq "SkipUnreachable" })

    Write-Host ""
    Write-Host "Plan: $($toUpdate.Count) host(s) (upgrade/install + config repair on already-current), $($already.Count) already on target, $($unreachable.Count) unreachable." -ForegroundColor White

    if ($toUpdate.Count -eq 0) {
        Write-WarnStep "Nothing to update after verification."
        return $false
    }

    if ($SkipPrompt) {
        Write-Step "Confirmation skipped (-Force)."
        return $true
    }

    $answer = Read-Host "Proceed on $($toUpdate.Count) host(s)? [y/N]"
    if ($answer -match '^(y|yes)$') {
        return $true
    }

    Write-WarnStep "Aborted by operator — no changes applied."
    return $false
}

function Invoke-RemoteNginxUpdate {
    param(
        [PSCustomObject]$Target,
        [string]$KeyPath,
        [string]$User,
        [string]$Version,
        [string]$LocalScript,
        [bool]$DoRestart
    )

    $hostLabel = "$($Target.InstanceId) $($Target.Name) [$($Target.ConnectIp)]"
    $remoteTmp = "/tmp/remote-update-nginx-$Version.sh"
    $sshBase = Get-SshBaseArgs -KeyPath $KeyPath
    $dest = "${User}@$($Target.ConnectIp)"
    $restartArg = if ($DoRestart) { "restart" } else { "norestart" }

    Write-Step "Target: $hostLabel"

    if (-not $PSCmdlet.ShouldProcess($hostLabel, "Update nginx to $Version via SSH")) {
        return [PSCustomObject]@{
            InstanceId = $Target.InstanceId
            Name       = $Target.Name
            Ip         = $Target.ConnectIp
            Status     = "Skipped"
            Detail     = "ShouldProcess declined"
        }
    }

    try {
        $scpArgs = $sshBase + @($LocalScript, "${dest}:${remoteTmp}")
        $scpOut = & scp @scpArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "scp failed: $scpOut"
        }

        # Strip CR in case the .sh was checked out with Windows CRLF
        $remoteCmd = "sed -i 's/\r$//' $remoteTmp && chmod +x $remoteTmp && sudo bash $remoteTmp $Version $restartArg && rm -f $remoteTmp"
        $sshArgs = $sshBase + @($dest, $remoteCmd)
        $output = & ssh @sshArgs 2>&1
        $exit = $LASTEXITCODE
        $text = ($output | Out-String).Trim()

        if ($exit -eq 0) {
            Write-Ok "Updated $hostLabel"
            if ($text) { Write-Host $text }
            return [PSCustomObject]@{
                InstanceId = $Target.InstanceId
                Name       = $Target.Name
                Ip         = $Target.ConnectIp
                Status     = "Success"
                Detail     = $text
            }
        }

        Write-ErrStep "Failed on $hostLabel (exit $exit)"
        if ($text) { Write-Host $text }
        return [PSCustomObject]@{
            InstanceId = $Target.InstanceId
            Name       = $Target.Name
            Ip         = $Target.ConnectIp
            Status     = "Failed"
            Detail     = $text
        }
    }
    catch {
        Write-ErrStep "Error on $hostLabel : $_"
        return [PSCustomObject]@{
            InstanceId = $Target.InstanceId
            Name       = $Target.Name
            Ip         = $Target.ConnectIp
            Status     = "Failed"
            Detail     = "$_"
        }
    }
}

# --- main ---


if (-not (Test-CommandExists "ssh")) {
    throw "ssh not found in PATH. Install OpenSSH client."
}
if (-not (Test-CommandExists "scp")) {
    throw "scp not found in PATH. Install OpenSSH client."
}

$pemResolved = (Resolve-Path -LiteralPath $PemFile).Path

# ssh refuses world-readable private keys on Unix
$onUnix = $false
try {
    $onUnix = [bool]($IsLinux -or $IsMacOS)
}
catch {
    $onUnix = $PSVersionTable.Platform -eq "Unix"
}
if ($onUnix -and (Test-CommandExists "chmod")) {
    & chmod 600 $pemResolved 2>$null
}

$doDry = [bool]$DryRun -or $WhatIfPreference

if (-not $LogPath) {
    $defaultLogDir = Join-Path $ScriptRoot "logs"
    $LogPath = Join-Path $defaultLogDir ("nginx-verify-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}

if ($InstanceIp -and $SkipAwsLookup) {
    Write-Step "Skipping AWS lookup; targeting IP $InstanceIp"
    $targets = @(
        [PSCustomObject]@{
            InstanceId = "n/a"
            Name       = "manual"
            PublicIp   = $InstanceIp
            PrivateIp  = $null
            ConnectIp  = $InstanceIp
            Platform   = "unknown"
        }
    )
}
else {
    if (-not (Test-CommandExists "aws")) {
        throw "aws CLI not found in PATH."
    }
    if ($SkipAwsLookup -and -not $InstanceIp) {
        throw "-SkipAwsLookup requires -InstanceIp."
    }
    $targets = Get-Ec2Targets -FilterIp $InstanceIp -PreferPublicIp:$UsePublicIp
}

if ($targets.Count -eq 0) {
    Write-WarnStep "No instances to update."
    exit 0
}

Write-Host ""
Write-Host "Discovered instances:" -ForegroundColor White
$targets | Format-Table InstanceId, Name, ConnectIp, Platform -AutoSize
Write-Host ""

$verification = Invoke-VerificationStage `
    -Targets $targets `
    -KeyPath $pemResolved `
    -User $SshUser `
    -TargetVersion $NginxVersion `
    -VerificationLogPath $LogPath

if ($doDry) {
    Write-WarnStep "Dry run — verification only; no updates executed."
    exit 0
}

$confirmed = Confirm-UpgradeExecution -VerificationRows $verification -SkipPrompt:([bool]$Force)
if (-not $confirmed) {
    exit 0
}

$toUpdate = @($verification | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties['Action'] -and ($_.Action -in @("Install", "Upgrade", "AlreadyCurrent"))
    })

$localScript = $null
try {
    $localScript = New-TempRemoteUpdateScript
    $results = foreach ($row in $toUpdate) {
        Invoke-RemoteNginxUpdate `
            -Target $row.Target `
            -KeyPath $pemResolved `
            -User $SshUser `
            -Version $NginxVersion `
            -LocalScript $localScript `
            -DoRestart:([bool]$Restart)
    }
}
finally {
    if ($localScript -and (Test-Path -LiteralPath $localScript)) {
        Remove-Item -LiteralPath $localScript -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor White
$results | Format-Table InstanceId, Name, Ip, Status -AutoSize

$failed = @($results | Where-Object { $_.Status -eq "Failed" })
if ($failed.Count -gt 0) {
    Write-ErrStep "$($failed.Count) instance(s) failed."
    exit 1
}

Write-Ok "Done."
exit 0
