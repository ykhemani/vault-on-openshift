#!/usr/bin/env bash
# db-up.sh — Deploy PostgreSQL for the Vault PoV
# See db.md for full details.
#
# Creates:
#   - namespace:        database
#   - PostgreSQL:       via OpenShift postgresql-persistent template
#   - ClusterIP svc:    postgresql.database.svc.cluster.local:5432
#   - NodePort svc:     postgresql-external (for out-of-cluster access)
#   - database:         demodb
#   - users:            postgres (superuser), vault (superuser), static-user
#   - role:             demodb_reader (SELECT on all tables)
#   - table:            customer (first_name, last_name, street, city, state, postal)
#   - sample data:      20 rows
#
# Required environment variables (defaults shown):
#   POSTGRES_PASSWORD      postgres
#   VAULT_DB_PASSWORD      vaultpass
#   STATIC_USER_PASSWORD   staticpass
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
SVC_NAME="postgresql"
SLEEP=2

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
VAULT_DB_PASSWORD="${VAULT_DB_PASSWORD:-vaultpass}"
STATIC_USER_PASSWORD="${STATIC_USER_PASSWORD:-staticpass}"

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

run() {
  echo -e "${DIM}  \$  $*${RESET}"
  sleep "${SLEEP}"
  eval "$*"
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

if ! oc get template postgresql-persistent -n openshift &>/dev/null; then
  err "Template 'postgresql-persistent' not found in the openshift namespace"
  err "This template is included with OpenShift — check your cluster version"
  exit 1
fi
ok "Template postgresql-persistent found"

if [[ "${POSTGRES_PASSWORD}" == "postgres" ]]; then
  warn "POSTGRES_PASSWORD is using the default value — consider setting a stronger password"
fi
if [[ "${VAULT_DB_PASSWORD}" == "vaultpass" ]]; then
  warn "VAULT_DB_PASSWORD is using the default value — consider setting a stronger password"
fi
if [[ "${STATIC_USER_PASSWORD}" == "staticpass" ]]; then
  warn "STATIC_USER_PASSWORD is using the default value — consider setting a stronger password"
fi

# ── namespace ─────────────────────────────────────────────────────────────────
section "Step 1 — Create the 'database' namespace"

run "oc new-project ${NAMESPACE}"
ok "Namespace '${NAMESPACE}' created"

# ── deploy postgresql ─────────────────────────────────────────────────────────
section "Step 2 — Deploy PostgreSQL via postgresql-persistent template"
info "Using Red Hat's supported PostgreSQL 15 (15-el9) image from the built-in template"
info "Database: demodb  |  User: postgres"

run "oc new-app postgresql-persistent \
  --namespace=${NAMESPACE} \
  --param DATABASE_SERVICE_NAME=${SVC_NAME} \
  --param POSTGRESQL_DATABASE=demodb \
  --param POSTGRESQL_USER=postgres \
  --param POSTGRESQL_PASSWORD=${POSTGRES_PASSWORD} \
  --param MEMORY_LIMIT=512Mi \
  --param VOLUME_CAPACITY=1Gi \
  --param POSTGRESQL_VERSION=15-el9"

ok "PostgreSQL deployment created"

# ── wait for pod ──────────────────────────────────────────────────────────────
section "Step 3 — Wait for PostgreSQL pod to be Ready"
info "Polling until the postgresql pod is Running and Ready..."

for i in $(seq 1 60); do
  PHASE=$(oc get pods -n "${NAMESPACE}" -l name=postgresql \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  READY=$(oc get pods -n "${NAMESPACE}" -l name=postgresql \
    --no-headers 2>/dev/null | awk '{print $2}' | head -1)
  echo -e "  ${DIM}[${i}/60] phase=${PHASE:-pending}  ready=${READY:-0/1}${RESET}"
  if [[ "${READY}" == "1/1" ]]; then
    break
  fi
  sleep 5
done

DB_POD=$(oc get pod -n "${NAMESPACE}" -l name=postgresql \
  --no-headers -o custom-columns=':metadata.name' | head -1)

if [[ -z "${DB_POD}" ]]; then
  err "Could not find a running postgresql pod — aborting"
  exit 1
fi
ok "PostgreSQL pod ready: ${DB_POD}"

# ── init sql ──────────────────────────────────────────────────────────────────
section "Step 4 — Create users, roles, schema, and sample data"
info "Applying init SQL to ${DB_POD}"

# The template stores credentials in env vars inside the pod.
# We read them back so we connect with exactly the credentials that were set up,
# regardless of any template defaults. PGPASSWORD avoids an interactive prompt.
DB_USER=$(oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
  bash -c 'echo $POSTGRESQL_USER' 2>/dev/null)
DB_PASS=$(oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
  bash -c 'echo $POSTGRESQL_PASSWORD' 2>/dev/null)
DB_NAME=$(oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
  bash -c 'echo $POSTGRESQL_DATABASE' 2>/dev/null)

info "Connecting as '${DB_USER}' to database '${DB_NAME}'"

# The postgresql-persistent template on some OpenShift versions does not
# create the POSTGRESQL_DATABASE — it only creates the default 'postgres'
# database. Create demodb explicitly if it doesn't exist.
DB_EXISTS=$(oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
  env PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -d postgres \
  -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" 2>/dev/null || true)

if [[ "${DB_EXISTS}" != "1" ]]; then
  info "Database '${DB_NAME}' not found — creating it..."
  oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
    env PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -d postgres \
    -c "CREATE DATABASE \"${DB_NAME}\";"
  ok "Database '${DB_NAME}' created"
else
  ok "Database '${DB_NAME}' already exists"
fi

# Write the init SQL to a temp file and copy it into the pod with oc exec.
# A heredoc piped directly through 'oc exec' is unreliable — the shell
# processes variable substitution locally, then oc exec passes stdin, but
# set -euo pipefail combined with oc's stdin handling can silently drop the
# SQL. Writing to a temp file and using 'oc exec -- psql -f -' is reliable.
INIT_SQL=$(mktemp /tmp/vault-pov-init-XXXXXX.sql)
trap 'rm -f "${INIT_SQL}"' EXIT

cat > "${INIT_SQL}" << SQL
-- ── vault admin user ──────────────────────────────────────────────────────
-- Vault uses this superuser to create and revoke dynamic credentials and to
-- rotate the static-user password. It must have CREATEROLE and LOGIN.
CREATE USER vault WITH SUPERUSER LOGIN PASSWORD '${VAULT_DB_PASSWORD}';

-- ── static demo user ──────────────────────────────────────────────────────
-- Used to demonstrate Vault static credential rotation. Vault will rotate
-- this user's password on a configured schedule.
CREATE USER "static-user" WITH LOGIN PASSWORD '${STATIC_USER_PASSWORD}';

-- ── demodb_reader role ────────────────────────────────────────────────────
-- Granted to every dynamically-created user so they can SELECT from all
-- tables in demodb without needing per-user grants. This is standard
-- PostgreSQL practice for shared read access.
CREATE ROLE demodb_reader;
GRANT CONNECT ON DATABASE ${DB_NAME} TO demodb_reader;
GRANT USAGE ON SCHEMA public TO demodb_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO demodb_reader;
-- Ensure tables created in the future are also accessible
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO demodb_reader;

-- Grant demodb_reader to static-user so it can read data during the PoV
GRANT demodb_reader TO "static-user";

-- ── customer table ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customer (
  id         SERIAL PRIMARY KEY,
  first_name VARCHAR(50)  NOT NULL,
  last_name  VARCHAR(50)  NOT NULL,
  street     VARCHAR(100) NOT NULL,
  city       VARCHAR(50)  NOT NULL,
  state      CHAR(2)      NOT NULL,
  postal     VARCHAR(10)  NOT NULL
);

-- ── sample data (20 rows) ─────────────────────────────────────────────────
INSERT INTO customer (first_name, last_name, street, city, state, postal) VALUES
  ('Alice',   'Anderson',  '123 Maple St',       'Springfield',   'IL', '62701'),
  ('Bob',     'Baker',     '456 Oak Ave',         'Shelbyville',   'IL', '62565'),
  ('Carol',   'Clark',     '789 Pine Rd',         'Capital City',  'IL', '62702'),
  ('David',   'Davis',     '321 Elm St',          'Ogdenville',    'MN', '55001'),
  ('Eve',     'Evans',     '654 Cedar Ln',        'North Haverbrook','MN','55002'),
  ('Frank',   'Foster',    '987 Birch Blvd',      'Brockway',      'MN', '55003'),
  ('Grace',   'Green',     '111 Walnut Way',      'Austin',        'TX', '73301'),
  ('Hank',    'Harris',    '222 Chestnut Ct',     'Dallas',        'TX', '75201'),
  ('Iris',    'Ingram',    '333 Spruce Dr',       'Houston',       'TX', '77001'),
  ('Jack',    'Johnson',   '444 Willow Walk',     'San Antonio',   'TX', '78201'),
  ('Karen',   'King',      '555 Ash Ave',         'Phoenix',       'AZ', '85001'),
  ('Leo',     'Lewis',     '666 Poplar Pl',       'Tucson',        'AZ', '85701'),
  ('Mia',     'Martin',    '777 Sycamore St',     'Mesa',          'AZ', '85201'),
  ('Nate',    'Nelson',    '888 Magnolia Rd',     'Portland',      'OR', '97201'),
  ('Olivia',  'Owen',      '999 Dogwood Dr',      'Salem',         'OR', '97301'),
  ('Paul',    'Parker',    '101 Redwood Ln',      'Eugene',        'OR', '97401'),
  ('Quinn',   'Quinn',     '202 Sequoia St',      'Seattle',       'WA', '98101'),
  ('Rachel',  'Reed',      '303 Cypress Ct',      'Tacoma',        'WA', '98401'),
  ('Sam',     'Scott',     '404 Juniper Blvd',    'Spokane',       'WA', '99201'),
  ('Tina',    'Taylor',    '505 Hawthorn Pl',     'Bellevue',      'WA', '98004');
SQL

# Pipe the SQL file into the pod via stdin
oc exec -i -n "${NAMESPACE}" "${DB_POD}" -- \
  env PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -d "${DB_NAME}" < "${INIT_SQL}"

ok "Init SQL applied"

# ── verify init ───────────────────────────────────────────────────────────────
section "Step 5 — Verify database objects"

echo ""
info "Users and roles:"
oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
  env PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -d "${DB_NAME}" -c "\du"

echo ""
info "Row count in customer table:"
oc exec -n "${NAMESPACE}" "${DB_POD}" -- \
  env PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT count(*) FROM customer;"

# ── nodeport service ──────────────────────────────────────────────────────────
section "Step 6 — Expose PostgreSQL via NodePort for out-of-cluster access"
info "Creates a second Service (postgresql-external) on a NodePort so the"
info "database can be reached from outside the cluster — useful for"
info "demonstrating that Vault and the app are infrastructure-independent."

oc apply -n "${NAMESPACE}" -f - << 'YAML'
apiVersion: v1
kind: Service
metadata:
  name: postgresql-external
  namespace: database
  labels:
    app: postgresql-external
spec:
  type: NodePort
  selector:
    name: postgresql
  ports:
    - name: postgresql
      port: 5432
      targetPort: 5432
YAML

NODE_PORT=$(oc get svc postgresql-external -n "${NAMESPACE}" \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
ok "NodePort service created — port: ${NODE_PORT:-<pending>}"
info "Connect from outside the cluster:"
info "  PGPASSWORD=<password> psql -h <node-ip> -p ${NODE_PORT:-<nodeport>} -U postgres -d demodb"
info "  Get a node IP with: oc get nodes -o wide"

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✔  PostgreSQL is ready for the Vault PoV${RESET}"
echo -e "${GREEN}${BOLD}${RESET}"
echo -e "${GREEN}${BOLD}  In-cluster:    postgresql.database.svc.cluster.local:5432${RESET}"
echo -e "${GREEN}${BOLD}  NodePort:      <node-ip>:${NODE_PORT:-<nodeport>}${RESET}"
echo -e "${GREEN}${BOLD}  Database:      demodb${RESET}"
echo -e "${GREEN}${BOLD}  Vault user:    vault / ${VAULT_DB_PASSWORD}${RESET}"
echo -e "${GREEN}${BOLD}  Static user:   static-user / ${STATIC_USER_PASSWORD}${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
info "Next: see ../pov.md for Vault database secrets engine configuration"
echo ""
