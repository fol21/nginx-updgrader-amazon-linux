<#
.SYNOPSIS
    Updates nginx to a target version on AWS EC2 instances via SSH.

.DESCRIPTION
    Lists running EC2 instances with the AWS CLI (or targets a single IP), then
    runs a verification stage (SSH read-only: current nginx version vs target),
    asks for confirmation, and only then copies scripts/remote-update-nginx.sh
    over SSH to install/upgrade nginx (default: 1.30.6).

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
$RemoteScriptPath = Join-Path (Join-Path $ScriptRoot "scripts") "remote-update-nginx.sh"

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

if (-not (Test-Path -LiteralPath $RemoteScriptPath)) {
    throw "Remote update script not found: $RemoteScriptPath"
}

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

$results = foreach ($row in $toUpdate) {
    Invoke-RemoteNginxUpdate `
        -Target $row.Target `
        -KeyPath $pemResolved `
        -User $SshUser `
        -Version $NginxVersion `
        -LocalScript $RemoteScriptPath `
        -DoRestart:([bool]$Restart)
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
