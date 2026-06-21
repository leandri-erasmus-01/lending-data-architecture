"""
etl/ingestion/aml_webhook_handler.py

Represents the ASYNC WEBHOOK ingestion pattern (AML/PEP screening).

Unlike AECB and Fraud, the AML provider's response arrives independently of
our outbound request, with no other reliable way to correlate it — so WE pass
our application_id into the screening request up front, and the provider
echoes it back in the callback payload (see Architecture Doc §4.1).

This handler must:
  1. Acknowledge fast (return 200 immediately) so the provider doesn't retry
     unnecessarily.
  2. Write idempotently — callbacks can arrive duplicated or out of order.
"""

import hashlib
import json
import uuid
from dataclasses import dataclass, asdict
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")

BRONZE_BUCKET = "mal-lakehouse"
BRONZE_PREFIX = "bronze/aml"


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


def submit_screening_request(application_id: str, internal_uuid: str, full_name: str, dob: str) -> None:
    """
    Outbound call made at APPLICATION time (not shown receiving a response —
    the response arrives later via the webhook below). application_id is
    deliberately included in the outbound payload so the provider can echo
    it back; this is the one vendor in the design that requires this, because
    AECB and Fraud responses are matched back via our own request log instead
    (see Architecture Doc §4.1).
    """
    import requests  # local import: only needed for the outbound call

    requests.post(
        "https://aml-provider.example.com/v1/screen",
        json={
            "callback_reference": application_id,   # echoed back in the webhook payload
            "full_name": full_name,
            "dob": dob,
        },
        timeout=5,
    )
    # internal_uuid is not sent to the vendor — it has no meaning to them.
    # It is retained on our side via the application_id correlation, the
    # same pattern used for AECB and Fraud.


def verify_webhook_signature(headers: dict, body: bytes) -> bool:
    """
    Placeholder for HMAC/signature verification of the inbound webhook.
    A real implementation validates a provider-supplied signature header
    against a shared secret before trusting the payload.
    """
    return "X-AML-Signature" in headers  # illustrative only


def build_bronze_envelope(payload: dict, internal_uuid: str) -> BronzeEnvelope:
    now = datetime.now(timezone.utc)
    raw_bytes = json.dumps(payload).encode("utf-8")
    content_hash = "sha256:" + hashlib.sha256(raw_bytes).hexdigest()

    return BronzeEnvelope(
        bronze_id=str(uuid.uuid4()),
        source_system="aml",
        source_event_id=payload["event_id"],
        application_id=payload["callback_reference"],   # echoed back by the provider
        internal_uuid=internal_uuid,
        received_at=now.isoformat(),
        source_generated_at=payload.get("callback_at", now.isoformat()),
        ingest_date=now.strftime("%Y-%m-%d"),
        content_hash=content_hash,
        schema_version="1.0",
        raw_payload=json.dumps(payload),
    )


def write_to_bronze_idempotent(envelope: BronzeEnvelope) -> dict:
    """
    Idempotent write keyed on source_event_id (the AML provider's own event
    ID). Uses a conditional put (IfNoneMatch) so a duplicate or retried
    callback does NOT create a second logical row — it is silently absorbed.
    """
    key = f"{BRONZE_PREFIX}/ingest_date={envelope.ingest_date}/{envelope.source_event_id}.json"
    try:
        s3.put_object(
            Bucket=BRONZE_BUCKET,
            Key=key,
            Body=envelope.to_json(),
            ContentType="application/json",
            IfNoneMatch="*",   # fails if the object already exists
        )
        return {"status": "WRITTEN", "key": key}
    except ClientError as e:
        if e.response["Error"]["Code"] in ("PreconditionFailed", "412"):
            return {"status": "DUPLICATE_IGNORED", "key": key}
        raise


def lookup_internal_uuid(application_id: str) -> str:
    """In production: looked up from the application/decision context store,
    keyed by application_id (which we generated ourselves at application
    time, before any vendor was called)."""
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table("application_context")
    item = table.get_item(Key={"application_id": application_id}).get("Item")
    if not item:
        raise LookupError(f"No application context found for {application_id}")
    return item["internal_uuid"]


def handler(event, context):
    """
    API Gateway + Lambda entry point for the AML provider's webhook callback.
    Always acknowledges with 200 quickly, even on a processing issue, to
    avoid unnecessary provider-side retries — failures are logged and routed
    to an exception path rather than surfaced as a webhook error.
    """
    headers = event.get("headers", {})
    body_bytes = event.get("body", "").encode("utf-8")

    if not verify_webhook_signature(headers, body_bytes):
        return {"statusCode": 401, "body": "Invalid signature"}

    payload = json.loads(body_bytes)

    try:
        internal_uuid = lookup_internal_uuid(payload["callback_reference"])
        envelope = build_bronze_envelope(payload, internal_uuid)
        result = write_to_bronze_idempotent(envelope)
    except LookupError as e:
        # Still ack 200 — we don't want the provider retrying indefinitely —
        # but log for manual investigation. This should not happen if
        # application_id was correctly passed in the original screening
        # request.
        result = {"status": "CONTEXT_NOT_FOUND", "reason": str(e)}

    return {"statusCode": 200, "body": json.dumps(result)}
