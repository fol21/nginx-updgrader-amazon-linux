#!/usr/bin/env bash
# Installs/upgrades nginx to a specific version on Debian/Ubuntu or RHEL/Amazon Linux.
# Keep in sync with the embedded bash in Update-Nginx.ps1 (SSH updater).
# Usage: sudo bash upgrade-nginx.sh [VERSION] [restart|norestart]
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

  echo "nginx ${TARGET} not in stable apt repo — retrying with mainline..."
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
        # Pin major (2023) — $releasever is unreliable on some AL2023 images
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
  echo "nginx ${TARGET} already installed — repairing site config only"
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
    echo "WARNING: nginx restart failed — package/config update still succeeded" >&2
  fi
else
  echo "=== Skipping nginx restart (pass restart / use -Restart to enable) ==="
fi

echo "OK"
