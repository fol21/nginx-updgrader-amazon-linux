<#
.SYNOPSIS
    Updates nginx to a target version on AWS EC2 instances via SSH.

.DESCRIPTION
    Lists running EC2 instances with the AWS CLI (or targets a single IP), then
    copies scripts/remote-update-nginx.sh over SSH and runs it with sudo to
    install/upgrade nginx (default: 1.30.6).

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
    AWS region for describe-instances. Falls back to your AWS CLI default.

.PARAMETER Profile
    Optional AWS CLI profile name.

.PARAMETER NginxVersion
    Target nginx version. Default: 1.30.6

.PARAMETER UsePrivateIp
    Prefer private IPs when listing instances (VPN / bastion access).

.PARAMETER SkipAwsLookup
    With -InstanceIp, skip AWS CLI and SSH straight to that IP.

.PARAMETER DryRun
    List targets without connecting.

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
    [string]$Region,

    [Parameter()]
    [string]$Profile,

    [Parameter()]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$NginxVersion = "1.30.6",

    [Parameter()]
    [switch]$UsePrivateIp,

    [Parameter()]
    [switch]$SkipAwsLookup,

    [Parameter()]
    [switch]$DryRun
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
    $extra = [System.Collections.Generic.List[string]]::new()
    if ($Region) {
        $extra.Add("--region")
        $extra.Add($Region)
    }
    if ($Profile) {
        $extra.Add("--profile")
        $extra.Add($Profile)
    }
    return $extra
}

function Get-Ec2Targets {
    param(
        [string]$FilterIp,
        [bool]$PreferPrivateIp
    )

    $awsArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($a in (Get-AwsExtraArgs)) { $awsArgs.Add($a) }

    $awsArgs.Add("ec2")
    $awsArgs.Add("describe-instances")
    $awsArgs.Add("--filters")
    $awsArgs.Add("Name=instance-state-name,Values=running")
    $awsArgs.Add("--query")
    $awsArgs.Add("Reservations[].Instances[].[InstanceId,PublicIpAddress,PrivateIpAddress,Tags[?Key==``Name``]|[0].Value,PlatformDetails]")
    $awsArgs.Add("--output")
    $awsArgs.Add("json")

    Write-Step "Querying running EC2 instances via AWS CLI..."
    $raw = & aws @($awsArgs.ToArray()) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "aws ec2 describe-instances failed:`n$raw"
    }

    $rows = $raw | ConvertFrom-Json
    if (-not $rows) {
        return @()
    }

    $targets = foreach ($row in $rows) {
        $id = [string]$row[0]
        $publicIp = if ($null -ne $row[1] -and "$($row[1])" -ne "") { [string]$row[1] } else { $null }
        $privateIp = if ($null -ne $row[2] -and "$($row[2])" -ne "") { [string]$row[2] } else { $null }
        $name = if ($null -ne $row[3] -and "$($row[3])" -ne "") { [string]$row[3] } else { "(unnamed)" }
        $platform = if ($null -ne $row[4] -and "$($row[4])" -ne "") { [string]$row[4] } else { "unknown" }

        $connectIp = if ($PreferPrivateIp) {
            if ($privateIp) { $privateIp } else { $publicIp }
        }
        else {
            if ($publicIp) { $publicIp } else { $privateIp }
        }

        if (-not $connectIp) {
            Write-WarnStep "Skipping $id ($name): no reachable IP"
            continue
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

function Invoke-RemoteNginxUpdate {
    param(
        [PSCustomObject]$Target,
        [string]$KeyPath,
        [string]$User,
        [string]$Version,
        [string]$LocalScript,
        [bool]$IsDryRun
    )

    $hostLabel = "$($Target.InstanceId) $($Target.Name) [$($Target.ConnectIp)]"
    $remoteTmp = "/tmp/remote-update-nginx-$Version.sh"
    $sshBase = Get-SshBaseArgs -KeyPath $KeyPath
    $dest = "${User}@$($Target.ConnectIp)"

    Write-Step "Target: $hostLabel"

    if ($IsDryRun -or $WhatIfPreference) {
        Write-Host "  DRY RUN — would: scp script -> $dest:$remoteTmp ; ssh sudo bash $remoteTmp $Version"
        return [PSCustomObject]@{
            InstanceId = $Target.InstanceId
            Name       = $Target.Name
            Ip         = $Target.ConnectIp
            Status     = "DryRun"
            Detail     = "Skipped SSH"
        }
    }

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

        $remoteCmd = "chmod +x $remoteTmp && sudo bash $remoteTmp $Version && rm -f $remoteTmp"
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
    $targets = Get-Ec2Targets -FilterIp $InstanceIp -PreferPrivateIp:$UsePrivateIp
}

if ($targets.Count -eq 0) {
    Write-WarnStep "No instances to update."
    exit 0
}

Write-Host ""
Write-Host "Instances to update (nginx -> $NginxVersion):" -ForegroundColor White
$targets | Format-Table InstanceId, Name, ConnectIp, Platform -AutoSize
Write-Host ""

$results = foreach ($t in $targets) {
    Invoke-RemoteNginxUpdate `
        -Target $t `
        -KeyPath $pemResolved `
        -User $SshUser `
        -Version $NginxVersion `
        -LocalScript $RemoteScriptPath `
        -IsDryRun:$doDry
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
