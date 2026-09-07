#!/usr/bin/env bash
# =============================================================================
# common.sh - shared helpers for every script in this lab.
# Source it, don't run it:   . "$(dirname "$0")/../lib/common.sh"
# =============================================================================

# Colours, but only when we are attached to a real terminal.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''; C_BOLD=''
fi

log()   { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()    { printf '%s [ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s [warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s [fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
info()  { printf '%s        %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()   { err "$*"; exit 1; }

# skip <reason> - announce that a step was already done and is being skipped.
skip()  { printf '%s [skip]%s %s\n' "$C_DIM" "$C_RESET" "$*"; }

# Print a section banner so long runs stay readable.
section() {
  printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "$(printf '%.0s-' $(seq 1 ${#1}))" "$C_RESET"
}

# require_root - re-exec under sudo if we are not root.
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must run as root. Re-run with: sudo $0 $*"
  fi
}

# need <command> [...] - fail unless every named command exists.
need() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] || die "Missing required command(s): ${missing[*]}"
}

# retry <attempts> <sleep-seconds> <command...>
retry() {
  local attempts=$1 delay=$2; shift 2
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      err "Command failed after ${attempts} attempts: $*"
      return 1
    fi
    warn "Attempt ${n}/${attempts} failed; retrying in ${delay}s..."
    n=$((n + 1)); sleep "$delay"
  done
}

# wait_for <timeout-seconds> <description> <command...>
# Polls the command every 5s until it succeeds or the timeout expires.
wait_for() {
  local timeout=$1 desc=$2; shift 2
  local waited=0
  info "Waiting for ${desc} (timeout ${timeout}s)..."
  while ! "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then
      err "Timed out after ${timeout}s waiting for ${desc}"
      return 1
    fi
    sleep 5; waited=$((waited + 5))
  done
  ok "${desc} is ready (${waited}s)"
}

# confirm <prompt> - ask before doing something destructive.
# Honours ASSUME_YES=1 for unattended runs.
confirm() {
  if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
  local reply
  printf '%s%s [y/N]%s ' "$C_YELLOW" "$1" "$C_RESET"
  read -r reply </dev/tty || return 1
  case "$reply" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

# backup_file <path> - keep a timestamped copy before we edit something.
backup_file() {
  [ -f "$1" ] || return 0
  local dest="$1.lab-bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$1" "$dest"
  info "Backed up $1 -> $dest"
}

# load_env - find and source lab.env, walking up from the script location.
# Sets LAB_ROOT to the repo root.
load_env() {
  local dir="${1:-$PWD}"
  local probe="$dir"
  while [ "$probe" != "/" ]; do
    if [ -f "$probe/lab.env" ] || [ -f "$probe/lab.env.example" ]; then
      LAB_ROOT="$probe"; break
    fi
    probe="$(dirname "$probe")"
  done
  [ -n "${LAB_ROOT:-}" ] || die "Could not locate lab.env - run from inside the repo."

  if [ -f "$LAB_ROOT/lab.env" ]; then
    # shellcheck disable=SC1090
    . "$LAB_ROOT/lab.env"
  else
    die "No lab.env found. Create one with:  cp lab.env.example lab.env  then edit it."
  fi
  export LAB_ROOT
}

# parse_workers - turn WORKERS="name:ip name:ip" into arrays WORKER_NAMES/WORKER_IPS.
parse_workers() {
  WORKER_NAMES=(); WORKER_IPS=()
  local pair
  for pair in ${WORKERS:-}; do
    WORKER_NAMES+=("${pair%%:*}")
    WORKER_IPS+=("${pair##*:}")
  done
}

# os_id - "ubuntu" / "debian" / "rhel" etc.
os_id() { . /etc/os-release 2>/dev/null && echo "${ID:-unknown}"; }

# Every node script starts with this so failures stop immediately.
strict_mode() { set -Eeuo pipefail; trap 'err "Failed at line $LINENO: $BASH_COMMAND"' ERR; }
