#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# labs/lib/verify.sh - shared assertions for the lab verify.sh scripts.
# Source it; do not run it.
#
# Every verify.sh works from anywhere that has a working kubectl:
#   * on the control plane (KUBECONFIG=/etc/kubernetes/admin.conf), or
#   * on your host after `./lab kubeconfig` (export KUBECONFIG=./kubeconfig)
# =============================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  V_RED=$'\033[31m'; V_GREEN=$'\033[32m'; V_YELLOW=$'\033[33m'
  V_DIM=$'\033[2m'; V_BOLD=$'\033[1m'; V_RESET=$'\033[0m'
else
  V_RED=''; V_GREEN=''; V_YELLOW=''; V_DIM=''; V_BOLD=''; V_RESET=''
fi

PASSED=0; FAILED=0
declare -a FAILURES=()

# Find a usable kubeconfig without making the user think about it.
if [ -z "${KUBECONFIG:-}" ]; then
  for candidate in "$HOME/.kube/config" /etc/kubernetes/admin.conf \
                   "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/kubeconfig"; do
    [ -r "$candidate" ] && { export KUBECONFIG="$candidate"; break; }
  done
fi
command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl not found. Run this on the control plane, or fetch a kubeconfig:"
  echo "  ./lab kubeconfig && export KUBECONFIG=\$PWD/kubeconfig"
  exit 1
}
kubectl version -o json >/dev/null 2>&1 || {
  echo "kubectl cannot reach the API server (KUBECONFIG=${KUBECONFIG:-unset})."
  exit 1
}

title() {
  echo
  echo "${V_BOLD}$1${V_RESET}"
  printf '%s%s%s\n' "$V_DIM" "$(printf '%.0s=' $(seq 1 ${#1}))" "$V_RESET"
}

# check <description> <command...> - passes when the command exits 0.
check() {
  local desc="$1"; shift
  printf '  %-58s' "$desc"
  if "$@" >/dev/null 2>&1; then
    printf '%sPASS%s\n' "$V_GREEN" "$V_RESET"; PASSED=$((PASSED+1))
  else
    printf '%sFAIL%s\n' "$V_RED" "$V_RESET"; FAILED=$((FAILED+1)); FAILURES+=("$desc")
  fi
}

# check_eq <description> <expected> <command...> - passes when stdout == expected.
check_eq() {
  local desc="$1" expected="$2"; shift 2
  local actual
  actual="$("$@" 2>/dev/null | tr -d '[:space:]')"
  printf '  %-58s' "$desc"
  if [ "$actual" = "$expected" ]; then
    printf '%sPASS%s\n' "$V_GREEN" "$V_RESET"; PASSED=$((PASSED+1))
  else
    printf '%sFAIL%s %s(got "%s", want "%s")%s\n' \
      "$V_RED" "$V_RESET" "$V_DIM" "$actual" "$expected" "$V_RESET"
    FAILED=$((FAILED+1)); FAILURES+=("${desc} - got '${actual}', want '${expected}'")
  fi
}

# check_ge <description> <minimum> <command...> - passes when stdout >= minimum.
check_ge() {
  local desc="$1" min="$2"; shift 2
  local actual
  actual="$("$@" 2>/dev/null | tr -d '[:space:]')"
  actual="${actual:-0}"
  printf '  %-58s' "$desc"
  if [ "$actual" -ge "$min" ] 2>/dev/null; then
    printf '%sPASS%s %s(%s)%s\n' "$V_GREEN" "$V_RESET" "$V_DIM" "$actual" "$V_RESET"
    PASSED=$((PASSED+1))
  else
    printf '%sFAIL%s %s(got "%s", want >= %s)%s\n' \
      "$V_RED" "$V_RESET" "$V_DIM" "$actual" "$min" "$V_RESET"
    FAILED=$((FAILED+1)); FAILURES+=("${desc} - got '${actual}', want >= ${min}")
  fi
}

hint() { printf '  %s-> %s%s\n' "$V_YELLOW" "$1" "$V_RESET"; }

summary() {
  echo
  local total=$((PASSED + FAILED))
  if [ "$FAILED" -eq 0 ]; then
    printf '%s  %d/%d checks passed - lab complete.%s\n' "$V_GREEN$V_BOLD" "$PASSED" "$total" "$V_RESET"
    echo
    return 0
  fi
  printf '%s  %d/%d checks passed, %d failed:%s\n' "$V_RED$V_BOLD" "$PASSED" "$total" "$FAILED" "$V_RESET"
  local f
  for f in "${FAILURES[@]}"; do echo "    - ${f}"; done
  echo
  echo "  Re-read the README for the tasks you have not completed yet."
  echo
  return 1
}
