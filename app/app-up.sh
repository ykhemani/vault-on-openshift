#!/usr/bin/env bash
# app-up.sh — Build and deploy the Vault PoV demo web app on OpenShift (VMware)
#
# Builds the Flask app container using the OpenShift internal registry,
# deploys it in the 'app' namespace, and exposes it via an OpenShift Route.
#
# Credentials are read exclusively from /vault/secrets/db-creds (a file).
# This script creates a static Kubernetes Secret with:
#   username=static-user / password=staticpass
# and mounts it at /vault/secrets/db-creds inside the container.
#
# After VSO is configured in UC3, VSO will overwrite that same path with
# dynamically-issued credentials, and the deployment will restart via
# rolloutRestartTargets.
#
# Required environment variables (set before running):
#   APP_HOSTNAME  — full Route hostname, e.g. demoapp.apps.cluster.example.com
#
# Required:
#   oc logged in as cluster-admin
set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

NAMESPACE="app"
APP_NAME="vault-pov-app"
APP_VERSION="${APP_VERSION:-0.0.1}"
SECRET_NAME="vault-pov-db-creds"
DB_HOST="${DB_HOST:-postgresql.database.svc.cluster.local}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-demodb}"
STATIC_USER="static-user"
STATIC_USER_PASSWORD="${STATIC_USER_PASSWORD:-staticpass}"
CREDS_MOUNT="/vault/secrets"
CREDS_FILE="db-creds"
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

run() {
  echo -e "${DIM}  \$  $*${RESET}"
  sleep "${SLEEP}"
  eval "$*"
}

# ── preflight ─────────────────────────────────────────────────────────────────
section "Preflight — checking cluster access and tools"

for tool in oc; do
  if ! command -v "${tool}" &>/dev/null; then
    err "'${tool}' not found in PATH — aborting"; exit 1
  fi
  ok "${tool} found"
done

if ! oc whoami &>/dev/null; then
  err "Not logged into OpenShift — run 'oc login' first"; exit 1
fi
ok "Logged in as: $(oc whoami) @ $(oc whoami --show-server)"

APP_HOSTNAME="${APP_HOSTNAME:-}"
if [[ -z "${APP_HOSTNAME}" ]]; then
  warn "APP_HOSTNAME is not set — Route will use OpenShift's default ingress hostname"
  warn "To set a custom hostname: export APP_HOSTNAME=demoapp.apps.<cluster>.<domain>"
fi

# Warn if database namespace doesn't exist yet
if ! oc get project database &>/dev/null; then
  warn "The 'database' namespace does not exist — run db/db-up.sh first"
  warn "Continuing anyway (you can deploy the app before the DB is ready)"
fi

# ── namespace ─────────────────────────────────────────────────────────────────
section "Step 1 — Create the 'app' namespace"

if oc get project "${NAMESPACE}" &>/dev/null; then
  warn "Namespace '${NAMESPACE}' already exists — skipping"
else
  run "oc new-project ${NAMESPACE}"
  ok "Namespace '${NAMESPACE}' created"
fi

# ── static credentials secret ─────────────────────────────────────────────────
section "Step 2 — Create the static credentials Secret"
info "Secret: ${SECRET_NAME}  →  username=${STATIC_USER} / password=${STATIC_USER_PASSWORD}"
info "Mounted at ${CREDS_MOUNT}/${CREDS_FILE} inside the container."
info "In UC3 this Secret is replaced by VSO writing the same path."

if [[ "${STATIC_USER_PASSWORD}" == "staticpass" ]]; then
  warn "STATIC_USER_PASSWORD is using the default 'staticpass'."
  warn "Override with: export STATIC_USER_PASSWORD=<password>  (must match db-up.sh)"
fi

if oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  warn "Secret '${SECRET_NAME}' already exists — deleting and recreating"
  run "oc delete secret ${SECRET_NAME} -n ${NAMESPACE}"
fi

# Write the creds file content exactly as the app expects: key=value lines.
run "oc create secret generic ${SECRET_NAME} \
  --namespace=${NAMESPACE} \
  --from-literal=${CREDS_FILE}='username=${STATIC_USER}
password=${STATIC_USER_PASSWORD}'"

ok "Static credentials Secret created"

# ── build the image ───────────────────────────────────────────────────────────
section "Step 3 — Build the container image using OpenShift BuildConfig"
info "Uses the OpenShift internal registry — no external registry required."
info "Source: current directory (app/)   Image tag: ${APP_VERSION}"

if oc get buildconfig "${APP_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  warn "BuildConfig '${APP_NAME}' already exists — skipping new-build"
else
  run "oc new-build --binary --name=${APP_NAME} \
    --namespace=${NAMESPACE} \
    --strategy=docker"
fi

info "Starting binary build — uploading local app/ directory..."
run "oc start-build ${APP_NAME} \
  --namespace=${NAMESPACE} \
  --from-dir=. \
  --follow"

# Tag the built image with the version as well as latest
run "oc tag ${NAMESPACE}/${APP_NAME}:latest ${NAMESPACE}/${APP_NAME}:${APP_VERSION}"

ok "Image built and tagged as ${APP_NAME}:${APP_VERSION} and ${APP_NAME}:latest"

# ── deploy ────────────────────────────────────────────────────────────────────
section "Step 4 — Create Deployment manifest (paused from birth)"
info "Deployment is written directly as YAML with paused:true — no ReplicaSet is created"
info "until we explicitly resume after all patches are applied."

IMAGE="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/${APP_NAME}:${APP_VERSION}"

echo -e "${DIM}  \$  oc apply -f - (Deployment YAML)${RESET}"
sleep "${SLEEP}"
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  paused: true
  replicas: 1
  selector:
    matchLabels:
      deployment: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        deployment: ${APP_NAME}
    spec:
      containers:
        - name: ${APP_NAME}
          image: ${IMAGE}
          ports:
            - containerPort: 8080
              protocol: TCP
          env:
            - name: DB_HOST
              value: "${DB_HOST}"
            - name: DB_PORT
              value: "${DB_PORT}"
            - name: DB_NAME
              value: "${DB_NAME}"
            - name: APP_VERSION
              value: "${APP_VERSION}"
EOF

# Also create the Service so oc expose works later
echo -e "${DIM}  \$  oc apply -f - (Service YAML)${RESET}"
sleep "${SLEEP}"
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  selector:
    deployment: ${APP_NAME}
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
EOF

ok "Deployment created (paused) — no pods scheduled yet"

# ── mount the credentials secret ──────────────────────────────────────────────
section "Step 5 — Mount the credentials Secret into the pod"
info "Mounting Secret '${SECRET_NAME}' at ${CREDS_MOUNT}/${CREDS_FILE}"

run "oc set volume deployment/${APP_NAME} \
  --namespace=${NAMESPACE} \
  --add \
  --name=vault-secrets \
  --type=secret \
  --secret-name=${SECRET_NAME} \
  --mount-path=${CREDS_MOUNT} \
  --overwrite"

ok "Volume mount configured"

# ── inject pod name via downward api ──────────────────────────────────────────
section "Step 6 — Inject POD_NAME via Downward API"
info "Exposes the pod's own metadata.name as POD_NAME — shown top-right on the app page."
info "Uses the Kubernetes Downward API so every new pod sees its own name automatically."

# oc set env does not support valueFrom.fieldRef — use a JSON patch instead.
echo -e "${DIM}  \$  oc patch deployment/${APP_NAME} -n ${NAMESPACE} --type=json -p='[...]'${RESET}"
sleep "${SLEEP}"
oc patch deployment/"${APP_NAME}" -n "${NAMESPACE}" --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "POD_NAME",
      "valueFrom": {
        "fieldRef": {
          "fieldPath": "metadata.name"
        }
      }
    }
  }
]'

ok "POD_NAME Downward API env var configured"

# ── health probes ─────────────────────────────────────────────────────────────
section "Step 7 — Configure health probes"
info "Probes are set while the Deployment is still paused — no extra rollout triggered."

run "oc set probe deployment/${APP_NAME} \
  --namespace=${NAMESPACE} \
  --liveness \
  --get-url=http://:8080/healthz \
  --initial-delay-seconds=10 \
  --period-seconds=15"

run "oc set probe deployment/${APP_NAME} \
  --namespace=${NAMESPACE} \
  --readiness \
  --get-url=http://:8080/healthz \
  --initial-delay-seconds=5 \
  --period-seconds=10"

ok "Health probes configured"

# ── resume rollout — single pod start ─────────────────────────────────────────
section "Step 8 — Resume Deployment"
info "All patches applied. Resuming rollout — exactly one pod will start."

run "oc rollout resume deployment/${APP_NAME} --namespace=${NAMESPACE}"

# ── wait for rollout ──────────────────────────────────────────────────────────
section "Step 9 — Wait for app pod to be Ready"
info "Polling until the app pod is Running and Ready..."

for i in $(seq 1 60); do
  READY=$(oc get pods -n "${NAMESPACE}" -l "deployment=${APP_NAME}" \
    --no-headers 2>/dev/null | awk '{print $2}' | head -1)
  PHASE=$(oc get pods -n "${NAMESPACE}" -l "deployment=${APP_NAME}" \
    --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  echo -e "  ${DIM}[${i}/60] phase=${PHASE:-pending}  ready=${READY:-0/1}${RESET}"
  if [[ "${READY}" == "1/1" ]]; then
    break
  fi
  sleep 5
done
ok "App pod is Ready"

# ── expose via route ──────────────────────────────────────────────────────────
section "Step 10 — Expose via OpenShift Route"

EXPOSE_HOSTNAME_FLAG=""
if [[ -n "${APP_HOSTNAME}" ]]; then
  EXPOSE_HOSTNAME_FLAG="--hostname=${APP_HOSTNAME}"
fi

run "oc expose svc/${APP_NAME} \
  --namespace=${NAMESPACE} \
  --port=8080 \
  ${EXPOSE_HOSTNAME_FLAG}"

run "oc patch route ${APP_NAME} \
  --namespace=${NAMESPACE} \
  -p '{\"spec\":{\"tls\":{\"termination\":\"edge\",\"insecureEdgeTerminationPolicy\":\"Redirect\"}}}'"

APP_HOSTNAME=$(oc get route "${APP_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "<route-host>")

ok "Route created: https://${APP_HOSTNAME}"


# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✔  Vault PoV demo app is running!${RESET}"
echo -e "${GREEN}${BOLD}${RESET}"
echo -e "${GREEN}${BOLD}  URL:  https://${APP_HOSTNAME:-<run: oc get route vault-pov-app -n app>}${RESET}"
echo -e "${GREEN}${BOLD}${RESET}"
echo -e "${YELLOW}${BOLD}  ⚠  App is using static credentials (username=${STATIC_USER})${RESET}"
echo -e "${YELLOW}${BOLD}     Complete UC3 (VSO) to enable dynamic credential rotation.${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
info "Next: configure Vault dynamic DB secrets (UC2) in ../pov.md"
echo ""
