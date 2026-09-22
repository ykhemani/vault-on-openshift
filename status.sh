#!/usr/bin/env bash
# status.sh — Show the current state of Vault Enterprise on OpenShift on VMware
# See vault-on-openshift-vmware.md for full details.
#
# Reads VAULT_TOKEN from vault-init.json if present and VAULT_TOKEN is not
# already set. Set VAULT_TOKEN in the environment to override.
#
# VAULT_HOSTNAME must be set in the environment, e.g.:
#   export VAULT_HOSTNAME=vault.apps.<cluster-name>.<base-domain>
#
# Works on full OpenShift (OCP on vSphere) as well as non-OpenShift clusters
# (k3d, kind, vanilla k8s) where Routes, Projects, and SCCs are absent.
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
VAULT_INIT_FILE="vault-init.json"

# ── helpers ───────────────────────────────────────────────────────────────────
section() {
  echo ""
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $*${RESET}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
}

label() {
  echo -e "${YELLOW}${BOLD}  $*${RESET}"
}

ok() {
  echo -e "${GREEN}  ✔  $*${RESET}"
}

warn() {
  echo -e "${YELLOW}  ⚠  $*${RESET}"
}

err() {
  echo -e "${RED}  ✖  $*${RESET}"
}

run_show() {
  echo -e "${DIM}  \$  $*${RESET}"
  eval "$*" 2>&1 || true
}

# ── preflight ─────────────────────────────────────────────────────────────────
section "Preflight — cluster access"

if ! command -v oc &>/dev/null; then
  err "'oc' not found in PATH — aborting"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  err "Not logged into OpenShift — run 'oc login' first"
  exit 1
fi
ok "Logged in as: $(oc whoami) @ $(oc whoami --show-server)"

# VAULT_HOSTNAME: no default on VMware — must be set by the caller
if [[ -z "${VAULT_HOSTNAME:-}" ]]; then
  warn "VAULT_HOSTNAME is not set — Route URL and external Vault checks will be skipped"
  warn "  Set it with: export VAULT_HOSTNAME=vault.apps.<cluster-name>.<base-domain>"
  VAULT_ADDR_AVAILABLE=false
else
  ok "VAULT_HOSTNAME: ${VAULT_HOSTNAME}"
  VAULT_ADDR_AVAILABLE=true
  export VAULT_ADDR="https://${VAULT_HOSTNAME}"
fi

# Probe for OpenShift-specific APIs (absent on k3d / vanilla k8s)
HAS_ROUTES=$(oc api-resources --api-group=route.openshift.io \
  --no-headers 2>/dev/null | grep -c '^route' || true)
HAS_PROJECTS=$(oc api-resources --api-group=project.openshift.io \
  --no-headers 2>/dev/null | grep -c '^project' || true)
HAS_SCCS=$(oc api-resources --api-group=security.openshift.io \
  --no-headers 2>/dev/null | grep -c '^securitycontextconstraint' || true)

# Resolve Vault token: already-exported env var > vault-init.json > skip
VAULT_TOKEN_SOURCE=""
if [[ -n "${VAULT_TOKEN:-}" ]]; then
  VAULT_TOKEN_SOURCE="environment"
  ok "VAULT_TOKEN already set in environment"
elif [[ -f "${VAULT_INIT_FILE}" ]]; then
  VAULT_TOKEN=$(python3 -c \
    "import json; d=json.load(open('${VAULT_INIT_FILE}')); print(d['root_token'])" \
    2>/dev/null || true)
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    VAULT_TOKEN_SOURCE="vault-init.json"
    ok "VAULT_TOKEN loaded from ${VAULT_INIT_FILE}"
  else
    warn "Could not parse root_token from ${VAULT_INIT_FILE}"
  fi
else
  warn "VAULT_TOKEN not set and ${VAULT_INIT_FILE} not found — Raft/license checks will be skipped"
fi
export VAULT_TOKEN="${VAULT_TOKEN:-}"

# Validate the token against the live cluster.
# Uses -tls-skip-verify so self-signed Route certs don't cause false failures.
# A 403 here means the token is expired or revoked — common if the original
# root token was rotated after initial setup. Export a fresh token with:
#   export VAULT_TOKEN=<current-token>
VAULT_TOKEN_VALID=false
if [[ -n "${VAULT_TOKEN}" && "${VAULT_ADDR_AVAILABLE}" == "true" ]]; then
  if vault token lookup -tls-skip-verify -format=json &>/dev/null; then
    VAULT_TOKEN_VALID=true
    ok "VAULT_TOKEN is valid (source: ${VAULT_TOKEN_SOURCE:-unknown})"
  else
    warn "VAULT_TOKEN was rejected by Vault at ${VAULT_ADDR}"
    if [[ "${VAULT_TOKEN_SOURCE}" == "vault-init.json" ]]; then
      warn "  The root token in vault-init.json may have been revoked after initial setup."
      warn "  Export a current token:  export VAULT_TOKEN=<token>"
    else
      warn "  Token may be expired, revoked, or from a different cluster."
      warn "  Export a current token:  export VAULT_TOKEN=<token>"
    fi
  fi
fi

# ── namespace ─────────────────────────────────────────────────────────────────
section "Namespace — ${NAMESPACE}"
if [[ "${HAS_PROJECTS}" -gt 0 ]]; then
  run_show "oc get project ${NAMESPACE} 2>/dev/null || echo '  (project not found)'"
else
  warn "Projects API not available (non-OpenShift cluster) — using 'oc get namespace'"
  run_show "oc get namespace ${NAMESPACE} 2>/dev/null || echo '  (namespace not found)'"
fi

# ── helm release ──────────────────────────────────────────────────────────────
section "Helm release — ${HELM_RELEASE}"
run_show "helm list --namespace ${NAMESPACE}"

# ── pods ──────────────────────────────────────────────────────────────────────
section "Pods — namespace: ${NAMESPACE}"
run_show "oc get pods -n ${NAMESPACE} -o wide"

# per-pod sealed/init status
echo ""
label "  Per-pod Vault seal status:"
for pod in vault-0 vault-1 vault-2; do
  PHASE=$(oc get pod "${pod}" -n "${NAMESPACE}" \
    --no-headers -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "${PHASE}" != "Running" ]]; then
    warn "${pod}: phase=${PHASE:-unknown} — skipping vault status check"
    continue
  fi
  STATUS=$(oc exec -n "${NAMESPACE}" "${pod}" -- \
    vault status -tls-skip-verify -format=json 2>/dev/null || true)
  if [[ -z "${STATUS}" ]]; then
    warn "${pod}: could not retrieve vault status"
    continue
  fi
  SEALED=$(echo "${STATUS}"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sealed','?'))"       2>/dev/null || echo "?")
  INIT=$(echo "${STATUS}"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('initialized','?'))"  2>/dev/null || echo "?")
  HA_MODE=$(echo "${STATUS}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ha_enabled','?'))"   2>/dev/null || echo "?")
  if [[ "${SEALED}" == "False" || "${SEALED}" == "false" ]]; then
    ok "${pod}: initialized=${INIT}  sealed=${SEALED}  ha_enabled=${HA_MODE}"
  else
    warn "${pod}: initialized=${INIT}  sealed=${SEALED}  ha_enabled=${HA_MODE}"
  fi
done

# ── services ──────────────────────────────────────────────────────────────────
section "Services — namespace: ${NAMESPACE}"
run_show "oc get svc -n ${NAMESPACE}"

# ── route ─────────────────────────────────────────────────────────────────────
section "OpenShift Route"
if [[ "${HAS_ROUTES}" -gt 0 ]]; then
  run_show "oc get route -n ${NAMESPACE}"
else
  warn "Routes API not available (non-OpenShift cluster) — checking Ingress instead"
  run_show "oc get ingress -n ${NAMESPACE} 2>/dev/null || echo '  (no Ingress resources found)'"
fi

# ── pvcs ──────────────────────────────────────────────────────────────────────
section "PersistentVolumeClaims — namespace: ${NAMESPACE}"
run_show "oc get pvc -n ${NAMESPACE}"

# Highlight StorageClass in use (helpful for VMware troubleshooting)
echo ""
label "  StorageClass in use by Vault PVCs:"
run_show "oc get pvc -n ${NAMESPACE} \
  -o jsonpath='{range .items[*]}{.metadata.name}{\"  storageClass=\"}{.spec.storageClassName}{\"  status=\"}{.status.phase}{\"\\n\"}{end}' \
  2>/dev/null || echo '  (no PVCs found)'"

# ── statefulset ───────────────────────────────────────────────────────────────
section "StatefulSet"
run_show "oc get statefulset -n ${NAMESPACE}"

# ── injector deployment ───────────────────────────────────────────────────────
section "Vault Agent Injector deployment"
run_show "oc get deploy vault-agent-injector -n ${NAMESPACE} 2>/dev/null || echo '  (not found)'"

# ── mutating webhook ──────────────────────────────────────────────────────────
section "MutatingWebhookConfiguration"
run_show "oc get mutatingwebhookconfiguration vault-agent-injector-cfg 2>/dev/null || echo '  (not found)'"

# ── service accounts & scc ────────────────────────────────────────────────────
section "Service Accounts and anyuid SCC bindings"
run_show "oc get serviceaccount -n ${NAMESPACE} vault vault-agent-injector 2>/dev/null || true"
echo ""
label "  anyuid SCC — principals that include vault service accounts:"
if [[ "${HAS_SCCS}" -gt 0 ]]; then
  run_show "oc adm policy who-can use scc anyuid 2>/dev/null | grep -i vault || echo '  (none found)'"
else
  warn "SCCs not available (non-OpenShift cluster) — skipping anyuid check"
fi

# ── license secret ────────────────────────────────────────────────────────────
section "Enterprise license secret"
run_show "oc get secret vault-ent-license -n ${NAMESPACE} 2>/dev/null || echo '  (not found)'"

# ── node topology labels (VMware-specific) ────────────────────────────────────
section "Node topology labels (VMware — zone labels may be absent)"
run_show "oc get nodes -o custom-columns=\
'NAME:.metadata.name,\
HOSTNAME-LABEL:.metadata.labels.kubernetes\.io/hostname,\
ZONE-LABEL:.metadata.labels.topology\.kubernetes\.io/zone' \
2>/dev/null || true"

# ── vault-level checks (require valid token + hostname) ───────────────────────
if [[ "${VAULT_ADDR_AVAILABLE}" == "true" ]]; then
  section "Vault status (via ${VAULT_ADDR})"
  run_show "vault status"
else
  section "Vault status (skipped — VAULT_HOSTNAME not set)"
  warn "Set VAULT_HOSTNAME to enable external Vault checks"
fi

if [[ "${VAULT_TOKEN_VALID}" == "true" ]]; then
  section "Raft peers"
  run_show "vault operator raft list-peers"

  section "Enterprise license"
  run_show "vault license get"
else
  section "Raft peers + Enterprise license (skipped — token invalid or absent)"
  if [[ -z "${VAULT_TOKEN}" ]]; then
    warn "No VAULT_TOKEN — set it or provide vault-init.json"
  else
    warn "Provide a valid root or admin token to see these:"
    warn "  export VAULT_TOKEN=<token>   or update vault-init.json"
  fi
fi

# ── recent events ─────────────────────────────────────────────────────────────
section "Recent events — namespace: ${NAMESPACE} (warnings only)"
run_show "oc get events -n ${NAMESPACE} --field-selector type=Warning \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || echo '  (no warning events)'"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}${BOLD}  Status check complete${RESET}"
if [[ "${VAULT_ADDR_AVAILABLE}" == "true" ]]; then
  echo -e "${CYAN}${BOLD}  Vault UI: https://${VAULT_HOSTNAME}/ui${RESET}"
else
  echo -e "${CYAN}${BOLD}  Vault UI: set VAULT_HOSTNAME to get the URL${RESET}"
fi
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
