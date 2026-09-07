#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# new-lab-vm.sh - create a bridged Ubuntu Server VM for the lab.
# Runs on a macOS or Linux host. Supports VirtualBox (Intel Mac / Linux) and
# prints UTM guidance on Apple Silicon, where VirtualBox is not an option.
#
#   ./scripts/host/new-lab-vm.sh --name k8s-cp --iso ~/iso/ubuntu-24.04.iso \
#       --memory 4096 --cpus 2 --disk 25
#
# It creates the VM shell; you run the Ubuntu installer yourself once, which is
# where you set the hostname and tick "Install OpenSSH server".
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
set -uo pipefail

NAME=""; ISO=""; MEMORY=2048; CPUS=2; DISK=25; BRIDGE=""; START=0

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --name NAME        VM name; use the hostname you plan to set (k8s-cp / k8s-worker1)
  --iso PATH         Ubuntu Server ISO
  --memory MB        RAM in MB     (default 2048; use 4096 for the control plane)
  --cpus N           vCPUs         (default 2; Kubernetes requires >= 2)
  --disk GB          Disk in GB    (default 25)
  --bridge IFACE     Host NIC to bridge onto (default: first connected)
  --start            Boot the VM when it is created
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)   NAME="$2"; shift 2 ;;
    --iso)    ISO="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --cpus)   CPUS="$2"; shift 2 ;;
    --disk)   DISK="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --start)  START=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$NAME" ] || { usage; die "--name is required"; }
[ -n "$ISO" ]  || { usage; die "--iso is required"; }
[ -f "$ISO" ]  || die "ISO not found: ${ISO}"

# --- Apple Silicon: VirtualBox is not viable, point at UTM -------------------
if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] && ! command -v VBoxManage >/dev/null 2>&1; then
  section "Apple Silicon detected"
  cat <<EOF
VirtualBox does not run usefully on Apple Silicon. Use UTM instead - it is free
and its defaults work for this lab.

  1. Install UTM:            brew install --cask utm
  2. Download the ARM64 Ubuntu Server ISO (not amd64):
                             https://ubuntu.com/download/server/arm
  3. In UTM: + -> Virtualize -> Linux -> select the ISO
  4. Settings that matter:
       Memory   : ${MEMORY} MB
       CPU      : ${CPUS} cores
       Storage  : ${DISK} GB
       Network  : Bridged (Advanced)   <-- NOT "Shared Network". Bridged is what
                                           lets this VM and the Windows VM see
                                           each other on your LAN.
  5. In the Ubuntu installer:
       hostname -> ${NAME}
       TICK "Install OpenSSH server"
  6. After first boot:  ip -4 addr   -> put that IP in lab.env

VMware Fusion (free for personal use) works equally well; choose "Bridged"
networking there too.
EOF
  exit 0
fi

command -v VBoxManage >/dev/null 2>&1 || die "VBoxManage not found. Install VirtualBox first."
section "VirtualBox $(VBoxManage --version)"

# --- Choose a bridge interface ----------------------------------------------
if [ -z "$BRIDGE" ]; then
  BRIDGE="$(VBoxManage list bridgedifs | awk '
    /^Name:/       { name=substr($0, index($0,$2)) }
    /^Status:.*Up/ { if (name != "") { print name; exit } }')"
  [ -n "$BRIDGE" ] || BRIDGE="$(VBoxManage list bridgedifs | awk '/^Name:/{print substr($0,index($0,$2)); exit}')"
  [ -n "$BRIDGE" ] || die "No bridgeable host adapters found."
  info "Auto-selected bridge interface: ${BRIDGE}"
fi
ok "Bridging onto: ${BRIDGE}"

if VBoxManage list vms | grep -q "\"${NAME}\""; then
  die "A VM named '${NAME}' already exists. Remove it with: VBoxManage unregistervm '${NAME}' --delete"
fi

section "Creating '${NAME}'"
VBoxManage createvm --name "$NAME" --ostype Ubuntu_64 --register >/dev/null
VBoxManage modifyvm "$NAME" \
  --memory "$MEMORY" --cpus "$CPUS" \
  --nic1 bridged --bridgeadapter1 "$BRIDGE" --nictype1 virtio \
  --ioapic on --rtcuseutc on \
  --boot1 dvd --boot2 disk --boot3 none --boot4 none \
  --graphicscontroller vmsvga --vram 16 --audio-driver none >/dev/null
# A unique MAC per node: cloned MACs make nodes fight over DHCP leases.
VBoxManage modifyvm "$NAME" --macaddress1 auto >/dev/null
ok "${CPUS} vCPU, ${MEMORY} MB RAM, bridged virtio NIC, unique MAC"

VM_DIR="$(VBoxManage showvminfo "$NAME" --machinereadable | awk -F= '/^CfgFile=/{gsub(/"/,"",$2); print $2}')"
VM_DIR="$(dirname "$VM_DIR")"
DISK_PATH="${VM_DIR}/${NAME}.vdi"

VBoxManage createmedium disk --filename "$DISK_PATH" --size $((DISK * 1024)) --format VDI >/dev/null
VBoxManage storagectl "$NAME" --name SATA --add sata --controller IntelAhci --portcount 2 >/dev/null
VBoxManage storageattach "$NAME" --storagectl SATA --port 0 --device 0 --type hdd --medium "$DISK_PATH" >/dev/null
VBoxManage storagectl "$NAME" --name IDE --add ide >/dev/null
VBoxManage storageattach "$NAME" --storagectl IDE --port 0 --device 0 --type dvddrive --medium "$ISO" >/dev/null
ok "${DISK} GB disk created and the installer ISO attached"

section "Next: install Ubuntu inside the VM"
cat <<EOF
  Start it:      VBoxManage startvm ${NAME} --type gui

  Installer choices that matter for this lab:
    Network   accept DHCP, then note the IPv4 address. It must be on your normal
              LAN subnet - a 10.0.2.x address means NAT, not bridged, and the two
              nodes will never see each other.
    Storage   "Use an entire disk"
    Profile   server name -> ${NAME}
              username    -> whatever you set as SSH_USER in lab.env
    SSH       TICK "Install OpenSSH server" - the whole toolkit drives the node
              over SSH and cannot work without it.
    Snaps     select none

  After the install reboots the VM:
    1. ip -4 addr           # note the IP, put it in lab.env
    2. Eject the ISO so it does not boot the installer again:
       VBoxManage storageattach ${NAME} --storagectl IDE --port 0 --device 0 \\
         --type dvddrive --medium none
    3. ./lab check

  Handy commands:
    VBoxManage startvm ${NAME} --type headless
    VBoxManage controlvm ${NAME} acpipowerbutton      # graceful shutdown
    VBoxManage snapshot ${NAME} take clean-install    # before you break things
    VBoxManage snapshot ${NAME} restore clean-install
EOF

if [ "$START" = "1" ]; then
  VBoxManage startvm "$NAME" --type gui
  ok "VM started"
fi
