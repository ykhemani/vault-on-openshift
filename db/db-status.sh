#!/usr/bin/env bash
# db-status.sh — Show the current state of the PostgreSQL PoV database
# See db.md for full details.
#
# Checks:
#   - Namespace and pod status
#   - Service endpoints (ClusterIP and NodePort)
#   - PostgreSQL connectivity (via oc exec)
#   - Users, roles, and demodb_reader grants
#   - customer table row count
#   - static-user connectivity
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
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
STATIC_USER_PASSWORD="${STATIC_USER_PASSWORD:-staticpass}"

# ── helpers ───────────────────────────────────────────────────────────────────
section() {
  echo ""
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
  echo -e "${CYAN}${BOLD}  $*${RESET}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
}

info()  { echo -e "${YELLOW}  ➜  $*${RESET}"; }
label() { echo -e "${YELLOW}${BOLD}  $*${RESET}"; }
ok()    { echo -e "${GREEN}  ✔  $*${RESET}"; }
warn()  { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
err()   { echo -e "${RED}  ✖  $*${RESET}"; }

run_show() {
  echo -e "${DIM}  \$  $*${RESET}"
  eval "$*" 2>&1 || true
}

# ── preflight ─────────────────────────────────────────────────────────────────
section "Preflight — cluster access"

if ! command -v oc &>/dev/null; then
  err "'oc' not found in PATH — aborting"; exit 1
fi
if ! oc whoami &>/dev/null; then
  err "Not logged into OpenShift — run 'oc login' first"; exit 1
fi
ok "Logged in as: $(oc whoami) @ $(oc whoami --show-server)"

# ── namespace ─────────────────────────────────────────────────────────────────
section "Namespace — ${NAMESPACE}"
if ! oc get project "${NAMESPACE}" &>/dev/null; then
  warn "Namespace '${NAMESPACE}' does not exist — has db-up.sh been run?"
  exit 0
fi
run_show "oc get project ${NAMESPACE}"

# ── pods ──────────────────────────────────────────────────────────────────────
section "Pods — namespace: ${NAMESPACE}"
run_show "oc get pods -n ${NAMESPACE} -o wide"

# Resolve the pod name for subsequent checks
DB_POD=$(oc get pod -n "${NAMESPACE}" -l name=postgresql \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)

if [[ -z "${DB_POD}" ]]; then
  warn "No postgresql pod found — skipping database-level checks"
  exit 0
fi

PHASE=$(oc get pod "${DB_POD}" -n "${NAMESPACE}" \
  --no-headers -o jsonpath='{.status.phase}' 2>/dev/null || true)
READY=$(oc get pod "${DB_POD}" -n "${NAMESPACE}" \
  --no-headers -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)

if [[ "${READY}" == "true" ]]; then
  ok "${DB_POD}: phase=${PHASE}  ready=true"
else
  warn "${DB_POD}: phase=${PHASE:-unknown}  ready=${READY:-false}"
fi

# ── services ──────────────────────────────────────────────────────────────────
section "Services — namespace: ${NAMESPACE}"
run_show "oc get svc -n ${NAMESPACE}"

echo ""
label "  NodePort for out-of-cluster access:"
NODE_PORT=$(oc get svc postgresql-external -n "${NAMESPACE}" \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
if [[ -n "${NODE_PORT}" ]]; then
  ok "postgresql-external NodePort: ${NODE_PORT}"
  info "  Connect with: PGPASSWORD=<password> psql -h <node-ip> -p ${NODE_PORT} -U postgres -d demodb"
  info "  Get a node IP with: oc get nodes -o wide"
else
  warn "postgresql-external service not found"
fi

# ── pvc ───────────────────────────────────────────────────────────────────────
section "PersistentVolumeClaim"
run_show "oc get pvc -n ${NAMESPACE}"

# ── resolve credentials from pod env vars ────────────────────────────────────
DB_USER=$(oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
  bash -c 'echo $POSTGRESQL_USER' 2>/dev/null)
DB_PASS=$(oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
  bash -c 'echo $POSTGRESQL_PASSWORD' 2>/dev/null)
DB_NAME=$(oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
  bash -c 'echo $POSTGRESQL_DATABASE' 2>/dev/null)

# ── connectivity ──────────────────────────────────────────────────────────────
section "PostgreSQL connectivity (user: ${DB_USER:-postgres}, db: ${DB_NAME:-demodb})"
if [[ "${PHASE}" != "Running" ]]; then
  warn "Pod is not Running — skipping connectivity checks"
else
  echo ""
  label "  PostgreSQL version:"
  run_show "oc exec -n ${NAMESPACE} ${DB_POD} -- \
    env PGPASSWORD='${DB_PASS}' psql -U '${DB_USER}' -d '${DB_NAME}' -c 'SELECT version();'"

  echo ""
  label "  Users and roles:"
  run_show "oc exec -n ${NAMESPACE} ${DB_POD} -- \
    env PGPASSWORD='${DB_PASS}' psql -U '${DB_USER}' -d '${DB_NAME}' -c '\du'"

  echo ""
  label "  demodb_reader grants on customer table:"
  run_show "oc exec -n ${NAMESPACE} ${DB_POD} -- \
    env PGPASSWORD='${DB_PASS}' psql -U '${DB_USER}' -d '${DB_NAME}' -c \
    \"SELECT grantee, privilege_type FROM information_schema.role_table_grants WHERE table_name='customer';\""

  echo ""
  label "  Row count in customer table:"
  run_show "oc exec -n ${NAMESPACE} ${DB_POD} -- \
    env PGPASSWORD='${DB_PASS}' psql -U '${DB_USER}' -d '${DB_NAME}' -c 'SELECT count(*) FROM customer;'"

  echo ""
  label "  Sample rows from customer table:"
  run_show "oc exec -n ${NAMESPACE} ${DB_POD} -- \
    env PGPASSWORD='${DB_PASS}' psql -U '${DB_USER}' -d '${DB_NAME}' -c 'SELECT * FROM customer LIMIT 5;'"
fi

# ── static-user connectivity ──────────────────────────────────────────────────
section "static-user connectivity"
if [[ "${PHASE}" != "Running" ]]; then
  warn "Pod is not Running — skipping"
else
  STATIC_RESULT=$(oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
    env PGPASSWORD="${STATIC_USER_PASSWORD}" \
    psql -U static-user -d "${DB_NAME:-demodb}" -c "SELECT count(*) FROM customer;" 2>&1 || true)
  if echo "${STATIC_RESULT}" | grep -q "count"; then
    ok "static-user can connect and read customer table"
    echo "${STATIC_RESULT}"
  else
    warn "static-user connection failed:"
    echo "${STATIC_RESULT}"
  fi
fi

# ── vault user connectivity ────────────────────────────────────────────────────
section "vault user connectivity"
if [[ "${PHASE}" != "Running" ]]; then
  warn "Pod is not Running — skipping"
else
  VAULT_DB_PASSWORD="${VAULT_DB_PASSWORD:-vaultpass}"
  VAULT_RESULT=$(oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
    env PGPASSWORD="${VAULT_DB_PASSWORD}" \
    psql -U vault -d "${DB_NAME:-demodb}" -c "SELECT current_user, pg_postmaster_start_time();" 2>&1 || true)
  if echo "${VAULT_RESULT}" | grep -q "vault"; then
    ok "vault user can connect"
    echo "${VAULT_RESULT}"
  else
    warn "vault user connection failed:"
    echo "${VAULT_RESULT}"
  fi
fi

# ── vault integration reference ───────────────────────────────────────────────
section "Vault database secrets engine reference"
echo ""
echo -e "  ${BOLD}In-cluster connection URL:${RESET}"
echo "    postgresql://{{username}}:{{password}}@postgresql.database.svc.cluster.local:5432/demodb"
echo ""
echo -e "  ${BOLD}Vault admin user:${RESET}   vault"
echo -e "  ${BOLD}Static rotation user:${RESET} static-user"
echo -e "  ${BOLD}Dynamic role creation SQL:${RESET}"
echo "    CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';"
echo "    GRANT demodb_reader TO \"{{name}}\";"
echo ""

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${CYAN}${BOLD}  Status check complete${RESET}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
