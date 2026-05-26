"""Smoke test runner — Databricks Connect against Serverless General Purpose.

Validates the L1+L2+L3+L4 path of the App Gateway v2 TCP/TLS proxy + NCC PE
rule architecture by executing a TLS-through-proxy test on Serverless compute.

Auth: uses Azure CLI (`az account get-access-token`) — no PAT token needed.

Run: `DATABRICKS_HOST=https://adb-<workspace>.azuredatabricks.net uv run python run_test.py`

Expected output:
  [1/4] DNS lookup for smoke-broker.appgw-test.example.com
        resolved to: <Databricks-managed private IP>
  [2/4] Opening TCP socket → connected
  [3/4] TLS handshake → established (TLS 1.3)
  [4/4] Round-trip echo → confirmed
  PASS — full L1+L2+L3+L4 path validated end-to-end
"""

import os
import sys


TEST_FQDN = os.environ.get("SMOKE_TEST_FQDN", "smoke-broker.appgw-test.example.com")
TEST_PORT = int(os.environ.get("SMOKE_TEST_PORT", "9092"))


def run_tls_smoke_test():
    """Executes ON Serverless compute (wrapped as a Spark UDF)."""
    import socket
    import ssl
    import datetime

    lines = []

    def log(msg):
        lines.append(msg)

    try:
        log(f"[1/4] DNS lookup for {TEST_FQDN}")
        ip = socket.gethostbyname(TEST_FQDN)
        log(f"      resolved to: {ip}")

        log(f"[2/4] Opening TCP socket to {TEST_FQDN}:{TEST_PORT}")
        raw = socket.create_connection((TEST_FQDN, TEST_PORT), timeout=15)
        log(f"      TCP connected from {raw.getsockname()} to {raw.getpeername()}")

        log(f"[3/4] TLS handshake (SNI={TEST_FQDN}, cert verification disabled)")
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        tls = ctx.wrap_socket(raw, server_hostname=TEST_FQDN)
        log(f"      TLS established. Cipher: {tls.cipher()}")
        peer_cert_head = tls.getpeercert(binary_form=True)[:60]
        log(f"      Peer cert (first 60 bytes): {peer_cert_head!r}")

        log(f"[4/4] Round-trip echo through the proxy")
        msg = f"hello-from-serverless-{datetime.datetime.utcnow().isoformat()}Z\n".encode()
        tls.sendall(msg)
        rx = tls.recv(8192)
        log(f"      sent: {msg!r}")
        log(f"      recv: {rx!r}")
        tls.close()

        if msg in rx:
            log("PASS — full L1+L2+L3+L4 path validated end-to-end")
        else:
            log(f"FAIL — echo did not contain sent message (received {len(rx)} bytes)")
    except Exception as e:
        log(f"FAIL — {type(e).__name__}: {e}")

    return "\n".join(lines)


def main():
    host = os.environ.get("DATABRICKS_HOST")
    if not host:
        print("ERROR: set DATABRICKS_HOST to your workspace URL (e.g., https://adb-XXXX.azuredatabricks.net)")
        sys.exit(2)

    os.environ["DATABRICKS_AUTH_TYPE"] = "azure-cli"

    from databricks.connect import DatabricksSession
    from pyspark.sql.types import StringType

    print(f"Connecting to {host} via Databricks Connect (Serverless)...")
    spark = (
        DatabricksSession.builder
        .serverless(True)
        .getOrCreate()
    )
    print("Serverless session ready. Submitting TLS smoke test as a UDF...")

    spark.udf.register("smoke_test", run_tls_smoke_test, StringType())
    rows = spark.sql("SELECT smoke_test() AS result").collect()
    result = rows[0]["result"]

    print()
    print("=" * 72)
    print("REMOTE EXECUTION OUTPUT (from Serverless worker):")
    print("=" * 72)
    print(result)
    print("=" * 72)

    if "PASS" in result:
        print("\n✅ Smoke test PASSED.")
        sys.exit(0)
    else:
        print("\n❌ Smoke test FAILED. See output above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
