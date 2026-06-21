-- =============================================================================
-- SILVER: Application Inputs (joined view)
-- =============================================================================
-- Joins the three per-source conformed tables on application_id into a single
-- row per application. This is the direct input to Gold's decision_input
-- table (sql/gold/gold_decision_input.sql) once must-pass DQ rules are applied.
--
-- LEFT JOINs are deliberate: at any given Silver run, a slower vendor
-- (typically AECB) may not have responded yet. The application stays visible
-- with NULLs for the missing source rather than being dropped — this is the
-- "AECB_PENDING" / "AML_PENDING" state referenced in the Architecture Doc.
-- =============================================================================

CREATE TABLE silver.lending_application_request (
    application_id                STRING,
    internal_uuid                 STRING,
    application_date              DATE,

    -- AECB
    aecb_score                    INT,
    aecb_band                     STRING,
    total_outstanding             DECIMAL(18,2),
    aecb_identity_status          STRING,

    -- Fraud
    fraud_score                   INT,
    risk_band                     STRING,
    fraud_identity_status         STRING,

    -- AML
    aml_status                    STRING,
    pep_flag                      BOOLEAN,
    match_score                   DECIMAL(4,3),
    aml_match_decision            STRING,

    -- Roll-up status, used by the must-pass gate before Gold
    pending_sources               ARRAY<STRING>  COMMENT 'List of sources not yet responded for this application, e.g. [''aecb'']',
    batch_date                    DATE          COMMENT 'Partition column — the Silver run date'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/silver/application_inputs/';

-- Build statement:
INSERT INTO silver.lending_application_request
SELECT
    COALESCE(a.application_id, f.application_id, m.application_id)   AS application_id,
    COALESCE(a.internal_uuid, f.internal_uuid, m.internal_uuid)         AS internal_uuid,
    CAST(COALESCE(a.aecb_report_date, f.fraud_scored_at, m.aml_screened_at) AS DATE) AS application_date,
    a.aecb_score, a.aecb_band, a.total_outstanding, a.identity_validation_status AS aecb_identity_status,
    f.fraud_score, f.risk_band, f.identity_validation_status AS fraud_identity_status,
    m.aml_status, m.pep_flag, m.match_score, m.match_decision AS aml_match_decision,
    ARRAY_REMOVE(ARRAY(
        CASE WHEN a.application_id IS NULL THEN 'aecb' END,
        CASE WHEN f.application_id IS NULL THEN 'fraud' END,
        CASE WHEN m.application_id IS NULL THEN 'aml' END
    ), NULL) AS pending_sources,
    CURRENT_DATE() AS batch_date
FROM silver.aecb_conformed   a
FULL OUTER JOIN silver.fraud_conformed f USING (application_id)
FULL OUTER JOIN silver.aml_conformed   m USING (application_id)
WHERE a.batch_date = CURRENT_DATE() OR f.batch_date = CURRENT_DATE() OR m.batch_date = CURRENT_DATE();

-- Note: a FULL OUTER JOIN (rather than a simple LEFT JOIN anchored on one
-- source) is used here so that no application is lost regardless of which
-- source responded first.
