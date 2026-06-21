-- =============================================================================
-- BRONZE: Internal Customer Profile (CDC from PostgreSQL)
-- =============================================================================
-- Source pattern : Continuous change-data-capture (AWS DMS) from the internal
--                   Postgres customer_profile table. Independent of any single
--                   application — captures profile updates as they happen.
-- Match key       : internal_uuid (this IS the canonical key / identity spine)
-- Write pattern   : Append-only. Each CDC event (insert/update) lands as a new
--                   row; we never overwrite history, so prior profile states
--                   remain queryable.
-- =============================================================================

CREATE TABLE bronze.internal_profile (
    bronze_id               STRING      COMMENT 'Surrogate key for this raw record (UUID)',
    source_system           STRING      COMMENT 'Always ''internal''',
    source_event_id         STRING      COMMENT 'DMS change event ID / LSN',
    application_id          STRING      COMMENT 'NULL for most rows — profile changes are not application-triggered. Populated only if the change occurred as a direct side-effect of an application.',
    internal_uuid           STRING      COMMENT 'Canonical customer identifier',
    received_at             TIMESTAMP   COMMENT 'When the CDC event was captured and written',
    source_generated_at     TIMESTAMP   COMMENT 'Timestamp of the change in the source Postgres table',
    ingest_date             DATE        COMMENT 'Partition column, derived from received_at',
    schema_version          STRING      COMMENT 'Internal profile table schema version',
    raw_payload             STRING      COMMENT 'Entire original row image (JSON-encoded), untouched'
)
PARTITIONED BY (ingest_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/bronze/internal_profile/'
TBLPROPERTIES ('write.format.default' = 'parquet');

-- Notes:
--   * The internal profile holds Emirates ID, customer name, DOB, email and
--     phone for every customer — it is the only source holding every
--     attribute the other three vendors need, which is why it is the
--     identity anchor for the whole pipeline (see Architecture Doc, §2).
--   * raw_payload here is expected to contain at minimum:
--       emirates_id, full_name, dob, email, phone, internal_uuid
