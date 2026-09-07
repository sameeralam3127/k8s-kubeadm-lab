<#
.SYNOPSIS
    Prepare a Windows machine to act as a host for the kubeadm lab.

.DESCRIPTION
    Installs (or verifies) everything a Windows user needs:
      * OpenSSH client   - to drive the Linux VMs
      * VirtualBox       - the hypervisor that runs the worker VM
      * kubectl          - to talk to the cluster from Windows
      * Windows Terminal - nicer output than conhost (optional)

    Uses winget where available and falls back to direct downloads.
    Run this in an ELEVATED PowerShell window (right-click -> Run as
    Administrator); the OpenSSH capability and VirtualBox both need it.

.EXAMPLE
    .\Setup-WindowsHost.ps1
.EXAMPLE
    .\Setup-WindowsHost.ps1 -SkipVirtualBox     # host will not run a VM
#>

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
[CmdletBinding()]
param(
    [switch]$SkipVirtualBox,
    [switch]$SkipKubectl,
    [switch]$SkipTerminal
)

$ErrorActionPreference = 'Stop'

function Write-Head ($m) {
    Write-Host ''
    Write-Host $m -ForegroundColor White
    Write-Host ('-' * $m.Length) -ForegroundColor DarkGray
}
function Write-Ok   ($m) { Write-Host " [ok] "   -ForegroundColor Green  -NoNewline; Write-Host $m }
function Write-Warn2($m) { Write-Host " [warn] " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Bad  ($m) { Write-Host " [fail] " -ForegroundColor Red    -NoNewline; Write-Host $m }
function Write-Info2($m) { Write-Host "        $m" -ForegroundColor DarkGray }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Winget { [bool](Get-Command winget -ErrorAction SilentlyContinue) }

function Install-WithWinget ($id, $friendly) {
    Write-Info2 "winget install $id"
    & winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) { Write-Ok "$friendly installed"; return $true }
    Write-Warn2 "winget could not install $friendly (exit $LASTEXITCODE)"
    return $false
}

Write-Head 'Environment'
Write-Info2 "Windows : $((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Info2 "PowerShell : $($PSVersionTable.PSVersion)"
if (Test-Admin) { Write-Ok 'Running elevated' }
else {
    Write-Bad 'Not running as Administrator.'
    Write-Info2 'Close this window, right-click PowerShell -> Run as Administrator, and re-run.'
    exit 1
}
if (Test-Winget) { Write-Ok "winget available ($(winget --version))" }
else { Write-Warn2 'winget not found - falling back to manual download links' }

# ---------------------------------------------------------------------------
Write-Head '1/5  OpenSSH client'
if (Get-Command ssh -ErrorAction SilentlyContinue) {
    Write-Ok "ssh already present ($((ssh -V 2>&1) -join ''))"
} else {
    # OpenSSH ships as an optional Windows capability on 1809+ / Windows 11.
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Client*' |
           Select-Object -First 1
    if ($cap -and $cap.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        Write-Ok 'OpenSSH client installed'
    } elseif ($cap) {
        Write-Ok 'OpenSSH client already installed'
    } else {
        Write-Bad 'OpenSSH client capability not found on this Windows build.'
        Write-Info2 'Install Git for Windows instead, which bundles ssh/scp.'
    }
}

# ssh-agent makes key auth painless; start it and set it to auto-start.
Write-Head '2/5  ssh-agent service'
try {
    $svc = Get-Service ssh-agent -ErrorAction Stop
    if ($svc.StartType -eq 'Disabled') {
        Set-Service ssh-agent -StartupType Automatic
        Write-Ok 'ssh-agent set to start automatically'
    }
    if ($svc.Status -ne 'Running') { Start-Service ssh-agent; Write-Ok 'ssh-agent started' }
    else { Write-Ok 'ssh-agent already running' }
} catch {
    Write-Warn2 "Could not configure ssh-agent: $($_.Exception.Message)"
    Write-Info2 'Not fatal - the lab passes the key with -i on every call.'
}

# ---------------------------------------------------------------------------
Write-Head '3/5  VirtualBox'
if ($SkipVirtualBox) {
    Write-Info2 'Skipped (-SkipVirtualBox)'
} elseif (Get-Command VBoxManage -ErrorAction SilentlyContinue) {
    Write-Ok "VirtualBox already installed ($(VBoxManage --version))"
} elseif (Test-Path 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe') {
    Write-Ok 'VirtualBox installed but not on PATH'
    Write-Info2 'Adding C:\Program Files\Oracle\VirtualBox to this session PATH'
    $env:Path += ';C:\Program Files\Oracle\VirtualBox'
} else {
    $done = $false
    if (Test-Winget) { $done = Install-WithWinget 'Oracle.VirtualBox' 'VirtualBox' }
    if (-not $done) {
        Write-Warn2 'Install VirtualBox manually from https://www.virtualbox.org/wiki/Downloads'
    } else {
        $env:Path += ';C:\Program Files\Oracle\VirtualBox'
    }
    # Hyper-V and VirtualBox fight over the CPU virtualisation extensions.
    $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
    if ($hv -and $hv.State -eq 'Enabled') {
        Write-Warn2 'Hyper-V is enabled. VirtualBox VMs will be slow or refuse to start.'
        Write-Info2 'Either use Hyper-V for the VM instead, or disable Hyper-V with:'
        Write-Info2 '  bcdedit /set hypervisorlaunchtype off   (then reboot)'
    }
}

# ---------------------------------------------------------------------------
Write-Head '4/5  kubectl'
if ($SkipKubectl) {
    Write-Info2 'Skipped (-SkipKubectl)'
} elseif (Get-Command kubectl -ErrorAction SilentlyContinue) {
    Write-Ok "kubectl already installed ($((kubectl version --client -o json 2>$null | ConvertFrom-Json).clientVersion.gitVersion))"
} else {
    $done = $false
    if (Test-Winget) { $done = Install-WithWinget 'Kubernetes.kubectl' 'kubectl' }
    if (-not $done) {
        # Direct download into a per-user tools directory that we add to PATH.
        $dir = Join-Path $env:LOCALAPPDATA 'k8s-lab\bin'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $ver = (Invoke-WebRequest -UseBasicParsing 'https://dl.k8s.io/release/stable.txt').Content.Trim()
        $url = "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe"
        Write-Info2 "Downloading kubectl $ver"
        Invoke-WebRequest -UseBasicParsing $url -OutFile (Join-Path $dir 'kubectl.exe')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$dir*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$dir", 'User')
            Write-Info2 "Added $dir to your user PATH (new shells only)"
        }
        $env:Path += ";$dir"
        Write-Ok "kubectl $ver installed to $dir"
    }
}

# ---------------------------------------------------------------------------
Write-Head '5/5  Windows Terminal (optional)'
if ($SkipTerminal) {
    Write-Info2 'Skipped (-SkipTerminal)'
} elseif (Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue) {
    Write-Ok 'Windows Terminal already installed'
} elseif (Test-Winget) {
    Install-WithWinget 'Microsoft.WindowsTerminal' 'Windows Terminal' | Out-Null
} else {
    Write-Info2 'Install it from the Microsoft Store for colour output that renders properly.'
}

# ---------------------------------------------------------------------------
Write-Head 'Execution policy'
$pol = Get-ExecutionPolicy -Scope CurrentUser
if ($pol -in @('Restricted', 'Undefined', 'AllSigned')) {
    Write-Warn2 "Current user execution policy is '$pol' - lab.ps1 will not run."
    Write-Info2 'Fix it with:'
    Write-Info2 '  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
} else {
    Write-Ok "Execution policy: $pol"
}

Write-Head 'Next steps'
@'
  1. Create the Ubuntu worker VM on this machine:
         .\New-LabVM.ps1 -Name k8s-worker1 -IsoPath C:\iso\ubuntu-24.04-live-server-amd64.iso

  2. On whichever machine holds the repo, copy lab.env.example to lab.env and
     fill in the two IP addresses.

  3. Then drive the lab from here:
         .\lab.ps1 check
         .\lab.ps1 up
'@ | Write-Host
Write-Host ''
Write-Ok 'Host setup complete.'
