-- =============================================================================
-- SILVER: Match Audit
-- =============================================================================
-- Records every cross-validation outcome — automatic match or exception —
-- across all three external sources. Required to support manual review and
-- to explain any identity-matching outcome to compliance or CBUAE on request.
-- See Architecture Doc §4.4.
-- =============================================================================

CREATE TABLE silver.match_audit (
    audit_id                     STRING      COMMENT 'Surrogate key (UUID)',
    application_id               STRING,
    internal_uuid                STRING,
    source_system                STRING      COMMENT 'aecb | fraud | aml',
    submitted_identifier         STRING      COMMENT 'What we sent the vendor, e.g. "784-1990-1234567-8" or "Ahmed Al Mansoori|1990-03-15"',
    returned_identifier          STRING      COMMENT 'What the vendor sent back',
    match_type                   STRING      COMMENT 'DETERMINISTIC | PROBABILISTIC',
    match_score                  DECIMAL(4,3)  COMMENT 'NULL for deterministic checks; 0.000-1.000 for AML',
    match_decision               STRING      COMMENT 'AUTO_MATCH | MANUAL_REVIEW | NO_MATCH | MISMATCH',
    exception_reason             STRING      COMMENT 'Populated only when match_decision is not AUTO_MATCH, e.g. "cross_uuid_collision", "weak_name_similarity"',
    rule_version                 STRING      COMMENT 'Version tag of the matching logic that produced this result',
    evaluated_at                 TIMESTAMP,
    batch_date                   DATE        COMMENT 'Partition column'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/silver/match_audit/';

-- This table is the audit source for the match_exceptions and manual-review
-- queues referenced in the Architecture Doc. A simple operational view:
--
-- CREATE VIEW silver.match_exceptions AS
-- SELECT * FROM silver.match_audit
-- WHERE match_decision IN ('MANUAL_REVIEW', 'NO_MATCH', 'MISMATCH');
