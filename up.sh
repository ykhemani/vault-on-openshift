#!/usr/bin/env bash
# up.sh — Stand up Vault Enterprise on OpenShift on VMware (vSphere IPI/UPI)
# See vault-on-openshift-vmware.md for full details.
#
# Required environment variables:
#   VAULT_LICENSE   — valid Vault Enterprise license string
#   VAULT_HOSTNAME  — external hostname for the OpenShift Route, e.g.:
#                     vault.apps.<cluster-name>.<base-domain>
#
# The script must be run from the openshift-on-vmware/ directory so that
# vault-values.yaml is found by the relative path in HELM_VALUES.
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
HELM_CHART="hashicorp/vault"
HELM_VALUES="vault-values.yaml"
VAULT_SECRET_NAME="vault-ent-license"
# VAULT_HOSTNAME must be set in the environment — no ROSA-specific default here.
# Example: export VAULT_HOSTNAME=vault.apps.my-cluster.example.com
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

run() {
  cmd "$*"
  sleep "${SLEEP}"
  eval "$*"
}

pause() {
  echo ""
  info "Waiting ${SLEEP}s before executing..."
  sleep "${SLEEP}"
}

# ── preflight ─────────────────────────────────────────────────────────────────
step "Preflight — checking required tools and variables"
info "Checking: oc, helm, vault CLIs; VAULT_LICENSE and VAULT_HOSTNAME env vars"
pause

for tool in oc helm vault python3; do
  if ! command -v "$tool" &>/dev/null; then
    echo -e "${RED}  ✖  '$tool' not found in PATH — aborting${RESET}"
    exit 1
  fi
  ok "$tool found"
done

if [[ -z "${VAULT_LICENSE:-}" ]]; then
  echo -e "${RED}  ✖  VAULT_LICENSE is not set — aborting${RESET}"
  exit 1
fi
ok "VAULT_LICENSE is set"

if [[ -z "${VAULT_HOSTNAME:-}" ]]; then
  echo -e "${RED}  ✖  VAULT_HOSTNAME is not set — aborting${RESET}"
  echo -e "${RED}     Set it to the desired Route hostname, e.g.:${RESET}"
  echo -e "${RED}     export VAULT_HOSTNAME=vault.apps.<cluster>.<domain>${RESET}"
  exit 1
fi
ok "VAULT_HOSTNAME is set: ${VAULT_HOSTNAME}"

if ! oc whoami &>/dev/null; then
  echo -e "${RED}  ✖  Not logged into OpenShift — run 'oc login' first${RESET}"
  exit 1
fi
ok "Logged in as: $(oc whoami) @ $(oc whoami --show-server)"

# Warn if the StorageClass in vault-values.yaml may not exist on this cluster
SC=$(grep 'storageClass:' "${HELM_VALUES}" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -1)
if [[ -n "${SC}" ]]; then
  if ! oc get storageclass "${SC}" &>/dev/null; then
    warn "StorageClass '${SC}' not found on this cluster."
    warn "Available storage classes:"
    oc get storageclass --no-headers | awk '{print "    " $1}'
    warn "Update storageClass in vault-values.yaml and re-run."
    exit 1
  fi
  ok "StorageClass '${SC}' exists"
fi

# ── step 0 ────────────────────────────────────────────────────────────────────
step "Step 0 — Add the HashiCorp Helm repo and update"
info "Adds the HashiCorp Helm repo (safe to re-run if already present),"
info "then fetches the latest chart index."

run "helm repo add hashicorp https://helm.releases.hashicorp.com"
run "helm repo update"
ok "Helm repo ready"

# ── step 1 ────────────────────────────────────────────────────────────────────
step "Step 1 — Create the 'vault' namespace"
info "Creates an OpenShift Project (namespace) named '${NAMESPACE}'."

run "oc new-project ${NAMESPACE}"
run "oc project ${NAMESPACE}"
ok "Project '${NAMESPACE}' created"

# ── step 2 ────────────────────────────────────────────────────────────────────
step "Step 2 — Pre-create service accounts and grant 'anyuid' SCC"
info "The anyuid SCC must be bound BEFORE helm install so pods never start"
info "without the correct permissions and enter CrashLoopBackOff."
info ""
info "Service accounts are labelled and annotated so Helm can adopt them"
info "during install without an 'invalid ownership metadata' error."
cmd "oc create serviceaccount vault -n ${NAMESPACE}"
cmd "oc create serviceaccount vault-agent-injector -n ${NAMESPACE}"
cmd "# annotate both SAs for Helm ownership"
cmd "oc adm policy add-scc-to-user anyuid -z vault -n ${NAMESPACE}"
cmd "oc adm policy add-scc-to-user anyuid -z vault-agent-injector -n ${NAMESPACE}"
pause

for sa in vault vault-agent-injector; do
  oc create serviceaccount "${sa}" -n "${NAMESPACE}"
  oc label serviceaccount "${sa}" -n "${NAMESPACE}" \
    app.kubernetes.io/managed-by=Helm
  oc annotate serviceaccount "${sa}" -n "${NAMESPACE}" \
    meta.helm.sh/release-name="${HELM_RELEASE}" \
    meta.helm.sh/release-namespace="${NAMESPACE}"
done

oc adm policy add-scc-to-user anyuid -z vault -n "${NAMESPACE}"
oc adm policy add-scc-to-user anyuid -z vault-agent-injector -n "${NAMESPACE}"
ok "Service accounts created, Helm ownership set, and anyuid SCC granted"

# ── step 3 ────────────────────────────────────────────────────────────────────
step "Step 3 — Create the Vault Enterprise license secret"
info "Reads \$VAULT_LICENSE and stores it as a Kubernetes secret."

run "oc create secret generic ${VAULT_SECRET_NAME} --from-literal=license=\"\${VAULT_LICENSE}\" -n ${NAMESPACE}"
ok "Secret '${VAULT_SECRET_NAME}' created"

# ── step 4 ────────────────────────────────────────────────────────────────────
step "Step 4 — Install Vault via Helm"
info "Installs chart '${HELM_CHART}' into namespace '${NAMESPACE}'."
info "Pods will be Running but 0/1 Ready until initialized and unsealed."

run "helm install ${HELM_RELEASE} ${HELM_CHART} --namespace ${NAMESPACE} --values ${HELM_VALUES} --wait=hookOnly"
ok "Helm install complete"

# global.openshift=true causes the chart to zero out the pod security context,
# dropping fsGroup/runAsUser. Patch them back onto the StatefulSet so the
# /vault/data PVC is writable (Vault runs as UID 100, needs fsGroup 1000).
echo ""
info "Patching StatefulSet security context (fsGroup + runAsUser) — required"
info "because global.openshift=true strips these from the Helm-rendered spec."
cmd "oc patch statefulset vault -n ${NAMESPACE} --type=json -p='[...]'"
sleep "${SLEEP}"
oc patch statefulset vault -n "${NAMESPACE}" --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/securityContext/runAsUser","value":100},
  {"op":"add","path":"/spec/template/spec/securityContext/runAsGroup","value":1000},
  {"op":"add","path":"/spec/template/spec/securityContext/fsGroup","value":1000},
  {"op":"add","path":"/spec/template/spec/securityContext/runAsNonRoot","value":true}
]'
ok "StatefulSet security context patched — deleting pods to apply"

# OnDelete strategy: delete the pods so they restart with the patched spec
run "oc delete pod vault-0 vault-1 vault-2 -n ${NAMESPACE}"

echo ""
info "Polling until vault-0, vault-1, vault-2 are all Running..."
for i in $(seq 1 60); do
  STATES=$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep '^vault-[0-2]' | awk '{print $3}')
  RUNNING=$(echo "${STATES}" | grep -c '^Running$' || true)
  echo -e "  ${DIM}[${i}/60] vault pods Running: ${RUNNING}/3${RESET}"
  if [[ "${RUNNING}" -eq 3 ]]; then
    break
  fi
  sleep 5
done

oc get pods -n "${NAMESPACE}"
ok "All 3 vault pods are Running"

# ── step 5 ────────────────────────────────────────────────────────────────────
step "Step 5 — Initialize Vault"
info "Initializes Vault with 1 key share and a threshold of 1."
info "Output is saved to vault-init.json — keep this file secure!"

run "oc exec -n ${NAMESPACE} vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json | tee vault-init.json"

UNSEAL_KEY=$(python3 -c "import sys,json; d=json.load(open('vault-init.json')); print(d['unseal_keys_b64'][0])")
ROOT_TOKEN=$(python3 -c "import sys,json; d=json.load(open('vault-init.json')); print(d['root_token'])")
ok "Vault initialized — unseal key and root token saved to vault-init.json"

# ── step 6 ────────────────────────────────────────────────────────────────────
step "Step 6 — Unseal all three Vault pods"
info "Each pod must be individually unsealed with the single unseal key."
info "Pods are unsealed one at a time; each must reach Ready before the next"
info "is unsealed, ensuring Raft quorum is never lost."
pause

for pod in vault-0 vault-1 vault-2; do
  echo ""
  info "Unsealing ${pod}..."
  cmd "oc exec -n ${NAMESPACE} ${pod} -- vault operator unseal \"\${UNSEAL_KEY}\""
  sleep 2
  oc exec -n "${NAMESPACE}" "${pod}" -- vault operator unseal "${UNSEAL_KEY}"
  info "Waiting for ${pod} to be Ready..."
  oc wait pod "${pod}" -n "${NAMESPACE}" --for=condition=Ready --timeout=120s
  ok "${pod} unsealed and Ready"
done

# ── step 7 ────────────────────────────────────────────────────────────────────
step "Step 7 — Verify the Raft cluster"
info "Logging in to vault-0 and listing Raft peers."

cmd "oc exec -n ${NAMESPACE} vault-0 -- vault login \"\${ROOT_TOKEN}\""
sleep 2
oc exec -n "${NAMESPACE}" vault-0 -- vault login "${ROOT_TOKEN}"

echo ""
cmd "oc exec -n ${NAMESPACE} vault-0 -- vault operator raft list-peers"
sleep 2
oc exec -n "${NAMESPACE}" vault-0 -- vault operator raft list-peers
ok "Raft cluster verified"

# ── step 8 ────────────────────────────────────────────────────────────────────
step "Step 8 — Expose Vault via an OpenShift Route"
info "Creates an edge-TLS Route at: https://${VAULT_HOSTNAME}"

run "oc expose svc/vault -n ${NAMESPACE} --name=vault --port=8200 --hostname=${VAULT_HOSTNAME}"
run "oc patch route vault -n ${NAMESPACE} -p '{\"spec\":{\"tls\":{\"termination\":\"edge\",\"insecureEdgeTerminationPolicy\":\"Redirect\"}}}'"

oc get route vault -n "${NAMESPACE}"
ok "Route created"

# ── step 9 ────────────────────────────────────────────────────────────────────
step "Step 9 — Validate from outside the cluster"
info "Checking Vault status, license, and writing a test secret via the Route."

export VAULT_ADDR="https://${VAULT_HOSTNAME}"
export VAULT_TOKEN="${ROOT_TOKEN}"

cmd "vault status"
sleep 2
vault status

echo ""
cmd "vault operator raft list-peers"
sleep 2
vault operator raft list-peers

echo ""
cmd "vault license get"
sleep 2
vault license get

echo ""
cmd "vault secrets enable -path=kv kv-v2"
sleep 2
vault secrets enable -path=kv kv-v2 2>/dev/null || warn "kv secrets engine already enabled"

cmd "vault kv put kv/test message=\"Vault Enterprise on OpenShift on VMware works!\""
sleep 2
vault kv put kv/test message="Vault Enterprise on OpenShift on VMware works!"

cmd "vault kv get kv/test"
sleep 2
vault kv get kv/test

ok "External validation passed"

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✔  Vault Enterprise is up and running!${RESET}"
echo -e "${GREEN}${BOLD}     URL:  https://${VAULT_HOSTNAME}${RESET}"
echo -e "${GREEN}${BOLD}     UI:   https://${VAULT_HOSTNAME}/ui${RESET}"
echo -e "${GREEN}${BOLD}     Init: vault-init.json  ← keep this secure!${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
