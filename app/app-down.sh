#!/usr/bin/env bash
# app-down.sh — Tear down the Vault PoV demo web app
set -euo pipefail

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

NAMESPACE="app"
SLEEP=2

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

if ! oc whoami &>/dev/null; then
  err "Not logged into OpenShift — run 'oc login' first"; exit 1
fi
ok "Logged in as: $(oc whoami) @ $(oc whoami --show-server)"

if ! oc get project "${NAMESPACE}" &>/dev/null; then
  warn "Namespace '${NAMESPACE}' does not exist — nothing to do"
  exit 0
fi

# ── prune old images before namespace deletion ────────────────────────────────
section "Pruning old vault-pov-app images from internal registry"
info "Deleting all vault-pov-app image objects — blobs are reclaimed by the registry pruner."

OLD_IMAGES=$(oc get images 2>/dev/null \
  | grep "vault-pov-app" \
  | awk '{print $1}' || true)

if [[ -n "${OLD_IMAGES}" ]]; then
  echo "${OLD_IMAGES}" | while read -r img; do
    echo -e "${DIM}  \$  oc delete image ${img}${RESET}"
    oc delete image "${img}" --ignore-not-found 2>/dev/null \
      && ok "Deleted image ${img}" \
      || warn "Could not delete ${img} (may require cluster-admin registry access)"
  done
else
  info "No vault-pov-app images found"
fi

# ── delete namespace ──────────────────────────────────────────────────────────
section "Deleting namespace '${NAMESPACE}' and all resources within it"

run_tolerant "oc project default"
run_tolerant "oc delete project ${NAMESPACE}"

echo ""
info "Waiting for namespace '${NAMESPACE}' to be fully deleted (up to 120s)..."
echo -e "${DIM}  \$  oc wait --for=delete project/${NAMESPACE} --timeout=120s${RESET}"
sleep "${SLEEP}"
oc wait --for=delete "project/${NAMESPACE}" --timeout=120s \
  && ok "Namespace '${NAMESPACE}' fully deleted" \
  || warn "Timed out — check: oc get project ${NAMESPACE}"

# ── prune registry blobs ──────────────────────────────────────────────────────
section "Pruning unreferenced blobs from internal registry"
info "This reclaims storage for images deleted above."
info "Running: oc adm prune images --keep-tag-revisions=1 --keep-younger-than=0 --confirm"
oc adm prune images \
  --keep-tag-revisions=1 \
  --keep-younger-than=0 \
  --confirm 2>/dev/null \
  && ok "Registry pruned" \
  || warn "Registry prune failed or requires additional permissions — run manually if needed"

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✔  App teardown complete${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
