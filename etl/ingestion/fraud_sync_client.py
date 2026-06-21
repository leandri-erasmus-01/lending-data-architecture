"""
etl/ingestion/fraud_sync_client.py

Represents the SYNCHRONOUS, REAL-TIME ingestion pattern (Fraud provider).

Unlike AECB (async file) and AML (async webhook), the fraud score is needed
INSIDE the decision itself, in well under a second. The decision service
calls the fraud API inline and uses the response immediately. Persisting the
raw response to Bronze must NOT block that call — so the write is decoupled
via a queue (SQS) and handled by a separate consumer.

This module shows both halves:
  1. score_applicant() — the synchronous, blocking call used by the decision
     service.
  2. The SQS consumer that durably persists the response to Bronze, a beat
     after the decision has already used it.
"""

import hashlib
import json
import uuid
from dataclasses import dataclass, asdict
from datetime import datetime, timezone

import boto3
import requests

s3 = boto3.client("s3")
sqs = boto3.client("sqs")

BRONZE_BUCKET = "mal-lakehouse"
BRONZE_PREFIX = "bronze/fraud"
PERSIST_QUEUE_URL = "https://sqs.me-central-1.amazonaws.com/xxxx/fraud-bronze-persist"

FRAUD_API_URL = "https://fraud-provider.example.com/v1/score"
FRAUD_API_TIMEOUT_SECONDS = 1.5  # the decision cannot wait long; fail fast and fall back


# -----------------------------------------------------------------------------
# 1. SYNCHRONOUS PATH — called inline by the decision service
# -----------------------------------------------------------------------------

def score_applicant(application_id: str, internal_uuid: str, phone: str, email: str) -> dict:
    """
    Blocking call made as part of the live decision flow. internal_uuid is
    NOT sent to the vendor (it has no meaning to them) — only phone and email,
    looked up from the internal profile before this call is made.

    Returns the parsed score immediately for the decision service to act on.
    Bronze persistence is fired off asynchronously and does not block this
    return.
    """
    response = requests.post(
        FRAUD_API_URL,
        json={"phone": phone, "email": email},
        timeout=FRAUD_API_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    payload = response.json()

    # Fire-and-forget: queue the raw response for durable Bronze persistence.
    # This does NOT block the return of fraud_score to the caller.
    _enqueue_for_bronze_persist(application_id, internal_uuid, payload)

    return {
        "fraud_score": payload["fraud_score"],
        "risk_band": payload["risk_band"],
    }


def _enqueue_for_bronze_persist(application_id: str, internal_uuid: str, payload: dict) -> None:
    sqs.send_message(
        QueueUrl=PERSIST_QUEUE_URL,
        MessageBody=json.dumps({
            "application_id": application_id,
            "internal_uuid": internal_uuid,
            "payload": payload,
            "captured_at": datetime.now(timezone.utc).isoformat(),
        }),
    )


# -----------------------------------------------------------------------------
# 2. ASYNC PATH — SQS consumer that durably writes to Bronze
# -----------------------------------------------------------------------------

@dataclass
class BronzeEnvelope:
    bronze_id: str
    source_system: str
    source_event_id: str
    application_id: str
    internal_uuid: str
    received_at: str
    source_generated_at: str
    ingest_date: str
    content_hash: str
    schema_version: str
    raw_payload: str

    def to_json(self) -> str:
        return json.dumps(asdict(self))


def build_bronze_envelope(message: dict) -> BronzeEnvelope:
    payload = message["payload"]
    raw_bytes = json.dumps(payload).encode("utf-8")
    content_hash = "sha256:" + hashlib.sha256(raw_bytes).hexdigest()
    now = datetime.now(timezone.utc)

    return BronzeEnvelope(
        bronze_id=str(uuid.uuid4()),
        source_system="fraud",
        source_event_id=payload.get("request_id", str(uuid.uuid4())),
        application_id=message["application_id"],
        internal_uuid=message["internal_uuid"],
        received_at=now.isoformat(),
        source_generated_at=payload.get("scored_at", message["captured_at"]),
        ingest_date=now.strftime("%Y-%m-%d"),
        content_hash=content_hash,
        schema_version="1.0",
        raw_payload=json.dumps(payload),
    )


def write_to_bronze(envelope: BronzeEnvelope) -> str:
    key = f"{BRONZE_PREFIX}/ingest_date={envelope.ingest_date}/{envelope.application_id}_{envelope.source_event_id}.json"
    s3.put_object(
        Bucket=BRONZE_BUCKET,
        Key=key,
        Body=envelope.to_json(),
        ContentType="application/json",
    )
    return key


def sqs_consumer_handler(event, context):
    """
    Lambda triggered by the SQS queue. Each message is the queued fraud
    response from a score_applicant() call made moments earlier by the
    decision service.
    """
    results = []
    for record in event["Records"]:
        message = json.loads(record["body"])
        envelope = build_bronze_envelope(message)
        key = write_to_bronze(envelope)
        results.append({"status": "OK", "bronze_key": key})
    return {"processed": len(results), "results": results}
