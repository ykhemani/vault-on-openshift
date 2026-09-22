"""
app.py — Vault PoV demo web application

Reads database credentials exclusively from /vault/secrets/db-creds.
The file is written by a Kubernetes Secret (pre-VSO) or by VSO once
the VaultDynamicSecret is configured.

Expected file format (key=value, one per line):
    username=<user>
    password=<pass>

The page displays the username AND password so credential rotation is
immediately visible to PoV participants when VSO rotates the lease.

Page auto-refreshes every 30 seconds.
"""

import os
import time
import psycopg2
from flask import Flask, render_template_string

app = Flask(__name__)

# ── configuration ─────────────────────────────────────────────────────────────
CREDS_FILE   = os.environ.get("CREDS_FILE", "/vault/secrets/db-creds")
DB_HOST      = os.environ.get("DB_HOST", "postgresql.database.svc.cluster.local")
DB_PORT      = int(os.environ.get("DB_PORT", "5432"))
DB_NAME      = os.environ.get("DB_NAME", "demodb")
REFRESH_SECS = int(os.environ.get("REFRESH_SECS", "30"))
POD_NAME     = os.environ.get("POD_NAME", "unknown")
APP_VERSION  = os.environ.get("APP_VERSION", "dev")
APP_NAME     = "vault-pov-app"
START_TIME   = time.monotonic()

def uptime_str():
    """Return a human-readable uptime string, e.g. '2h 14m 03s'."""
    secs = int(time.monotonic() - START_TIME)
    h, rem = divmod(secs, 3600)
    m, s   = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m {s:02d}s"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"

# ── credential loading ────────────────────────────────────────────────────────
def load_credentials():
    """
    Load DB credentials from CREDS_FILE only.
    Raises RuntimeError if the file is absent or unparseable.
    """
    if not os.path.exists(CREDS_FILE):
        raise RuntimeError(
            f"Credentials file not found: {CREDS_FILE}\n"
            "Ensure the Secret is mounted or VSO has synced the VaultDynamicSecret."
        )

    creds = {}
    with open(CREDS_FILE) as f:
        for line in f:
            line = line.strip()
            if "=" in line:
                key, _, val = line.partition("=")
                creds[key.strip()] = val.strip()

    username = creds.get("username") or creds.get("user")
    password = creds.get("password") or creds.get("pass")

    if not username or not password:
        raise RuntimeError(
            f"Credentials file {CREDS_FILE} exists but could not parse "
            "'username' and 'password' fields."
        )

    return username, password

# ── html template ─────────────────────────────────────────────────────────────
PAGE = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="refresh" content="{{ refresh }}">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Demo – Vault Dynamic Database Credentials via VSO</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, "Segoe UI", system-ui, sans-serif;
      font-size: 14px;
      line-height: 1.6;
      background: #f7f8fa;
      color: #1f2328;
      padding: 2rem;
    }

    header {
      max-width: 960px;
      margin: 0 auto 1.5rem;
    }

    header h1 {
      font-size: 1.25rem;
      font-weight: 600;
      color: #1f2328;
      margin: 0.6rem 0 0.25rem;
      line-height: 1.3;
    }

    .meta {
      display: flex;
      flex-wrap: wrap;
      gap: 1rem;
      font-size: 13px;
      color: #57606a;
      margin-top: 0.4rem;
    }

    .meta span strong { color: #1f2328; }

    /* page-info table — spans full width above the title */
    .page-info {
      width: 100%;
      border: 1px solid #e5e7eb;
      border-radius: 6px;
      background: #f7f8fa;
      font-size: 12px;
      border-collapse: collapse;
      overflow: hidden;
      table-layout: auto;
    }

    .page-info td {
      padding: 0.25rem 0.8rem;
      border-right: 1px solid #e5e7eb;
      white-space: nowrap;
    }

    .page-info tr td:last-child { border-right: none; }

    .page-info .pi-label {
      font-weight: 700;
      color: #1f2328;
      width: 1%;
    }

    .page-info .pi-value {
      font-family: "SFMono-Regular", Consolas, monospace;
      color: #57606a;
    }

    .badge {
      display: inline-block;
      padding: 0.15rem 0.55rem;
      border-radius: 20px;
      font-size: 12px;
      font-weight: 500;
    }

    .badge-ok     { background: #d1fae5; color: #065f46; }
    .badge-err    { background: #fee2e2; color: #991b1b; }
    .badge-static { background: #fef9c3; color: #854d0e; }
    .badge-vso    { background: #dbeafe; color: #1e40af; }

    .creds-box {
      max-width: 960px;
      margin: 0 auto 1rem;
      background: #fffbeb;
      border: 1px solid #fcd34d;
      border-radius: 8px;
      padding: 0.9rem 1.2rem;
      font-size: 13px;
    }

    .creds-box h2 {
      font-size: 13px;
      font-weight: 600;
      color: #92400e;
      margin-bottom: 0.5rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .creds-grid {
      display: grid;
      grid-template-columns: max-content 1fr;
      gap: 0.2rem 1rem;
      align-items: center;
    }

    .creds-grid .label { color: #78350f; font-weight: 600; }
    .creds-grid .value { font-family: "SFMono-Regular", Consolas, monospace; color: #1f2328; }

    /* password reveal toggle — pure CSS checkbox trick */
    .pw-toggle { display: none; }

    .pw-mask  { display: inline; }
    .pw-plain { display: none; }

    .pw-toggle:checked ~ .pw-label .pw-mask  { display: none; }
    .pw-toggle:checked ~ .pw-label .pw-plain { display: inline; }

    .pw-label {
      cursor: pointer;
      user-select: none;
      font-family: "SFMono-Regular", Consolas, monospace;
      color: #1f2328;
    }

    .pw-label .pw-mask {
      letter-spacing: 0.1em;
      color: #78350f;
    }

    .pw-hint {
      font-size: 11px;
      color: #a16207;
      margin-left: 0.4rem;
    }

    .card {
      max-width: 960px;
      margin: 0 auto;
      background: #ffffff;
      border: 1px solid #e5e7eb;
      border-radius: 8px;
      overflow: hidden;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }

    thead { background: #f0f1f3; }

    thead th {
      padding: 0.6rem 1rem;
      text-align: left;
      font-weight: 600;
      color: #57606a;
      text-transform: uppercase;
      font-size: 11px;
      letter-spacing: 0.05em;
      border-bottom: 1px solid #e5e7eb;
    }

    tbody tr:nth-child(even) { background: #fafafa; }
    tbody tr:hover           { background: #f0f4ff; }

    tbody td {
      padding: 0.55rem 1rem;
      border-bottom: 1px solid #f0f1f3;
      color: #1f2328;
    }

    tbody tr:last-child td { border-bottom: none; }

    .error-card {
      max-width: 960px;
      margin: 0 auto;
      background: #fff5f5;
      border: 1px solid #fecaca;
      border-radius: 8px;
      padding: 1.5rem;
    }

    .error-card h2 { color: #991b1b; margin-bottom: 0.75rem; }

    .error-card pre {
      background: #fef2f2;
      border: 1px solid #fecaca;
      border-radius: 4px;
      padding: 0.75rem 1rem;
      font-size: 12px;
      white-space: pre-wrap;
      word-break: break-word;
      color: #7f1d1d;
    }

    footer {
      max-width: 960px;
      margin: 1rem auto 0;
      font-size: 12px;
      color: #8c959f;
      text-align: left;
      border-top: 1px solid #e5e7eb;
      padding-top: 0.75rem;
    }
  </style>
</head>
<body>

<header>
  <table class="page-info">
    <tr>
      <td class="pi-label">Pod</td>
      <td class="pi-value">{{ pod_name }}</td>
      <td class="pi-label">Uptime</td>
      <td class="pi-value">{{ uptime }}</td>
      <td class="pi-label">Image</td>
      <td class="pi-value">{{ app_name }}:{{ app_version }}</td>
      <td class="pi-label">Auto-refresh</td>
      <td class="pi-value">{{ refresh }}s</td>
      <td class="pi-label">Page loaded</td>
      <td class="pi-value">{{ timestamp }}</td>
    </tr>
  </table>
  <h1>Demo &#8211; Vault provided Dynamic Database Credentials using the Vault Secrets Operator</h1>
  <div class="meta">
    <span><strong>Database:</strong> {{ db_name }}</span>
    <span><strong>Host:</strong> {{ db_host }}</span>
  </div>
</header>

{% if username and password %}
<div class="creds-box">
  <h2>Current Credentials (from {{ creds_file }})</h2>
  <div class="creds-grid">
    <span class="label">source</span>
    <span>
      {% if creds_source == "vso" %}
        <span class="badge badge-vso">VSO</span>
      {% elif creds_source == "static" %}
        <span class="badge badge-static">static secret</span>
      {% else %}
        <span class="badge badge-err">not found</span>
      {% endif %}
    </span>
    <span class="label">username</span><span class="value">{{ username }}</span>
    <span class="label">password</span>
    <span>
      <input type="checkbox" id="pw-toggle" class="pw-toggle">
      <label for="pw-toggle" class="pw-label">
        <span class="pw-mask">&#9679;&#9679;&#9679;&#9679;&#9679;&#9679;&#9679;&#9679;</span>
        <span class="pw-plain">{{ password }}</span>
        <span class="pw-hint">(click to reveal)</span>
      </label>
    </span>
  </div>
</div>
{% endif %}

{% if error %}
<div class="error-card">
  <h2>&#9888; Could not load data</h2>
  <pre>{{ error }}</pre>
</div>
{% else %}
<div class="card">
  <table>
    <thead>
      <tr>
        <th>#</th>
        <th>First Name</th>
        <th>Last Name</th>
        <th>Street</th>
        <th>City</th>
        <th>State</th>
        <th>Postal</th>
      </tr>
    </thead>
    <tbody>
      {% for row in rows %}
      <tr>
        <td>{{ row.id }}</td>
        <td>{{ row.first_name }}</td>
        <td>{{ row.last_name }}</td>
        <td>{{ row.street }}</td>
        <td>{{ row.city }}</td>
        <td>{{ row.state }}</td>
        <td>{{ row.postal }}</td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
</div>
{% endif %}

<footer>Copyright &copy; 2026 IBM. All rights reserved.</footer>

</body>
</html>
"""

# ── route ─────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    timestamp    = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
    rows         = []
    error        = None
    connected_as = None
    creds_source = None
    username     = None
    password     = None
    uptime       = uptime_str()

    try:
        username, password = load_credentials()

        # Vault dynamic DB usernames always start with "v-" (e.g. v-approle-demodb_r-abc123-…).
        # The static user created by db-up.sh is literally "static-user" — never starts with "v-".
        creds_source = "vso" if username.startswith("v-") else "static"

        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=username,
            password=password,
            connect_timeout=5,
        )
        with conn:
            with conn.cursor() as cur:
                cur.execute("SELECT current_user;")
                connected_as = cur.fetchone()[0]
                cur.execute(
                    "SELECT id, first_name, last_name, street, city, state, postal "
                    "FROM customer ORDER BY id;"
                )
                cols = [d[0] for d in cur.description]
                rows = [dict(zip(cols, row)) for row in cur.fetchall()]
        conn.close()

    except RuntimeError as exc:
        error = str(exc)
        creds_source = "not found"
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"

    return render_template_string(
        PAGE,
        rows=rows,
        error=error,
        connected_as=connected_as,
        creds_source=creds_source,
        username=username,
        password=password,
        creds_file=CREDS_FILE,
        db_name=DB_NAME,
        db_host=DB_HOST,
        timestamp=timestamp,
        refresh=REFRESH_SECS,
        pod_name=POD_NAME,
        app_name=APP_NAME,
        app_version=APP_VERSION,
        uptime=uptime,
    )

@app.route("/healthz")
def healthz():
    return "ok", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
