#!/usr/bin/env bash
# db-down.sh — Tear down PostgreSQL for the Vault PoV
# See db.md for full details.
#
# Removes:
#   - The 'database' namespace and everything in it
#     (Deployment, Services, PVC, ConfigMap, Secret)
#
# Does NOT touch Vault — clean up any Vault database secrets engine
# configuration separately via ../pov.md.
set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

NAMESPACE="database"
SLEEP=2

# ── helpers ───────────────────────────────────────────────────────────────────
section() {
  echo ""
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $*${RESET}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
}

info() { echo -e "${YELLOW}  ➜  $*${RESET}"; }
ok()   { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
err()  { echo -e "${RED}  ✖  $*${RESET}"; }

run_tolerant() {
  echo -e "${DIM}  \$  $*${RESET}"
  sleep "${SLEEP}"
  eval "$*" || warn "Command returned non-zero (resource may already be gone) — continuing"
}

# ── preflight ─────────────────────────────────────────────────────────────────
section "Preflight — checking cluster access"

if ! command -v oc &>/dev/null; then
  err "'oc' not found in PATH — aborting"; exit 1
fi
if ! oc whoami &>/dev/null; then
  err "Not logged into OpenShift — run 'oc login' first"; exit 1
fi
ok "Logged in as: $(oc whoami) @ $(oc whoami --show-server)"

if ! oc get project "${NAMESPACE}" &>/dev/null; then
  warn "Namespace '${NAMESPACE}' does not exist — nothing to do"
  exit 0
fi

# ── warn about vault ──────────────────────────────────────────────────────────
section "Reminder — Vault configuration is not cleaned up here"
warn "If you have configured the Vault database secrets engine against this"
warn "PostgreSQL instance, disable it in Vault before or after running this"
warn "script. See ../pov.md for the steps."
echo ""
info "Continuing in ${SLEEP}s..."
sleep "${SLEEP}"

# ── delete namespace ──────────────────────────────────────────────────────────
section "Deleting namespace '${NAMESPACE}' and all resources within it"
info "This removes the Deployment, Services, PVC, ConfigMap, and Secret."

run_tolerant "oc project default"
run_tolerant "oc delete project ${NAMESPACE}"

echo ""
info "Waiting for namespace '${NAMESPACE}' to be fully deleted (up to 120s)..."
echo -e "${DIM}  \$  oc wait --for=delete project/${NAMESPACE} --timeout=120s${RESET}"
sleep "${SLEEP}"
oc wait --for=delete "project/${NAMESPACE}" --timeout=120s \
  && ok "Namespace '${NAMESPACE}' fully deleted" \
  || warn "Timed out waiting — check: oc get project ${NAMESPACE}"

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✔  PostgreSQL teardown complete${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
info "Verify nothing remains:"
echo -e "${DIM}  \$  oc get project ${NAMESPACE}   # should return 'not found'${RESET}"
echo ""
