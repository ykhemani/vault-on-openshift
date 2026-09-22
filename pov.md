# Vault Enterprise Proof of Value (PoV)

This document describes the use cases, objectives, and success criteria for a Vault Enterprise (Vault) Proof of Value (PoV).

> **Scope:** This PoV stands up a non-production Vault Enterprise environment
> for the purpose of demonstrating and evaluating Vault capabilities. It is not
> intended to produce a production-ready deployment.

---

## Prerequisites

The following must be in place before beginning the PoV.

### Workstation

| Tool | Minimum Version | Install |
|------|----------------|---------|
| `oc` | 4.14+ | [OpenShift CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/) |
| `helm` | v3.x | [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/) |
| `vault` | 2.x | [developer.hashicorp.com/vault/install](https://developer.hashicorp.com/vault/install) |
| `python3` | 3.x | Pre-installed on most systems |

Verify all tools are present:
```bash
oc version
helm version
vault version
python3 --version
```

For example:
```bash
❯ oc version
Client Version: 4.21.7
Kustomize Version: v5.7.1
Server Version: 4.21.7
Kubernetes Version: v1.34.5

❯ helm version
version.BuildInfo{Version:"v4.2.3", GitCommit:"43e8b7feece8beb0fcba47059ec9b522fd929a64", GitTreeState:"clean", GoVersion:"go1.26.5", KubeClientVersion:"v1.36"}

❯ vault version
Vault v2.0.4+ent (cbe86e71d0ef87529b50589b50b60e9deaa50bb7), built 2026-08-03T16:09:47Z

❯ python3 --version
Python 3.14.7
```

### OpenShift Cluster

- OpenShift 4.14+ running on VMware vSphere (IPI or UPI)
- `cluster-admin` credentials

```bash
# Log in
oc login https://api.<cluster-name>.<base-domain>:6443 --username=<admin-user>

# Confirm cluster-admin
oc whoami
oc auth can-i '*' '*' --all-namespaces
```

For example:
```bash
❯ oc whoami
cluster-admin

❯ oc auth can-i '*' '*' --all-namespaces
yes
```

### Storage Class

Confirm the vSphere CSI storage class name on the cluster:

```bash
oc get storageclass
```

The default in `vault-values.yaml` is `thin-csi`. If your cluster uses a different
name, update `server.dataStorage.storageClass` in `vault-values.yaml` before
running `up.sh`.

| Storage class | When you see it |
|--------------|-----------------|
| `thin-csi` | vSphere CSI operator (OCP 4.11+) — most common |
| `thin` | Legacy in-tree vSphere provider |
| `standard` | Some vSphere environments |

### Environment Variables

Both must be exported in your shell before running any script:

```bash
export VAULT_LICENSE="<vault-enterprise-license-string>"
export VAULT_HOSTNAME="vault.apps.<cluster-name>.<base-domain>"
```

> **Tip:** Keep these in a `vault-env.sh` file that you `source` before running
> scripts. Do not commit it to source control.

### Vault Enterprise License

A valid Vault Enterprise license is required. Contact your HashiCorp account
team if you need a trial license for the PoV.

---

## Use Case 1 — Install and Initialize Vault Enterprise

### Objective

Install and initialize a Vault Enterprise cluster to provide a working Vault environment for executing the PoV. Please note that the instructions provided herein should not be used to put Vault in production.

### Success Criteria

- Vault Enterprise is installed on OpenShift using the Helm chart
- All 3 Vault pods are running and healthy
- The Vault cluster is initialized and unsealed
- The Vault UI is accessible via the OpenShift Route
- Vault Enterprise license is active and valid

### How to Execute

Both variables must be exported in your shell before running any script.

```bash
# Your Vault Enterprise license string
export VAULT_LICENSE="<your-vault-enterprise-license>"

# The hostname you want for the OpenShift Route (must resolve via your cluster's
# wildcard DNS — replace cluster-name and base-domain with your values)
export VAULT_HOSTNAME="vault.apps.<cluster-name>.<base-domain>"
```

> **Tip:** Put these in a file (e.g. `vault-env.sh`) that you `source` before
> running the scripts — don't commit it to source control.
> ```bash
> # vault-env.sh  (add to .gitignore)
> export VAULT_LICENSE="..."
> export VAULT_HOSTNAME="vault.apps.<cluster-name>.<base-domain>"
> ```
> ```bash
> source vault-env.sh
> ```

```bash
./up.sh
```

`up.sh` will:
1. Verify all tools and environment variables are present
2. Verify the storage class exists on the cluster
3. Add the HashiCorp Helm repo
4. Create the `vault` namespace
5. Pre-create service accounts and grant the `anyuid` SCC
6. Create the Vault Enterprise license secret
7. Install Vault via Helm
8. Patch the StatefulSet security context (required by `global.openshift: true`)
9. Wait for all 3 pods to be `Running`
10. Initialize Vault — saves keys and root token to `vault-init.json`
11. Unseal all 3 pods one at a time, waiting for each to be `Ready` before the next
12. Verify the Raft cluster
13. Create an OpenShift Route with edge TLS
14. Validate Vault is reachable externally

> **`vault-init.json` contains the unseal key and root token. Store it securely
> and do not commit it to source control. It is shown only once.**

#### Verify that Vault is deployed and initialized.

```bash
export VAULT_ADDR="https://${VAULT_HOSTNAME}"
export VAULT_TOKEN=$(cat vault-init.json | jq -r .root_token)

# All 3 pods Running and Ready
oc get pods -n vault

# Vault status — should show Initialized: true, Sealed: false
vault status
vault status -format=json | jq -r .initialized
vault status -format=json | jq -r .sealed

# One Vault server should be a leader, and the other two should be followers
vault operator raft list-peers
```

### Expected Results

1. 3 Vault pods and a vault-agent-injector pod are running in the vault namespace in OpenShift.
```
❯ oc get pods -n vault

NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 1/1     Running   0          83m
vault-1                                 1/1     Running   0          83m
vault-2                                 1/1     Running   0          83m
vault-agent-injector-8644889bfd-6pvqp   1/1     Running   0          83m
```

2. Vault is initialized and unsealed.
```
❯ vault status
Key                     Value
---                     -----
Seal Type               shamir
Initialized             true
Sealed                  false
Total Shares            1
Threshold               1
Version                 2.1.1+ent
Build Date              2026-09-15T21:39:40Z
Storage Type            raft
Cluster Name            vault-cluster-c7b977d7
Cluster ID              17cd0331-6d83-e857-8cdb-9b033730319f
Removed From Cluster    false
HA Enabled              true
HA Cluster              https://vault-0.vault-internal:8201
HA Mode                 active
Active Since            2026-09-21T18:55:33.723091732Z
Raft Committed Index    14323
Raft Applied Index      14323
Last WAL                5557

❯ vault status -format=json | jq -r .initialized
true

❯ vault status -format=json | jq -r .sealed
false

❯ vault operator raft list-peers

Node       Address                        State       Voter
----       -------                        -----       -----
vault-0    vault-0.vault-internal:8201    leader      true
vault-1    vault-1.vault-internal:8201    follower    true
vault-2    vault-2.vault-internal:8201    follower    true
```
---

## Demo Environment Setup

Before running Use Cases 2, set up the PostgreSQL database and the demo application. These will enable us to demonstrate Vault providing dynamic database credentials for a sample app.

### Step 1 — Deploy the PostgreSQL database

The [`db/db-up.sh`](db/db-up.sh) script deploys PostgreSQL into the `database` namespace, creates the `demodb` database, and provisions the users and roles Vault will manage:

| User | Purpose |
|------|---------|
| `vault` | Vault's superuser — creates and revokes dynamic credentials |
| `static-user` | Pre-VSO static account used by the demo app before UC3 |
| `demodb_reader` | Role granted to all dynamic credentials |

```bash
cd db

# Default — uses 'staticpass' for static-user
./db-up.sh

Verify the database is ready:

```bash
./db-status.sh
```

Expected: PostgreSQL pod Running, `demodb` database exists, and `static-user` and `vault` users exist.

---

### Step 2 — Deploy the demo web application

The [`app/app-up.sh`](app/app-up.sh) script builds the Flask demo app using the OpenShift internal registry, creates a static Kubernetes Secret with the `static-user` credentials mounted at `/vault/secrets/db-creds`, and exposes the app via an OpenShift Route.

```bash
cd app

./app-up.sh
```

Verify the app is running:

```bash
./app-status.sh
```

Expected: app pod Running, Route accessible at `https://${APP_HOSTNAME}`, page
loads showing the `customer` table connected as `static-user`.

> **What you should see at this point:**
> The demo app page shows:
> - **Creds source:** `static secret` (amber badge)
> - **Current Credentials:** `username=static-user`, password masked (click to reveal)
> - The `customer` table populated with 20 rows
>
> This is the baseline state before Vault takes over credential management.

---

## Use Case 2 — Dynamic Database Secrets

### Objective

Enable Vault's database secrets engine and configure it to issue short-lived
PostgreSQL credentials on demand. Demonstrate that every caller receives a
unique username and password that Vault automatically revokes when the lease
expires — eliminating long-lived shared credentials entirely.

### Success Criteria

- The database secrets engine is enabled and configured in Vault
- A Vault role (`demodb-reader`) is created that issues dynamic credentials
- `vault read` returns a unique username and password
- The issued username is visible in PostgreSQL (`\du`)
- After lease expiry (or manual revocation), the username is gone from PostgreSQL

### How to Execute

All commands in this section assume that the following environment variables are set.

```bash
export VAULT_ADDR="https://${VAULT_HOSTNAME}"
export VAULT_TOKEN=$(cat vault-init.json | jq -r .root_token)
export VAULT_SKIP_VERIFY=true   # if using a self-signed cert
```

---

#### Step 1 — Enable the database secrets engine

```bash
vault secrets enable -path=database database
```

Expected:
```
Success! Enabled the database secrets engine at: database/
```

---

#### Step 2 — Configure the PostgreSQL connection

Vault connects to PostgreSQL using the `vault` superuser created by
[`db/db-up.sh`](db/db-up.sh). The password defaults to `vaultpass`; if you
set `VAULT_DB_PASSWORD` when running `db-up.sh`, use that value here.

```bash
vault write database/config/demodb \
  plugin_name=postgresql-database-plugin \
  allowed_roles="demodb-reader" \
  connection_url="postgresql://{{username}}:{{password}}@postgresql.database.svc.cluster.local:5432/demodb?sslmode=disable" \
  username="vault" \
  password="vaultpass"
```

> **Note:** Replace `vaultpass` with `${VAULT_DB_PASSWORD}` if you overrode the
> default when running `db-up.sh`.

Expected:
```
Success! Data written to: database/config/demodb
```

Verify Vault can reach the database:

```bash
vault write -force database/config/demodb/rotate-root
```

Expected: no error. This immediately rotates the `vault` superuser password so
it is known only to Vault — a security best practice.

---

#### Step 3 — Create the dynamic role

The role defines the SQL Vault runs to create and revoke credentials, and how
long each lease lasts.

```bash
vault write database/roles/demodb-reader \
  db_name=demodb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT demodb_reader TO \"{{name}}\";" \
  revocation_statements="REVOKE demodb_reader FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="10m" \
  max_ttl="30m"
```

Expected:
```
Success! Data written to: database/roles/demodb-reader
```

---

#### Step 4 — Read a dynamic credential

```bash
vault read database/creds/demodb-reader
```

Expected output:
```
Key                Value
---                -----
lease_id           database/creds/demodb-reader/EkTga9i8kZndDp1RLFRM8NUL
lease_duration     10m
lease_renewable    true
password           fQNiX17m7LgMsh-tlu16
username           v-root-demodb-r-st6PMIxrNISgnPHgBzaW-1790037416
```

> The username always starts with `v-` — this is what the demo app uses to
> detect that VSO (not the static Secret) is providing credentials.

---

#### Step 5 — Verify the credential in PostgreSQL

Confirm the dynamic user was created in the database by running `psql` directly
inside the PostgreSQL pod — no node IP or NodePort access required.

```bash
# Run \du inside the PostgreSQL pod
oc exec -n database \
  $(oc get pod -n database -l name=postgresql -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U postgres -d demodb -c "\du"
```

Look for a row whose role name starts with `v-` — for example:

```
                                      List of roles
         Role name              |         Attributes          |      Member of
--------------------------------+-----------------------------+------------------
 demodb_reader                  | Cannot login                | {}
 postgres                       | Superuser, Create role, ... | {}
 static-user                    |                             | {demodb_reader}
 v-root-demodb-r-PGNQbxxuE...   | Password valid until ...    | {demodb_reader}
 vault                          | Superuser, Create role, ... | {}
```

You can also confirm the credential actually works against the database.
Set the two shell variables first, then run a single `oc exec` that passes them
into the pod via a `bash -c` invocation — this avoids the outer shell consuming
the quotes before they reach `psql`:

```bash
DYNAMIC_USER="v-root-demodb-r-<suffix>"   # username from Step 4
DYNAMIC_PASS="<password-from-step-4>"     # password from Step 4
DB_POD=$(oc get pod -n database -l name=postgresql -o jsonpath='{.items[0].metadata.name}')

oc exec -n database "${DB_POD}" \
  -- bash -c "PGPASSWORD='${DYNAMIC_PASS}' psql -U '${DYNAMIC_USER}' -d demodb -c 'SELECT current_user;'"
```

Expected:
```
            current_user
------------------------------------
 v-root-demodb-r-iWJuH9m1-...
(1 row)
```

---

#### Step 6 — Revoke the credential

```bash
vault lease revoke database/creds/demodb-reader/<lease-id-from-step-4>
```

Re-run the `\du` check — the dynamic user should be gone:

```bash
oc exec -n database \
  $(oc get pod -n database -l name=postgresql -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U postgres -d demodb -c "\du"
```

The `v-root-…` row should no longer appear.

---

### Expected Results

| Check | Expected |
|-------|----------|
| `vault secrets list` | `database/` appears |
| `vault read database/creds/demodb-reader` | Returns unique `username` + `password` |
| `\du` in PostgreSQL | Dynamic username (`v-root-…`) present while lease is active |
| After revocation / expiry | Dynamic username absent from `\du` |

---


## Use Case 3 — Vault Secrets Operator (VSO)

### Objective

Install the Vault Secrets Operator (VSO) on OpenShift and configure it to
deliver dynamically-issued PostgreSQL credentials directly into the demo app
pod as a file. Demonstrate that:

- The app never holds a long-lived password
- Credentials rotate automatically when a Vault lease expires
- The app restarts cleanly when VSO writes new credentials — without any
  manual intervention

### Success Criteria

- VSO is installed and running in the `vault-secrets-operator-system` namespace
- A `VaultConnection`, `VaultAuth`, and `VaultDynamicSecret` are configured
- The app pod's `/vault/secrets/db-creds` file is written by VSO (not the static Secret)
- The demo app page shows **Creds source: VSO** (blue badge)
- The username on the page starts with `v-` and changes each lease cycle
- The app pod restarts automatically when VSO rotates credentials

---

### How to Execute

All commands assume:

```bash
export VAULT_ADDR="https://${VAULT_HOSTNAME}"
export VAULT_TOKEN=$(cat vault-init.json | jq -r .root_token)
export VAULT_SKIP_VERIFY=true
```

---

#### Step 1 — Install the Vault Secrets Operator via Helm

> **OpenShift note:** OpenShift mirrors unqualified Docker Hub image names
> (e.g. `hashicorp/vault-secrets-operator`) to `registry.connect.redhat.com`,
> where the tag may not exist. Explicitly prefixing the repository with
> `docker.io/` bypasses the mirror and pulls directly from Docker Hub.

First, uninstall any previous failed attempt:

```bash
helm uninstall vault-secrets-operator \
  --namespace vault-secrets-operator-system 2>/dev/null || true
```

Then install with the explicit `docker.io/` prefix:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system \
  --create-namespace \
  --version 1.5.1 \
  --set controller.manager.image.repository=docker.io/hashicorp/vault-secrets-operator
```

Verify VSO is running:

```bash
oc get pods -n vault-secrets-operator-system
```

Expected:
```
NAME                                                         READY   STATUS    RESTARTS   AGE
vault-secrets-operator-controller-manager-<suffix>          2/2     Running   0          60s
```

---

#### Step 2 — Enable Kubernetes auth in Vault

VSO authenticates to Vault using the Kubernetes auth method. Enable it and
configure it to trust the OpenShift cluster's service account tokens.

```bash
vault auth enable kubernetes
```

Configure it using the in-cluster API server address:

```bash
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"
```

Expected:
```
Success! Data written to: auth/kubernetes/config
```

---

#### Step 3 — Create a Vault policy for the app

This policy grants the app's service account permission to read dynamic
database credentials from the `demodb-reader` role.

```bash
vault policy write demodb-reader - <<EOF
path "database/creds/demodb-reader" {
  capabilities = ["read"]
}
EOF
```

Expected:
```
Success! Uploaded policy: demodb-reader
```

---

#### Step 4 — Create a Kubernetes auth role in Vault

Bind the policy to the `default` service account in the `app` namespace:

```bash
vault write auth/kubernetes/role/demodb-reader \
  bound_service_account_names=default \
  bound_service_account_namespaces=app \
  policies=demodb-reader \
  ttl=10m
```

Expected:
```
Success! Data written to: auth/kubernetes/role/demodb-reader
```

---

#### Step 5 — Create the VSO custom resources in the `app` namespace

Apply all three VSO resources — `VaultConnection`, `VaultAuth`, and
`VaultDynamicSecret` — in a single manifest.

```bash
oc apply -f - <<EOF
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: app
spec:
  address: http://vault.vault.svc.cluster.local:8200
  skipTLSVerify: false
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: app
spec:
  vaultConnectionRef: vault-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: demodb-reader
    serviceAccount: default
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata:
  name: demodb-creds
  namespace: app
spec:
  vaultAuthRef: vault-auth
  mount: database
  path: creds/demodb-reader
  destination:
    name: vault-pov-db-creds
    create: false
    transformation:
      templates:
        db-creds:
          text: |
            username={{ .Secrets.username }}
            password={{ .Secrets.password }}
  rolloutRestartTargets:
    - kind: Deployment
      name: vault-pov-app
EOF
```

> **Key points:**
> - `destination.name: vault-pov-db-creds` targets the **same Secret** that
>   `app-up.sh` created — VSO overwrites it in place, no pod spec changes needed
> - `destination.create: false` tells VSO to update the existing Secret rather
>   than try to create a new one
> - The `transformation.templates` block writes the file in the exact
>   `key=value` format the app expects
> - `rolloutRestartTargets` triggers a rolling restart of the `vault-pov-app`
>   Deployment each time VSO rotates the credentials

---

#### Step 6 — Verify VSO has synced the credentials

Check that the `VaultDynamicSecret` is ready:

```bash
oc get vaultdynamicsecret demodb-creds -n app
```

Expected:
```
NAME           READY   STATUS    AGE
demodb-creds   True    Synced    30s
```

Inspect the Secret VSO wrote:

```bash
oc get secret vault-pov-db-creds -n app \
  -o jsonpath='{.data.db-creds}' | base64 -d
```

Expected — a `v-` username and a dynamically-issued password:
```
username=v-root-demodb-r-iWJuH9m1-...
password=A1b2-C3d4-E5f6-G7h8
```

---

#### Step 7 — Verify the demo app shows VSO credentials

Open the app in a browser (or `curl`):

```bash
APP_ROUTE=$(oc get route vault-pov-app -n app -o jsonpath='{.spec.host}')
echo "https://${APP_ROUTE}"
```

The page should now show:

- **Creds source:** `VSO` (blue badge)
- **Current Credentials:** username starting with `v-`, password masked
- **Connected as:** the same `v-` username confirmed against the database

---

#### Step 8 — Watch credentials rotate

Shorten the lease TTL on the role to 2 minutes to demonstrate rotation without
waiting an hour:

```bash
vault write database/roles/demodb-reader \
  db_name=demodb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT demodb_reader TO \"{{name}}\";" \
  revocation_statements="REVOKE demodb_reader FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1m" \
  max_ttl="3m"
```

Watch VSO renew the lease and eventually rotate:

```bash
oc get vaultdynamicsecret demodb-creds -n app -w
```

Within 2 minutes:
1. VSO writes a new username + password to the Secret
2. The `vault-pov-app` Deployment rolls — a new pod starts
3. Refresh the app page — the username has changed to a new `v-` value
4. The old username is gone from PostgreSQL (`\du`)

Verify the old credential was revoked:

```bash
DB_POD=$(oc get pod -n database -l name=postgresql -o jsonpath='{.items[0].metadata.name}')
oc exec -n database "${DB_POD}" -- psql -U postgres -d demodb -c "\du"
```

Only one `v-` user should be present — the newly issued one.

---

#### Step 9 — Restore the lease TTL (optional)

Reset the role back to a 1-hour TTL after the demo:

```bash
vault write database/roles/demodb-reader \
  db_name=demodb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT demodb_reader TO \"{{name}}\";" \
  revocation_statements="REVOKE demodb_reader FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
```

---

### Expected Results

| Check | Expected |
|-------|----------|
| `oc get pods -n vault-secrets-operator-system` | VSO controller pod `2/2 Running` |
| `oc get vaultdynamicsecret demodb-creds -n app` | `READY=True`, `STATUS=Synced` |
| Secret `vault-pov-db-creds` content | `username=v-root-…` (dynamic) |
| App page **Creds source** badge | Blue **VSO** |
| App page **Connected as** | `v-root-…` username |
| After TTL expiry | Username changes, app restarts, old user absent from `\du` |

---
