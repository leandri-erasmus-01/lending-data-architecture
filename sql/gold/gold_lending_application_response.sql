-- =============================================================================
-- GOLD: Lending Application Response
-- =============================================================================
-- Written ONCE per application by the credit policy/decision engine (out of
-- scope for this pipeline — this table is its output, consumed by us).
-- This is a structurally separate table on a separate trigger from
-- lending_application_request: lending_application_request is written as inputs become available;
-- lending_application_response is written the moment a verdict is reached.
--
-- The write of this row is also the trigger for the immutable decision
-- snapshot (see docs/DECISIONS.md, Architecture Doc §5).
-- =============================================================================

CREATE TABLE gold.lending_application_response (
    application_id            STRING,
    internal_uuid             STRING,
    decision_outcome          STRING      COMMENT 'APPROVED | DECLINED | REFER',
    decision_reason_code      STRING,
    policy_version            STRING,
    decided_at                TIMESTAMP,
    decided_by                STRING      COMMENT '''AUTO'' or an underwriter ID for manual review',
    batch_date                DATE        COMMENT 'Partition column'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/gold/decision_outcomes/'
TBLPROPERTIES ('table_type' = 'ICEBERG');

-- Audit note: rows in this table, together with the lending_application_request row they
-- reference (joined on application_id), should additionally be persisted to
-- a WORM (S3 Object Lock) snapshot store at write time — this table alone is
-- the queryable analytical copy, not the tamper-proof legal record.
