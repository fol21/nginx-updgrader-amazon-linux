# Update Nginx on AWS EC2

PowerShell helper that lists running EC2 instances with the AWS CLI (or a single IP you pass), then SSHs in with your PEM key and upgrades **nginx to 1.30.6** (configurable).

## Prerequisites

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) already logged in (`aws sts get-caller-identity` works) with `ec2:DescribeInstances`
- OpenSSH client (`ssh` and `scp`) in `PATH`
- PEM private key that matches the instances’ key pair
- Network reachability (public IP, or private IP with `-UsePrivateIp` over VPN/bastion)
- Passwordless `sudo` on the instances (typical for `ec2-user` / `ubuntu`)

## Files

| Path | Role |
|------|------|
| `Update-Nginx.ps1` | Orchestrator: AWS list + SSH/SCP |
| `scripts/remote-update-nginx.sh` | Runs on each host (apt or yum/dnf + nginx.org packages) |

## Usage

```powershell
# All running instances in the default region (Amazon Linux user)
.\Update-Nginx.ps1 -PemFile C:\keys\my-key.pem

# One instance by IP
.\Update-Nginx.ps1 -PemFile .\my-key.pem -InstanceIp 54.1.2.3 -SshUser ubuntu

# List what would be updated (no SSH)
.\Update-Nginx.ps1 -PemFile .\my-key.pem -Region us-east-1 -DryRun

# Private IPs only (VPN)
.\Update-Nginx.ps1 -PemFile .\my-key.pem -UsePrivateIp

# Skip AWS lookup and SSH straight to an IP
.\Update-Nginx.ps1 -PemFile .\my-key.pem -InstanceIp 10.0.1.5 -SkipAwsLookup -SshUser ubuntu

# Different nginx version
.\Update-Nginx.ps1 -PemFile .\my-key.pem -NginxVersion 1.30.6
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
| `-Region` | no | AWS CLI default | EC2 region |
| `-Profile` | no | — | AWS CLI profile |
| `-NginxVersion` | no | `1.30.6` | Exact version to install |
| `-UsePrivateIp` | no | off | Prefer private IPs from `describe-instances` |
| `-SkipAwsLookup` | no | off | With `-InstanceIp`, do not call AWS |
| `-DryRun` | no | off | Print targets only |

## What the remote script does

1. Detects Debian/Ubuntu (`apt`) or Amazon Linux/RHEL (`dnf`/`yum`)
2. Ensures the [nginx.org](https://nginx.org/en/linux_packages.html) package repo is configured
3. Installs the package matching the requested version
4. Enables and restarts `nginx`, then verifies `nginx -v`

If the exact version is not in the repo cache, the host fails with a non-zero exit and a short list of available versions.

## Exit codes

- `0` — all targets succeeded (or none found / dry-run only)
- `1` — one or more SSH/update failures
- Non-zero from PowerShell itself on missing tools, PEM, or AWS errors before updates start
