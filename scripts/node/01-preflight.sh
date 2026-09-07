#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# 01-preflight.sh - verify this VM can actually host a Kubernetes node.
# Read-only: it changes nothing, it only reports. Run it on EVERY node first.
#
#   sudo ./01-preflight.sh
#
# Env:
#   PEER_IPS="192.168.1.101 192.168.1.102"   # other nodes to ping-test
#   ROLE=control-plane|worker                 # tunes the port + resource checks
# =============================================================================
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ROLE="${ROLE:-worker}"
PEER_IPS="${PEER_IPS:-}"
FAILURES=0
WARNINGS=0

check()  { printf '  %-42s' "$1"; }
pass()   { printf '%s PASS %s%s\n' "$C_GREEN" "$C_RESET" "${1:-}"; }
fail()   { printf '%s FAIL %s%s\n' "$C_RED" "$C_RESET" "${1:-}"; FAILURES=$((FAILURES+1)); }
soft()   { printf '%s WARN %s%s\n' "$C_YELLOW" "$C_RESET" "${1:-}"; WARNINGS=$((WARNINGS+1)); }

section "Preflight checks (role: ${ROLE})"

# --- Operating system --------------------------------------------------------
check "Operating system"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) pass "${PRETTY_NAME}" ;;
    *)             soft "${PRETTY_NAME:-unknown} - scripts target Ubuntu/Debian" ;;
  esac
else
  fail "cannot read /etc/os-release"
fi

# --- Architecture ------------------------------------------------------------
check "CPU architecture"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64) pass "$ARCH" ;;
  *)              fail "$ARCH is not supported by upstream kubeadm packages" ;;
esac

# --- CPU / RAM / disk --------------------------------------------------------
CPUS="$(nproc)"
MIN_CPUS=2
check "CPU cores (need >= ${MIN_CPUS})"
[ "$CPUS" -ge "$MIN_CPUS" ] && pass "$CPUS" || fail "$CPUS - kubeadm init will refuse to run"

MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
if [ "$ROLE" = "control-plane" ]; then MIN_MEM=1700; else MIN_MEM=1400; fi
check "Memory MB (need >= ${MIN_MEM})"
[ "$MEM_MB" -ge "$MIN_MEM" ] && pass "${MEM_MB} MB" || fail "${MEM_MB} MB - give the VM more RAM"

DISK_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
check "Free disk on / (need >= 15G)"
[ "${DISK_GB:-0}" -ge 15 ] && pass "${DISK_GB} GB" || fail "${DISK_GB} GB free"

# --- Swap --------------------------------------------------------------------
check "Swap disabled"
if [ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -eq 0 ]; then
  pass
else
  soft "swap is ON - 02-prep-node.sh will disable it"
fi

# --- Kernel modules ----------------------------------------------------------
for mod in overlay br_netfilter; do
  check "Kernel module: ${mod}"
  if lsmod | grep -q "^${mod}\b"; then pass
  elif modinfo "$mod" >/dev/null 2>&1; then soft "available but not loaded yet"
  else fail "not available in this kernel"; fi
done

# --- sysctl ------------------------------------------------------------------
for key in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables; do
  check "sysctl ${key} = 1"
  val="$(sysctl -n "$key" 2>/dev/null || echo missing)"
  [ "$val" = "1" ] && pass || soft "currently '${val}' - 02-prep-node.sh will set it"
done

# --- Identity: hostname, machine-id, product_uuid ----------------------------
check "Hostname is not a default"
HN="$(hostname)"
case "$HN" in
  localhost|ubuntu|debian) fail "'${HN}' - every node needs a unique hostname" ;;
  *)                       pass "$HN" ;;
esac

check "machine-id present"
MID="$(cat /etc/machine-id 2>/dev/null)"
[ -n "$MID" ] && pass "${MID:0:12}..." || fail "empty - regenerate it (see README gotchas)"

check "product_uuid present"
PUUID="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo '')"
[ -n "$PUUID" ] && pass "${PUUID:0:13}..." || soft "unreadable (common on ARM/UTM) - usually harmless"

# --- Network -----------------------------------------------------------------
PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
check "Primary IPv4 address"
[ -n "$PRIMARY_IP" ] && pass "$PRIMARY_IP" || fail "no default route"

check "Internet reachable (pkgs.k8s.io)"
if curl -fsS --max-time 8 -o /dev/null https://pkgs.k8s.io/ 2>/dev/null; then
  pass
else
  fail "cannot reach the Kubernetes package repo - check DNS/proxy"
fi

for peer in $PEER_IPS; do
  [ "$peer" = "$PRIMARY_IP" ] && continue
  check "Ping peer ${peer}"
  if ping -c 2 -W 2 "$peer" >/dev/null 2>&1; then pass
  else fail "unreachable - fix bridged networking before continuing"; fi
done

# --- Ports -------------------------------------------------------------------
if [ "$ROLE" = "control-plane" ]; then
  PORTS="6443 2379 2380 10250 10257 10259"
else
  PORTS="10250 10256"
fi
for p in $PORTS; do
  check "Port ${p} free"
  if ss -Hltn "sport = :${p}" 2>/dev/null | grep -q .; then
    soft "in use - fine if this node is already joined, otherwise reset first"
  else
    pass
  fi
done

# --- Time sync ---------------------------------------------------------------
check "Clock synchronised (NTP)"
if command -v timedatectl >/dev/null 2>&1; then
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    pass "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  else
    soft "not synced - TLS certs between nodes will break on clock skew"
  fi
else
  soft "timedatectl unavailable"
fi

# --- Firewall ----------------------------------------------------------------
check "Firewall (ufw)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  soft "ufw is active - open the control-plane/worker ports or disable it in a lab"
else
  pass "inactive"
fi

# --- Summary -----------------------------------------------------------------
echo
if [ "$FAILURES" -gt 0 ]; then
  err "${FAILURES} blocking problem(s), ${WARNINGS} warning(s). Fix the FAILs before continuing."
  exit 1
fi
ok "Preflight passed with ${WARNINGS} warning(s). This node is ready for 02-prep-node.sh."
