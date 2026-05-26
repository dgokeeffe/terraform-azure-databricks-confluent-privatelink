"""Submit a Kafka producer + consumer test as a one-time Databricks Serverless Job.

Proves Databricks Serverless can act as both a Kafka producer and consumer
through the App Gateway TCP/TLS proxy + NCC PE rule path, using Spark's
native Kafka source (the production-idiomatic API).

The Job:
  1. Produces N rows to a topic via `df.write.format("kafka")`.
  2. Reads them back via `spark.read.format("kafka")` (batch, startingOffsets=earliest).
  3. Validates count + content match.
  4. Returns PASS/FAIL via dbutils.notebook.exit.

Run:
  DATABRICKS_HOST=https://adb-<workspace>.azuredatabricks.net \
    uv run python submit_kafka_job.py

Auth: Azure CLI (`az account get-access-token`).
"""

import base64
import os
import sys
import time

from databricks.sdk import WorkspaceClient
from databricks.sdk.service import workspace as ws_svc
from databricks.sdk.service.jobs import NotebookTask, SubmitTask


BROKER_FQDN = os.environ.get("KAFKA_BOOTSTRAP", "smoke-broker.appgw-test.example.com:9092")
TOPIC       = os.environ.get("KAFKA_TOPIC", "smoke-test")
NUM_MSGS    = int(os.environ.get("KAFKA_NUM_MSGS", "20"))


NOTEBOOK_SOURCE = f"""# Databricks notebook source
# MAGIC %md
# MAGIC # Kafka Producer + Consumer through App Gateway v2 TCP/TLS Proxy
# MAGIC
# MAGIC Validates that Databricks Serverless can drive a real Kafka client
# MAGIC workload (producer **and** consumer) through the App Gateway TCP
# MAGIC proxy + NCC PE rule path, using Spark's native Kafka source.
# MAGIC
# MAGIC The Kafka broker behind the App Gateway is a single Apache Kafka 3.7
# MAGIC broker in KRaft mode, with `advertised.listeners` set to the same
# MAGIC FQDN clients dial. The post-metadata re-resolution loops back through
# MAGIC the same NCC PE → App GW path.

# COMMAND ----------
import json, time, uuid

from pyspark.sql import Row
from pyspark.sql.functions import col, expr

BOOTSTRAP = "{BROKER_FQDN}"
TOPIC     = "{TOPIC}"
N         = {NUM_MSGS}

result = {{"bootstrap": BOOTSTRAP, "topic": TOPIC, "n": N, "status": "FAIL", "steps": []}}

def log(step, **kw):
    entry = {{"step": step, **kw}}
    result["steps"].append(entry)
    print(json.dumps(entry, default=str))

try:
    run_id = uuid.uuid4().hex[:8]
    log("init", run_id=run_id)

    # ---- PRODUCE ----
    log("produce_start")
    rows = [
        Row(key=f"k-{{i:03d}}-{{run_id}}", value=f"v-{{i:03d}}-payload-{{time.time():.3f}}")
        for i in range(N)
    ]
    df = spark.createDataFrame(rows)
    (df
        .selectExpr("CAST(key AS STRING) AS key", "CAST(value AS STRING) AS value")
        .write
        .format("kafka")
        .option("kafka.bootstrap.servers", BOOTSTRAP)
        .option("kafka.security.protocol", "PLAINTEXT")
        .option("topic", TOPIC)
        .save())
    log("produce_done", count=N)

    # ---- CONSUME ----
    log("consume_start")
    cdf = (spark.read
        .format("kafka")
        .option("kafka.bootstrap.servers", BOOTSTRAP)
        .option("kafka.security.protocol", "PLAINTEXT")
        .option("subscribe", TOPIC)
        .option("startingOffsets", "earliest")
        .option("endingOffsets", "latest")
        .load()
        .selectExpr("CAST(key AS STRING) AS key", "CAST(value AS STRING) AS value", "partition", "offset"))

    received = [(r.key, r.value) for r in cdf.collect()]
    matching = [(k, v) for k, v in received if run_id in (k or "")]
    log("consume_done", total_received=len(received), matched_this_run=len(matching))

    # ---- VERIFY ----
    if len(matching) == N:
        result["status"] = "PASS"
        result["sample"] = matching[:3]
        log("verify", message="PASS", matched=len(matching))
        print(f"PASS — produced {{N}} messages, consumed {{len(matching)}} matches from this run")
    else:
        log("verify", message="FAIL", matched=len(matching), expected=N)
        print(f"FAIL — expected {{N}} matches, got {{len(matching)}}")

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
    me = w.current_user.me().user_name
    notebook_path = f"/Users/{me}/kafka-producer-consumer-smoke-test"

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
        run_name=f"kafka-producer-consumer-smoke-{int(time.time())}",
        tasks=[
            SubmitTask(
                task_key="kafka_test",
                notebook_task=NotebookTask(notebook_path=notebook_path),
            )
        ],
    )
    run_id = submit.response.run_id if hasattr(submit, "response") else submit.run_id
    run_url = f"{host}/jobs/runs/{run_id}"
    print(f"Run ID:  {run_id}")
    print(f"Run URL: {run_url}")

    print("Polling for completion (up to ~15 min — Spark Kafka source has cold-start)...")
    info = None
    for i in range(90):
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
    if out.error:
        print(f"\nERROR: {out.error}")
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
