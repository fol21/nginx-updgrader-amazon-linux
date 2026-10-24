#!/usr/bin/env bash
# Installs/upgrades nginx to a specific version on Debian/Ubuntu or RHEL/Amazon Linux.
# Usage: sudo bash remote-update-nginx.sh [VERSION]
set -euo pipefail

TARGET="${1:-1.30.6}"

echo "=== Host: $(hostname) ==="
echo "=== Target nginx version: ${TARGET} ==="
echo "=== Current nginx (if any) ==="
nginx -v 2>&1 || true

install_debian() {
  export DEBIAN_FRONTEND=noninteractive

  if [[ ! -f /etc/apt/sources.list.d/nginx.list ]] && [[ ! -f /etc/apt/sources.list.d/nginx.sources ]]; then
    echo "Configuring nginx.org apt repository..."
    # shellcheck source=/dev/null
    . /etc/os-release
    local distro="${ID:-ubuntu}"
    local codename="${VERSION_CODENAME:-}"
    if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
      codename="$(lsb_release -cs)"
    fi
    codename="${codename:-jammy}"

    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
      | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

    local packages_distro="ubuntu"
    if [[ "$distro" == "debian" ]]; then
      packages_distro="debian"
    fi

    cat > /etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${packages_distro} ${codename} nginx
EOF
  fi

  apt-get update -qq

  local candidate
  candidate="$(apt-cache madison nginx 2>/dev/null | awk -v v="$TARGET" '$2 ~ "^"v {print $2; exit}')"
  if [[ -z "$candidate" ]]; then
    echo "ERROR: nginx ${TARGET} not found in apt cache. Available versions:" >&2
    apt-cache madison nginx 2>/dev/null | head -20 >&2 || true
    exit 2
  fi

  echo "Installing nginx=${candidate}"
  apt-get install -y "nginx=${candidate}"
}

install_rhel() {
  local pkg_mgr
  pkg_mgr="$(command -v dnf || command -v yum)"

  if [[ ! -f /etc/yum.repos.d/nginx.repo ]]; then
    echo "Configuring nginx.org yum repository..."
    # Amazon Linux 2023 / RHEL 9 style; nginx.org documents OS-specific baseurls.
    # Prefer amazonlinux or centos path based on /etc/os-release.
    # shellcheck source=/dev/null
    . /etc/os-release
    local baseurl
    case "${ID:-}" in
      amzn)
        if [[ "${VERSION_ID:-}" == 2 ]]; then
          baseurl="http://nginx.org/packages/amzn2/\$releasever/\$basearch/"
        else
          baseurl="http://nginx.org/packages/amzn/\$releasever/\$basearch/"
        fi
        ;;
      *)
        baseurl="http://nginx.org/packages/centos/\$releasever/\$basearch/"
        ;;
    esac

    cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=${baseurl}
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
  fi

  "$pkg_mgr" makecache -q || true

  if "$pkg_mgr" list available "nginx-${TARGET}*" 2>/dev/null | grep -q nginx; then
    "$pkg_mgr" install -y "nginx-${TARGET}*"
  else
    echo "Trying exact package nginx-${TARGET} ..."
    if ! "$pkg_mgr" install -y "nginx-${TARGET}"; then
      echo "ERROR: could not install nginx ${TARGET} via ${pkg_mgr}" >&2
      "$pkg_mgr" list available nginx 2>/dev/null | head -20 >&2 || true
      exit 2
    fi
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  install_debian
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
  install_rhel
else
  echo "ERROR: unsupported OS (need apt-get or yum/dnf)" >&2
  exit 3
fi

echo "=== Restarting nginx ==="
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

echo "=== Installed version ==="
nginx -v 2>&1

INSTALLED="$(nginx -v 2>&1 | sed -n 's/.*nginx\///p')"
if [[ "$INSTALLED" != ${TARGET}* ]]; then
  echo "ERROR: expected nginx ${TARGET}*, got ${INSTALLED:-unknown}" >&2
  exit 4
fi

echo "OK"
