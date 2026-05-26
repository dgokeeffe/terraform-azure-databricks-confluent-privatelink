"""Submit the TLS smoke test as a one-time Databricks Serverless Job.

Produces a shareable run URL — durable proof that the App Gateway TCP/TLS
proxy + NCC PE rule path works end-to-end from real Databricks Serverless
compute. Unlike Databricks Connect (ephemeral session), a Jobs run is
persisted in the workspace UI with stable URL, runtime, output, and audit
trail anyone with workspace access can review.

Run:
  DATABRICKS_HOST=https://adb-<workspace>.azuredatabricks.net \
    uv run python submit_job.py

Auth: Azure CLI (`az account get-access-token`).
"""

import base64
import os
import sys
import time

from databricks.sdk import WorkspaceClient
from databricks.sdk.service import workspace as ws_svc
from databricks.sdk.service.jobs import NotebookTask, SubmitTask


TEST_FQDN = os.environ.get("SMOKE_TEST_FQDN", "smoke-broker.appgw-test.example.com")


NOTEBOOK_SOURCE = f"""# Databricks notebook source
# MAGIC %md
# MAGIC # App Gateway v2 TCP/TLS Proxy — End-to-End Validation
# MAGIC
# MAGIC Validates the full Databricks Serverless → NCC PE Rule → Azure
# MAGIC Private Endpoint → App Gateway v2 TCP/TLS proxy → self-signed TLS
# MAGIC backend path. Output below is the proof this architecture works.

# COMMAND ----------
import socket, ssl, datetime, json

FQDN = "{TEST_FQDN}"
PORT = 9092

result = {{"steps": [], "status": "FAIL"}}

def log(step, **kw):
    entry = {{"step": step, **kw}}
    result["steps"].append(entry)
    print(json.dumps(entry, default=str))

try:
    # ---- L1: DNS lookup (proves NCC DNS injection works) ----
    ip = socket.gethostbyname(FQDN)
    log("L1_dns", fqdn=FQDN, resolved_ip=ip)

    # ---- L2: TCP socket (proves PE → App GW path works) ----
    raw = socket.create_connection((FQDN, PORT), timeout=15)
    log("L2_tcp", local=raw.getsockname(), remote=raw.getpeername())

    # ---- L3: TLS handshake (proves App GW TCP/TLS passthrough) ----
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    tls = ctx.wrap_socket(raw, server_hostname=FQDN)
    log("L3_tls",
        cipher=tls.cipher(),
        peer_cert_head=repr(tls.getpeercert(binary_form=True)[:60]))

    # ---- L4: Round-trip echo through the proxy ----
    msg = f"hello-from-serverless-job-{{datetime.datetime.utcnow().isoformat()}}Z\\n".encode()
    tls.sendall(msg)
    rx = tls.recv(8192)
    log("L4_echo", sent=repr(msg), recv=repr(rx), matched=msg in rx)
    tls.close()

    if msg in rx:
        result["status"] = "PASS"
        print("PASS — full L1+L2+L3+L4 path validated from Serverless")
    else:
        print(f"FAIL — echo mismatch")
except Exception as e:
    log("exception", type=type(e).__name__, message=str(e))
    print(f"FAIL — {{type(e).__name__}}: {{e}}")

# COMMAND ----------
import json as _json
dbutils.notebook.exit(_json.dumps(result))
"""


def main():
    host = os.environ.get("DATABRICKS_HOST")
    if not host:
        print("ERROR: set DATABRICKS_HOST to your workspace URL (e.g., https://adb-XXXX.azuredatabricks.net)")
        sys.exit(2)

    w = WorkspaceClient(host=host, auth_type="azure-cli")

    # Notebook lives at /Users/<current user>/appgw-tls-smoke-test
    me = w.current_user.me().user_name
    notebook_path = f"/Users/{me}/appgw-tls-smoke-test"

    print(f"Uploading notebook to {notebook_path}...")
    w.workspace.import_(
        path=notebook_path,
        format=ws_svc.ImportFormat.SOURCE,
        language=ws_svc.Language.PYTHON,
        content=base64.b64encode(NOTEBOOK_SOURCE.encode()).decode(),
        overwrite=True,
    )

    print("Submitting one-time Serverless job run...")
    submit = w.jobs.submit(
        run_name=f"appgw-tls-smoke-test-{int(time.time())}",
        tasks=[
            SubmitTask(
                task_key="tls_test",
                notebook_task=NotebookTask(notebook_path=notebook_path),
                # No new_cluster / existing_cluster_id → runs on Serverless
            )
        ],
    )
    run_id = submit.response.run_id if hasattr(submit, "response") else submit.run_id
    run_url = f"{host}/jobs/runs/{run_id}"
    print(f"Run ID:  {run_id}")
    print(f"Run URL: {run_url}")

    print("Polling for completion (up to ~10 min)...")
    info = None
    for i in range(60):
        info = w.jobs.get_run(run_id)
        state = info.state
        life = state.life_cycle_state.value if state.life_cycle_state else "?"
        result_state = state.result_state.value if state.result_state else None
        print(f"  [{i:02d}] life_cycle={life}  result={result_state}")
        if life in ("TERMINATED", "INTERNAL_ERROR", "SKIPPED"):
            break
        time.sleep(10)

    task_run_id = info.tasks[0].run_id
    out = w.jobs.get_run_output(task_run_id)
    print("\n" + "=" * 72)
    print("NOTEBOOK OUTPUT (from Serverless):")
    print("=" * 72)
    if out.notebook_output and out.notebook_output.result:
        print(out.notebook_output.result)
    else:
        print("(no notebook_output)")
    print("=" * 72)

    if info.state.result_state and info.state.result_state.value == "SUCCESS":
        print(f"\n✅ Job SUCCESS. Run URL: {run_url}")
        sys.exit(0)
    else:
        print(f"\n❌ Job did not succeed. State: {info.state.result_state}")
        print(f"   Run URL (for debugging): {run_url}")
        sys.exit(1)


if __name__ == "__main__":
    main()
