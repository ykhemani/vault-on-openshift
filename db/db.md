# PostgreSQL Setup for Vault PoV

This guide deploys a PostgreSQL instance in the `database` namespace on
OpenShift using the built-in `postgresql-persistent` template and Red Hat's
supported PostgreSQL image. No external Helm repos or custom registries are
required.

> **Scope:** This sets up the PostgreSQL side only — users, roles, schema, and
> sample data. Vault configuration (enabling the database secrets engine,
> configuring roles, etc.) is covered in [`../pov.md`](../pov.md).
>
> **Platform independence:** The database objects created here are standard
> PostgreSQL. In a real deployment the database may run on OpenShift, a VM,
> RDS, or any other platform. The application consuming credentials may run
> anywhere too. Vault sits in the middle and neither the app nor the database
> needs to know about the other's infrastructure.

---

## What db-up.sh creates

### Kubernetes resources

| Resource | Details |
|----------|---------|
| Namespace | `database` |
| Deployment | PostgreSQL 16 via OpenShift `postgresql-persistent` template |
| Service (ClusterIP) | `postgresql.database.svc.cluster.local:5432` |
| Service (NodePort) | `postgresql-external` — for connections from outside the cluster |

### PostgreSQL objects

| Object | Type | Purpose |
|--------|------|---------|
| `demodb` | Database | Demo database used throughout the PoV |
| `customer` | Table | Sample table with 20 rows of customer data |
| `postgres` | Superuser | Default admin — password from `POSTGRES_PASSWORD` |
| `vault` | Superuser | Used by Vault to manage dynamic and rotated credentials |
| `static-user` | User | Used to demonstrate Vault static credential rotation |
| `demodb_reader` | Role | Grants `SELECT` on all `demodb` tables — assigned to dynamically created users |

### `customer` table schema

```sql
CREATE TABLE customer (
  id         SERIAL PRIMARY KEY,
  first_name VARCHAR(50),
  last_name  VARCHAR(50),
  street     VARCHAR(100),
  city       VARCHAR(50),
  state      CHAR(2),
  postal     VARCHAR(10)
);
```

---

## Prerequisites

- `oc` logged in as `cluster-admin`
- OpenShift cluster with the built-in `postgresql-persistent` template

Verify the template is available:
```bash
oc get template postgresql-persistent -n openshift
```

---

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `POSTGRES_PASSWORD` | `postgres` | Password for the `postgres` superuser |
| `VAULT_DB_PASSWORD` | `vaultpass` | Password for the `vault` admin user |
| `STATIC_USER_PASSWORD` | `staticpass` | Password for the `static-user` |

Override before running `db-up.sh`:
```bash
export POSTGRES_PASSWORD="<strong-password>"
export VAULT_DB_PASSWORD="<strong-password>"
export STATIC_USER_PASSWORD="<strong-password>"
```

---

## Usage

```bash
cd openshift-on-vmware/db/

./db-up.sh      # deploy PostgreSQL, create users, schema, and sample data
./db-status.sh  # check pod status and verify connectivity
./db-down.sh    # tear everything down
```

---

## Connecting to the database

### From within the cluster (oc exec)

```bash
DB_POD=$(oc get pod -n database -l name=postgresql \
  --no-headers -o custom-columns=':metadata.name' | head -1)

# View the customer table
oc exec -n database "${DB_POD}" -- \
  psql -U postgres -d demodb -c "SELECT * FROM customer;"

# List all users and roles
oc exec -n database "${DB_POD}" -- \
  psql -U postgres -d demodb -c "\du"

# Connect as static-user
oc exec -n database "${DB_POD}" -- \
  env PGPASSWORD="${STATIC_USER_PASSWORD:-staticpass}" \
  psql -U static-user -d demodb -c "SELECT count(*) FROM customer;"
```

### From outside the cluster (port-forward)

```bash
oc port-forward -n database svc/postgresql 5432:5432 &

PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" \
  psql -h 127.0.0.1 -U postgres -d demodb -c "SELECT * FROM customer;"
```

### Via the NodePort service

```bash
# Get the NodePort number
oc get svc postgresql-external -n database

# Get a worker node's external IP
oc get nodes -o wide

# Connect
PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" \
  psql -h <node-ip> -p <node-port> -U postgres -d demodb
```

---

## Vault integration reference

When configuring the Vault database secrets engine (covered in `../pov.md`):

| Setting | Value |
|---------|-------|
| Connection URL | `postgresql://{{username}}:{{password}}@postgresql.database.svc.cluster.local:5432/demodb` |
| Vault admin username | `vault` |
| Vault admin password | value of `VAULT_DB_PASSWORD` (default: `vaultpass`) |
| Static rotation username | `static-user` |
| Database | `demodb` |
| Dynamic role creation SQL | `CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT demodb_reader TO "{{name}}";` |

---

## What db-down.sh removes

- The `database` namespace and all resources within it (Deployment, Services, PVC, Secret)

`db-down.sh` does **not** touch Vault — clean up any Vault database secrets
engine configuration separately via `../pov.md`.
