# Update Nginx on AWS EC2

PowerShell helper that lists running EC2 instances with the AWS CLI (or a single IP you pass), verifies current nginx versions over SSH, asks for confirmation, then upgrades **nginx to 1.30.6** (configurable).

## Prerequisites

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) already logged in (`aws sts get-caller-identity` works) with `ec2:DescribeInstances`
- OpenSSH client (`ssh` and `scp`) in `PATH`
- PEM private key that matches the instances’ key pair
- Network reachability to **private IPs** (VPN / bastion / same VPC). Use `-UsePublicIp` only if you must connect via public IP.
- Passwordless `sudo` on the instances (typical for `ec2-user` / `ubuntu`) — only needed for the update stage

## Files

| Path | Role |
|------|------|
| `Update-Nginx.ps1` | Orchestrator: AWS list → verify → confirm → SSH/SCP update |
| `scripts/remote-update-nginx.sh` | Runs on each host (apt or yum/dnf + nginx.org packages) |

## Flow

1. **Discover** — list running EC2 instances (or a single `-InstanceIp`)
2. **Verify** — SSH read-only to each host, read `nginx -v`, print IP / current / target / action, write a log under `logs/`
3. **Confirm** — ask `Proceed? [y/N]` (skipped with `-Force`)
4. **Update** — only hosts marked `Install` or `Upgrade` receive the remote script

## Usage

```powershell
# All running instances (verify table + confirm before update)
.\Update-Nginx.ps1 -PemFile C:\keys\my-key.pem

# One instance by IP
.\Update-Nginx.ps1 -PemFile .\my-key.pem -InstanceIp 54.1.2.3 -SshUser ubuntu

# Verification only (no confirmation, no update)
.\Update-Nginx.ps1 -PemFile .\my-key.pem -Region us-east-1 -DryRun

# Skip confirmation prompt (CI / automation)
.\Update-Nginx.ps1 -PemFile .\my-key.pem -Force

# Restart nginx after update/repair
.\Update-Nginx.ps1 -PemFile .\my-key.pem -Restart

# Force public IP (default is private)
.\Update-Nginx.ps1 -PemFile .\my-key.pem -UsePublicIp

# Skip AWS lookup and SSH straight to an IP
.\Update-Nginx.ps1 -PemFile .\my-key.pem -InstanceIp 10.0.1.5 -SkipAwsLookup -SshUser ubuntu
```

On Linux/macOS with PowerShell:

```bash
pwsh ./Update-Nginx.ps1 -PemFile ./my-key.pem -InstanceIp 54.1.2.3 -SshUser ubuntu
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-PemFile` | yes | — | Path to `.pem` for `ssh -i` / `scp -i` |
| `-InstanceIp` | no | — | Update only this public or private IP |
| `-SshUser` | no | `ec2-user` | SSH login (`ubuntu` on Ubuntu AMIs) |
| `-Region` | no | AWS CLI default | EC2 region (same priority as `aws` CLI) |
| `-NginxVersion` | no | `1.30.6` | Exact version to install |
| `-UsePublicIp` | no | off | Use public IP instead of private (default) |
| `-SkipAwsLookup` | no | off | With `-InstanceIp`, do not call AWS |
| `-DryRun` | no | off | Verification only; stop before update |
| `-Force` | no | off | Skip interactive confirmation |
| `-Restart` | no | off | `systemctl restart nginx` after a successful update/repair |
| `-LogPath` | no | `logs/nginx-verify-<timestamp>.log` | Verification log path |

## Verification actions

| Action | Meaning |
|--------|---------|
| `Install` | nginx not installed; will install target version |
| `Upgrade` | installed version differs from target |
| `AlreadyCurrent` | already on target; skipped |
| `SkipUnreachable` | SSH failed; skipped |

## What the remote script does

1. Detects Debian/Ubuntu (`apt`) or Amazon Linux/RHEL (`dnf`/`yum`)
2. Ensures the [nginx.org](https://nginx.org/en/linux_packages.html) package repo is configured
3. Installs the package matching the requested version
4. Verifies `nginx -v` matches the target (no service restart)

If the exact version is not in the repo cache, the host fails with a non-zero exit and a short list of available versions.

## Exit codes

- `0` — all targets succeeded, nothing to do, aborted at confirm, or dry-run
- `1` — one or more SSH/update failures
- Non-zero from PowerShell itself on missing tools, PEM, or AWS errors before updates start
