"""
etl/ingestion/aecb_sftp_loader.py

Represents the ASYNC, FILE-BASED ingestion pattern (AECB).

AECB does not respond synchronously — a request is submitted at application
time, and AECB processes it and drops a response file on SFTP some time later
(minutes to hours). This module is triggered by an S3 event when a new file
lands (via AWS Transfer Family), parses the XML, wraps it in the standard
Bronze ingestion envelope, and appends it to Bronze.

This is NOT a nightly bulk pull of the full customer base — see Architecture
Doc §2 (Assumptions) for why that model was rejected in favour of this one.
"""

import hashlib
import json
import uuid
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from xml.etree import ElementTree as ET

import boto3

s3 = boto3.client("s3")

BRONZE_BUCKET = "mal-lakehouse"
BRONZE_PREFIX = "bronze/aecb"

# In production this would be a durable lookup (e.g. DynamoDB) populated when
# the outbound AECB request was originally submitted, keyed on Emirates ID,
# mapping back to the application_id and internal_uuid that triggered it.
# AECB does not echo our application_id back, so WE are responsible for this
# correlation step (see Architecture Doc §4.1).
REQUEST_LOG_TABLE = "aecb_request_log"


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


def lookup_request_correlation(emirates_id: str) -> dict:
    """
    Resolve which application/customer this AECB response belongs to, using
    our own request log (NOT anything AECB returns to us).

    In production: a DynamoDB get_item call. Mocked here for illustration.
    """
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(REQUEST_LOG_TABLE)
    response = table.get_item(Key={"emirates_id": emirates_id})
    item = response.get("Item")
    if not item:
        raise LookupError(
            f"No outbound AECB request found for Emirates ID {emirates_id}. "
            "Cannot correlate this response to an application — routing to "
            "the unmatched-response exception queue."
        )
    return {"application_id": item["application_id"], "internal_uuid": item["internal_uuid"]}


def parse_aecb_report(xml_bytes: bytes) -> dict:
    """Extract the minimum identity field needed for correlation. Full field
    parsing into typed columns happens in Silver, not here — Bronze stores the
    raw payload untouched."""
    root = ET.fromstring(xml_bytes)
    emirates_id = root.findtext("./Subject/EmiratesId")
    generated_at = root.attrib.get("generatedAt")
    report_id = root.attrib.get("reportId")
    if not emirates_id:
        raise ValueError("AECB report missing Subject/EmiratesId — cannot correlate.")
    return {
        "emirates_id": emirates_id,
        "source_generated_at": generated_at,
        "source_event_id": report_id,
    }


def build_bronze_envelope(xml_bytes: bytes, file_key: str) -> BronzeEnvelope:
    parsed = parse_aecb_report(xml_bytes)
    correlation = lookup_request_correlation(parsed["emirates_id"])

    now = datetime.now(timezone.utc)
    content_hash = "sha256:" + hashlib.sha256(xml_bytes).hexdigest()

    return BronzeEnvelope(
        bronze_id=str(uuid.uuid4()),
        source_system="aecb",
        source_event_id=parsed["source_event_id"] or file_key,
        application_id=correlation["application_id"],
        internal_uuid=correlation["internal_uuid"],
        received_at=now.isoformat(),
        source_generated_at=parsed["source_generated_at"] or now.isoformat(),
        ingest_date=now.strftime("%Y-%m-%d"),
        content_hash=content_hash,
        schema_version="1.0",
        raw_payload=xml_bytes.decode("utf-8"),
    )


def write_to_bronze(envelope: BronzeEnvelope) -> str:
    """
    Append-only write. Idempotency is enforced via content_hash in the key —
    if the same file is delivered twice, it lands at the same S3 key and the
    second write is a harmless overwrite of identical content, never a
    duplicate logical row.
    """
    key = (
        f"{BRONZE_PREFIX}/ingest_date={envelope.ingest_date}/"
        f"{envelope.application_id}_{envelope.content_hash[7:19]}.json"
    )
    s3.put_object(
        Bucket=BRONZE_BUCKET,
        Key=key,
        Body=envelope.to_json(),
        ContentType="application/json",
    )
    return key


def handler(event, context):
    """
    S3 event handler — triggered when AWS Transfer Family lands a new AECB
    response file. One file may contain one customer's report (the common
    case) or, less commonly, a small batch of reports submitted together.
    """
    results = []
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]

        obj = s3.get_object(Bucket=bucket, Key=key)
        xml_bytes = obj["Body"].read()

        try:
            envelope = build_bronze_envelope(xml_bytes, file_key=key)
            written_key = write_to_bronze(envelope)
            results.append({"status": "OK", "bronze_key": written_key})
        except LookupError as e:
            # Unmatched response — cannot be silently dropped (audit
            # requirement). Routed to an exception path rather than raised
            # as an unhandled error, so one bad file doesn't block the batch.
            results.append({"status": "UNMATCHED", "file": key, "reason": str(e)})

    return {"processed": len(results), "results": results}
