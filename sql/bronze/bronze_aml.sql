-- =============================================================================
-- BRONZE: AML / PEP Screening
-- =============================================================================
-- Source pattern : Asynchronous webhook callback. Screening request submitted
--                   at application time; provider calls back independently,
--                   typically within minutes, in an unpredictable order.
-- Match key       : Name + DOB (probabilistic — see silver_match_audit.sql)
-- Write pattern   : Append-only. Never updated or overwritten. Idempotent on
--                   source_event_id to absorb duplicate/out-of-order callbacks.
-- =============================================================================

CREATE TABLE bronze.aml (
    bronze_id               STRING      COMMENT 'Surrogate key for this raw record (UUID)',
    source_system           STRING      COMMENT 'Always ''aml''',
    source_event_id         STRING      COMMENT 'AML provider''s event_id for this screening result',
    application_id          STRING      COMMENT 'Correlation ID WE sent to the AML provider in the original screening request; echoed back in the callback payload',
    internal_uuid           STRING      COMMENT 'Canonical customer identifier, known before the screening request was submitted',
    received_at             TIMESTAMP   COMMENT 'When the webhook callback was received and written',
    source_generated_at     TIMESTAMP   COMMENT 'Timestamp the AML provider reports inside the callback payload',
    ingest_date             DATE        COMMENT 'Partition column, derived from received_at',
    schema_version          STRING      COMMENT 'AML provider callback format version',
    raw_payload             STRING      COMMENT 'Entire original JSON payload, untouched, stored as text'
)
PARTITIONED BY (ingest_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/bronze/aml/'
TBLPROPERTIES ('write.format.default' = 'parquet');

-- Notes:
--   * This is the one source where WE must pass application_id (as event_id)
--     into the outbound request, because the provider's response arrives
--     independently and there is no other reliable way to correlate it back —
--     see etl/ingestion/aml_webhook_handler.py.
--   * The webhook handler enforces idempotency on source_event_id (conditional
--     S3 write) so a duplicate or retried callback does not create two rows.
--   * AML screening returns a similarity result against external watchlists,
--     not an exact echo — the resulting match_score and match_decision are
--     computed downstream in Silver, never in Bronze.
