# Databricks notebook source
"""Smoke test Confluent Kafka connectivity from Databricks serverless compute.

Expected widgets:
  bootstrap_servers: Confluent bootstrap servers including port.
  topic: Existing Kafka topic to write/read.
  secret_scope: Databricks secret scope holding Confluent credentials.
  api_key_secret: Secret key for the Confluent API key.
  api_secret_secret: Secret key for the Confluent API secret.
"""

import time
import uuid

from pyspark.sql import functions as F


dbutils.widgets.text("bootstrap_servers", "")
dbutils.widgets.text("topic", "")
dbutils.widgets.text("secret_scope", "")
dbutils.widgets.text("api_key_secret", "confluent-api-key")
dbutils.widgets.text("api_secret_secret", "confluent-api-secret")

bootstrap_servers = dbutils.widgets.get("bootstrap_servers").strip()
topic = dbutils.widgets.get("topic").strip()
secret_scope = dbutils.widgets.get("secret_scope").strip()
api_key_secret = dbutils.widgets.get("api_key_secret").strip()
api_secret_secret = dbutils.widgets.get("api_secret_secret").strip()

missing = [
    name
    for name, value in {
        "bootstrap_servers": bootstrap_servers,
        "topic": topic,
        "secret_scope": secret_scope,
        "api_key_secret": api_key_secret,
        "api_secret_secret": api_secret_secret,
    }.items()
    if not value
]
if missing:
    raise ValueError(f"Missing required widget values: {', '.join(missing)}")

api_key = dbutils.secrets.get(secret_scope, api_key_secret)
api_secret = dbutils.secrets.get(secret_scope, api_secret_secret)

kafka_options = {
    "kafka.bootstrap.servers": bootstrap_servers,
    "kafka.security.protocol": "SASL_SSL",
    "kafka.sasl.mechanism": "PLAIN",
    "kafka.sasl.jaas.config": (
        "org.apache.kafka.common.security.plain.PlainLoginModule required "
        f"username='{api_key}' password='{api_secret}';"
    ),
}

message_key = f"databricks-ncc-appgw-topic-{uuid.uuid4()}"
message_value = f"hello-from-databricks-serverless-{int(time.time())}"

payload = spark.createDataFrame([(message_key, message_value)], ["key", "value"]).select(
    F.col("key").cast("string"),
    F.col("value").cast("string"),
)

payload.write.format("kafka").options(**kafka_options).option("topic", topic).save()

deadline = time.time() + 120
matches = []

while time.time() < deadline:
    df = (
        spark.read.format("kafka")
        .options(**kafka_options)
        .option("subscribe", topic)
        .option("startingOffsets", "earliest")
        .option("endingOffsets", "latest")
        .load()
        .select(
            F.col("key").cast("string").alias("key"),
            F.col("value").cast("string").alias("value"),
        )
        .where(F.col("key") == message_key)
        .limit(1)
    )

    matches = df.collect()
    if matches:
        break
    time.sleep(5)

if not matches:
    raise TimeoutError(
        f"Produced key {message_key} to {topic}, but did not read it back within 120 seconds."
    )

print(
    "Kafka smoke test succeeded: wrote and read "
    f"key={message_key}, value={matches[0]['value']}"
)
