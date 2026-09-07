<#
.SYNOPSIS
    Create a bridged Ubuntu Server VM in VirtualBox for the kubeadm lab.

.DESCRIPTION
    Automates the VirtualBox side of "step 2" in the lab: a VM with the right
    CPU/RAM/disk, a bridged adapter (so the VM is a first-class citizen on your
    LAN and can reach the other node), and the Ubuntu ISO attached.

    It deliberately does NOT automate the Ubuntu installer. Installing Ubuntu
    by hand once is worth the ten minutes - you choose the hostname, the user,
    and you tick "Install OpenSSH server", which is what the rest of the lab
    needs. The script prints exactly which options to choose.

.PARAMETER Name
    VM name, which should match the hostname you will set (e.g. k8s-worker1).

.PARAMETER IsoPath
    Path to the Ubuntu Server ISO. Download from https://ubuntu.com/download/server

.PARAMETER MemoryMB
    RAM in MB. 2048 is the floor for a worker, 4096 for a control plane.

.PARAMETER Cpus
    vCPU count. Kubernetes requires at least 2.

.PARAMETER DiskGB
    Virtual disk size in GB.

.PARAMETER BridgeAdapter
    Host NIC to bridge onto. Omitted means "pick the first connected adapter".

.EXAMPLE
    .\New-LabVM.ps1 -Name k8s-worker1 -IsoPath C:\iso\ubuntu-24.04.1-live-server-amd64.iso

.EXAMPLE
    .\New-LabVM.ps1 -Name k8s-cp -IsoPath C:\iso\ubuntu.iso -MemoryMB 4096 -Cpus 2
#>

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$IsoPath,
    [int]$MemoryMB = 2048,
    [int]$Cpus = 2,
    [int]$DiskGB = 25,
    [string]$BridgeAdapter,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

function Write-Head ($m) {
    Write-Host ''
    Write-Host $m -ForegroundColor White
    Write-Host ('-' * $m.Length) -ForegroundColor DarkGray
}
function Write-Ok   ($m) { Write-Host " [ok] "   -ForegroundColor Green  -NoNewline; Write-Host $m }
function Write-Warn2($m) { Write-Host " [warn] " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Info2($m) { Write-Host "        $m" -ForegroundColor DarkGray }
function Die ($m) { Write-Host " [fail] " -ForegroundColor Red -NoNewline; Write-Host $m; exit 1 }

# --- Locate VBoxManage -------------------------------------------------------
$vbmCmd = Get-Command VBoxManage -ErrorAction SilentlyContinue
$vbm = if ($vbmCmd) { $vbmCmd.Source } else { $null }
if (-not $vbm) {
    $candidate = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
    if (Test-Path $candidate) { $vbm = $candidate }
    else { Die 'VBoxManage not found. Run .\Setup-WindowsHost.ps1 first.' }
}
Write-Head 'VirtualBox'
Write-Ok "VBoxManage: $vbm ($(& $vbm --version))"

if (-not (Test-Path $IsoPath)) { Die "ISO not found: $IsoPath" }
Write-Ok "ISO: $IsoPath ($([math]::Round((Get-Item $IsoPath).Length / 1GB, 2)) GB)"

if ($Cpus -lt 2)      { Write-Warn2 'Kubernetes needs at least 2 vCPUs; kubeadm init will fail with fewer.' }
if ($MemoryMB -lt 2048) { Write-Warn2 'Less than 2048 MB RAM will be very tight, even for a worker.' }

# --- Pick the bridge adapter -------------------------------------------------
Write-Head 'Network'
# `list bridgedifs` prints one blank-line-separated block per adapter.
$bridgedText = (& $vbm list bridgedifs) -join "`n"
$adapters = @()
foreach ($block in ($bridgedText -split "`n`n")) {
    if ($block -match 'Name:\s+(.+)') {
        $adapters += [pscustomobject]@{
            Name = $Matches[1].Trim()
            Up   = ($block -match 'Status:\s+Up')
        }
    }
}
if ($adapters.Count -eq 0) { Die 'VirtualBox reports no bridgeable host adapters.' }

if (-not $BridgeAdapter) {
    # Prefer an adapter VirtualBox reports as Up. Bridging onto a disconnected
    # NIC produces a VM with no IP, which is a confusing way to fail.
    $up = $adapters | Where-Object { $_.Up } | Select-Object -First 1
    $BridgeAdapter = if ($up) { $up.Name } else { $adapters[0].Name }
    Write-Info2 'No -BridgeAdapter given; auto-selected the first connected NIC.'
}
Write-Ok "Bridging onto: $BridgeAdapter"
Write-Info2 'Available adapters:'
$adapters | ForEach-Object {
    Write-Info2 ("  - {0} [{1}]" -f $_.Name, $(if ($_.Up) { 'up' } else { 'down' }))
}

# --- Create the VM -----------------------------------------------------------
Write-Head "Creating VM '$Name'"
$existing = & $vbm list vms
if ($existing -match "^`"$Name`"") {
    Die "A VM named '$Name' already exists. Delete it first: VBoxManage unregistervm `"$Name`" --delete"
}

& $vbm createvm --name $Name --ostype Ubuntu_64 --register | Out-Null
Write-Ok 'VM registered'

& $vbm modifyvm $Name `
    --memory $MemoryMB `
    --cpus $Cpus `
    --nic1 bridged --bridgeadapter1 $BridgeAdapter --nictype1 virtio `
    --ioapic on `
    --rtcuseutc on `
    --boot1 dvd --boot2 disk --boot3 none --boot4 none `
    --graphicscontroller vmsvga `
    --vram 16 `
    --audio-driver none | Out-Null
Write-Ok "Configured: ${Cpus} vCPU, ${MemoryMB} MB RAM, bridged virtio NIC"

# A unique MAC per node matters: cloned MACs make two nodes fight over DHCP
# leases and Kubernetes then sees duplicate addresses.
& $vbm modifyvm $Name --macaddress1 auto | Out-Null
Write-Ok 'Generated a unique MAC address'

# --- Storage -----------------------------------------------------------------
Write-Head 'Storage'
$cfgLine = (& $vbm showvminfo $Name --machinereadable | Where-Object { $_ -like 'CfgFile=*' } |
            Select-Object -First 1)
if (-not $cfgLine) { Die 'Could not determine the VM folder from VBoxManage.' }
$vmDir = Split-Path -Parent ($cfgLine -replace '^CfgFile=', '').Trim('"')
$disk   = Join-Path $vmDir "$Name.vdi"

& $vbm createmedium disk --filename $disk --size ($DiskGB * 1024) --format VDI | Out-Null
Write-Ok "Created ${DiskGB} GB disk: $disk"

& $vbm storagectl $Name --name 'SATA' --add sata --controller IntelAhci --portcount 2 | Out-Null
& $vbm storageattach $Name --storagectl 'SATA' --port 0 --device 0 --type hdd --medium $disk | Out-Null
& $vbm storagectl $Name --name 'IDE' --add ide | Out-Null
& $vbm storageattach $Name --storagectl 'IDE' --port 0 --device 0 --type dvddrive --medium $IsoPath | Out-Null
Write-Ok 'Attached the disk and the installer ISO'

# --- Instructions ------------------------------------------------------------
Write-Head 'Next: install Ubuntu inside the VM'
@"
  Start the VM (add -Start to do this automatically):

      & '$vbm' startvm $Name --type gui

  In the Ubuntu Server installer, the choices that matter for this lab:

    * Network      : accept DHCP, then WRITE DOWN the IPv4 address it shows.
                     It must be on your normal LAN subnet - if it starts with
                     10.0.2.x you are on NAT, not bridged, and the nodes will
                     not see each other.
    * Storage      : "Use an entire disk". Do NOT set up LVM with a swap file
                     if you can avoid it; the lab disables swap anyway.
    * Profile      : server name -> $Name
                     username    -> whatever you put in SSH_USER in lab.env
    * SSH          : TICK "Install OpenSSH server". This is required - the
                     whole toolkit drives the node over SSH.
    * Snaps        : select nothing. Keep the VM lean.

  After the install finishes and the VM reboots:

    1. Log in at the console and run:  ip -4 addr
    2. Put that IP into lab.env
    3. Eject the installer ISO so it does not boot again:

           & '$vbm' storageattach $Name --storagectl 'IDE' --port 0 --device 0 --type dvddrive --medium none

    4. From your repo folder:  .\lab.ps1 check

  Useful VM controls:

      & '$vbm' startvm $Name --type headless     # boot without a window
      & '$vbm' controlvm $Name acpipowerbutton   # graceful shutdown
      & '$vbm' controlvm $Name poweroff          # hard stop
      & '$vbm' snapshot $Name take clean-install # snapshot before you break things
      & '$vbm' snapshot $Name restore clean-install
      & '$vbm' unregistervm $Name --delete       # remove the VM entirely
"@ | Write-Host

if ($Start) {
    Write-Head 'Starting the VM'
    & $vbm startvm $Name --type gui
    Write-Ok 'VM started - complete the Ubuntu installer in the VirtualBox window'
}
