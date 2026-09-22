#!/usr/bin/env bash
# down.sh — Tear down Vault Enterprise on OpenShift on VMware (vSphere IPI/UPI)
# See vault-on-openshift-vmware.md (Step 13 — Cleanup) for full details.
#
# This script removes everything created by up.sh in reverse order:
#   1. OpenShift Route
#   2. Helm release (StatefulSet, Services, ConfigMaps, RBAC, Webhooks)
#   3. PersistentVolumeClaims (Helm intentionally leaves these behind)
#   4. Enterprise license secret
#   5. anyuid SCC bindings
#   6. vault namespace / project
#
# It is safe to re-run — each step tolerates "not found" errors.
set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

NAMESPACE="vault"
HELM_RELEASE="vault"
VAULT_SECRET_NAME="vault-ent-license"
SLEEP=2

# ── helpers ───────────────────────────────────────────────────────────────────
step() {
  echo ""
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $*${RESET}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
}

info() {
  echo -e "${YELLOW}  ➜  $*${RESET}"
}

cmd() {
  echo -e "${DIM}  \$  $*${RESET}"
}

ok() {
  echo -e "${GREEN}  ✔  $*${RESET}"
}

warn() {
  echo -e "${YELLOW}  ⚠  $*${RESET}"
}

# run_tolerant: print and execute a command; warn (don't abort) on non-zero exit
run_tolerant() {
  cmd "$*"
  sleep "${SLEEP}"
  eval "$*" || warn "Command returned non-zero (resource may already be gone) — continuing"
}

# ── preflight ─────────────────────────────────────────────────────────────────
step "Preflight — checking cluster access"

if ! command -v oc &>/dev/null; then
  echo -e "${RED}  ✖  'oc' not found in PATH — aborting${RESET}"
  exit 1
fi
ok "oc found"

if ! command -v helm &>/dev/null; then
  echo -e "${RED}  ✖  'helm' not found in PATH — aborting${RESET}"
  exit 1
fi
ok "helm found"

if ! oc whoami &>/dev/null; then
  echo -e "${RED}  ✖  Not logged into OpenShift — run 'oc login' first${RESET}"
  exit 1
fi
ok "Logged in as: $(oc whoami) @ $(oc whoami --show-server)"

# ── step 1 ────────────────────────────────────────────────────────────────────
step "Step 1 — Delete the OpenShift Route"
info "Removes the edge-TLS Route that exposed Vault externally."

run_tolerant "oc delete route vault -n ${NAMESPACE}"
ok "Route removed"

# ── step 2 ────────────────────────────────────────────────────────────────────
step "Step 2 — Uninstall the Vault Helm release"
info "Removes the StatefulSet, Deployments, Services, ConfigMaps, ServiceAccounts,"
info "RBAC resources, and the MutatingWebhookConfiguration."
info "PersistentVolumeClaims are intentionally left behind by Helm — Step 3 cleans them."

run_tolerant "helm uninstall ${HELM_RELEASE} --namespace ${NAMESPACE}"
ok "Helm release uninstalled"

# ── step 3 ────────────────────────────────────────────────────────────────────
step "Step 3 — Delete PersistentVolumeClaims"
info "Helm does not delete PVCs created by StatefulSet volumeClaimTemplates."
info "This step removes all PVCs labelled app.kubernetes.io/name=vault."

run_tolerant "oc delete pvc -n ${NAMESPACE} -l app.kubernetes.io/name=vault"
ok "PVCs deleted"

# ── step 4 ────────────────────────────────────────────────────────────────────
step "Step 4 — Delete the Enterprise license secret"

run_tolerant "oc delete secret ${VAULT_SECRET_NAME} -n ${NAMESPACE}"
ok "License secret deleted"

# ── step 5 ────────────────────────────────────────────────────────────────────
step "Step 5 — Revoke the anyuid SCC bindings"
info "Removes the anyuid SCC grants added in up.sh Step 2."

run_tolerant "oc adm policy remove-scc-from-user anyuid -z vault -n ${NAMESPACE}"
run_tolerant "oc adm policy remove-scc-from-user anyuid -z vault-agent-injector -n ${NAMESPACE}"
ok "anyuid SCC bindings revoked"

# ── step 6 ────────────────────────────────────────────────────────────────────
step "Step 6 — Delete the vault namespace"
info "Switching shell context to 'default' first — if the shell context is"
info "still 'vault' when the project is deleted, OpenShift auto-recreates it"
info "immediately, leaving a half-initialized namespace behind."

run_tolerant "oc project default"

run_tolerant "oc delete project ${NAMESPACE}"

echo ""
info "Waiting for project '${NAMESPACE}' to be fully deleted (up to 120s)..."
cmd "oc wait --for=delete project/${NAMESPACE} --timeout=120s"
sleep "${SLEEP}"
oc wait --for=delete "project/${NAMESPACE}" --timeout=120s || \
  warn "Timeout waiting for project deletion — check 'oc get project ${NAMESPACE}'"

ok "Namespace '${NAMESPACE}' deleted"

# ── verify ────────────────────────────────────────────────────────────────────
step "Verify — confirming everything is gone"

echo ""
cmd "oc get project ${NAMESPACE}"
oc get project "${NAMESPACE}" 2>&1 || true

echo ""
cmd "helm list --namespace ${NAMESPACE}"
helm list --namespace "${NAMESPACE}" 2>/dev/null || true

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✔  Vault teardown complete.${RESET}"
echo -e "${GREEN}${BOLD}     vault-init.json has NOT been deleted — remove it${RESET}"
echo -e "${GREEN}${BOLD}     manually if it is no longer needed.${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
