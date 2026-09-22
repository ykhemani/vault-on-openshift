#!/usr/bin/env bash
# app-status.sh — Show the current state of the Vault PoV demo web app
set -euo pipefail

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

NAMESPACE="app"
APP_NAME="vault-pov-app"
LOG_LINES="${LOG_LINES:-30}"

section() {
  echo ""
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $*${RESET}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
}

info()  { echo -e "${YELLOW}  ➜  $*${RESET}"; }
label() { echo -e "${BOLD}  $*${RESET}"; }
ok()    { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn()  { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
err()   { echo -e "${RED}  ✖  $*${RESET}"; }

run_show() {
  echo -e "${DIM}  \$  $*${RESET}"
  eval "$*" 2>&1 || true
}

# ── preflight ─────────────────────────────────────────────────────────────────
section "Preflight — cluster access"

if ! oc whoami &>/dev/null; then
  err "Not logged into OpenShift — run 'oc login' first"; exit 1
fi
ok "Logged in as: $(oc whoami) @ $(oc whoami --show-server)"

if ! oc get project "${NAMESPACE}" &>/dev/null; then
  warn "Namespace '${NAMESPACE}' does not exist — has app-up.sh been run?"
  exit 0
fi

# ── pods ──────────────────────────────────────────────────────────────────────
section "Pods"
run_show "oc get pods -n ${NAMESPACE} -o wide"

# Resolve the running app pod once — used by several checks below
APP_POD=$(oc get pod -n "${NAMESPACE}" -l "deployment=${APP_NAME}" \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 || true)
PHASE=""
POD_START=""

if [[ -n "${APP_POD}" ]]; then
  PHASE=$(oc get pod "${APP_POD}" -n "${NAMESPACE}" \
    --no-headers -o jsonpath='{.status.phase}' 2>/dev/null || true)
  POD_START=$(oc get pod "${APP_POD}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.startTime}' 2>/dev/null || true)
fi

# ── pod detail ────────────────────────────────────────────────────────────────
section "App pod detail"
if [[ -n "${APP_POD}" ]]; then
  ok "Pod:     ${APP_POD}"
  ok "Phase:   ${PHASE:-unknown}"
  [[ -n "${POD_START}" ]] && ok "Started: ${POD_START}"
  echo ""
  label "  Image and version:"
  oc get pod "${APP_POD}" -n "${NAMESPACE}" \
    -o jsonpath='  {range .spec.containers[*]}  {.name}: {.image}{"\n"}{end}' \
    2>/dev/null || true
  echo ""
  label "  APP_VERSION env var:"
  oc exec -n "${NAMESPACE}" "${APP_POD}" -- \
    env 2>/dev/null | grep "^APP_VERSION=" || echo "  APP_VERSION not set"
else
  warn "No app pod found"
fi

# ── deployment ────────────────────────────────────────────────────────────────
section "Deployment"
run_show "oc get deployment ${APP_NAME} -n ${NAMESPACE} 2>/dev/null || echo '  (not found)'"

# ── route ─────────────────────────────────────────────────────────────────────
section "Route"
run_show "oc get route -n ${NAMESPACE}"

APP_URL=$(oc get route "${APP_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)

# ── build history ─────────────────────────────────────────────────────────────
section "Build history"
run_show "oc get builds -n ${NAMESPACE} --sort-by='.metadata.creationTimestamp' 2>/dev/null \
  || echo '  (no builds found)'"

# ── credentials source ────────────────────────────────────────────────────────
section "Credentials in running pod (/vault/secrets/db-creds)"
if [[ -n "${APP_POD}" && "${PHASE}" == "Running" ]]; then
  CREDS=$(oc exec -n "${NAMESPACE}" "${APP_POD}" -- \
    cat /vault/secrets/db-creds 2>/dev/null || true)
  if [[ -n "${CREDS}" ]]; then
    USERNAME=$(echo "${CREDS}" | grep "^username=" | cut -d= -f2)
    if [[ "${USERNAME}" == v-* ]]; then
      ok "Creds source: VSO (dynamic)  username=${USERNAME}"
    else
      ok "Creds source: static secret  username=${USERNAME}"
    fi
    echo "${CREDS}" | sed 's/\(password=\).*/\1<redacted>/'
  else
    warn "/vault/secrets/db-creds not found in pod"
  fi
else
  warn "Pod not Running — skipping creds check"
fi

# ── VSO VaultDynamicSecret ────────────────────────────────────────────────────
section "VSO VaultDynamicSecret"
run_show "oc get vaultdynamicsecret -n ${NAMESPACE} 2>/dev/null || echo '  (none found — UC3 not yet configured)'"

# ── health check ──────────────────────────────────────────────────────────────
section "Health check (/healthz)"
if [[ -n "${APP_POD}" && "${PHASE}" == "Running" ]]; then
  HEALTH=$(oc exec -n "${NAMESPACE}" "${APP_POD}" -- \
    sh -c 'curl -sf http://127.0.0.1:8080/healthz 2>/dev/null \
      || python3 -c "import urllib.request; print(urllib.request.urlopen(\"http://127.0.0.1:8080/healthz\").read().decode())" 2>/dev/null' \
    || true)
  if [[ "${HEALTH}" == "ok" ]]; then
    ok "/healthz → ok"
  else
    warn "/healthz did not return 'ok': ${HEALTH:-no response}"
  fi
fi

# ── recent logs ───────────────────────────────────────────────────────────────
section "Recent app logs (last ${LOG_LINES} lines)"
if [[ -n "${APP_POD}" ]]; then
  echo -e "${DIM}  \$  oc logs -n ${NAMESPACE} ${APP_POD} --tail=${LOG_LINES}${RESET}"
  oc logs -n "${NAMESPACE}" "${APP_POD}" --tail="${LOG_LINES}" 2>&1 || true
else
  warn "No pod — no logs"
fi

# ── recent warning events ─────────────────────────────────────────────────────
section "Recent warning events"
run_show "oc get events -n ${NAMESPACE} --field-selector type=Warning \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || echo '  (none)'"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}${BOLD}  Status summary${RESET}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
if [[ -n "${APP_POD}" ]]; then
  echo -e "  Pod:     ${BOLD}${APP_POD}${RESET}  (${PHASE:-unknown})"
  [[ -n "${POD_START}" ]] && echo -e "  Started: ${BOLD}${POD_START}${RESET}"
fi
if [[ -n "${APP_URL}" ]]; then
  echo -e "  URL:    ${BOLD}https://${APP_URL}${RESET}"
fi
echo ""
