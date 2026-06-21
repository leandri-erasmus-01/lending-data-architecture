-- =============================================================================
-- ECL: Exposure Stage History
-- =============================================================================
-- Tracks IFRS 9 Stage 1/2/3 classification per loan, per reporting date, with
-- full transition history. A loan's CURRENT stage is simply the most recent
-- row for that loan_id; every transition (in either direction — including
-- cures, e.g. Stage 2 -> Stage 1) is preserved as a new row, never an update
-- to an existing one. This is the audit trail requirement: any past stage
-- classification, and the reason it was assigned, must be reconstructable
-- without relying on application logs.
--
-- Sources feeding this table: mart.fact_loan_performance (days_past_due,
-- delinquency_bucket) plus risk-grade and watchlist/forbearance flags that
-- are not currently modelled in fact_loan_performance and would need to be
-- added there or sourced from a credit risk system.
-- =============================================================================

CREATE TABLE ecl.exposure_stage_history (
    stage_history_id                STRING      COMMENT 'Surrogate key (UUID) for this stage record',
    loan_id                         STRING      COMMENT 'Joins to mart.fact_loan_performance.loan_id',
    reporting_date                  DATE        COMMENT 'The reporting date this stage classification applies to',

    current_stage                   INT         COMMENT '1 | 2 | 3',
    previous_stage                  INT         COMMENT 'Stage as of the prior reporting date, NULL for a loan''s first classification',
    stage_transition_type           STRING      COMMENT 'NEW_ORIGINATION | STAGE_UPGRADE | STAGE_DOWNGRADE | CURE | NO_CHANGE',

    -- SICR / default trigger evidence — the "why" behind the classification
    days_past_due                   INT         COMMENT 'Sourced from mart.fact_loan_performance as of reporting_date',
    dpd_backstop_triggered          BOOLEAN     COMMENT 'TRUE if 30+ DPD (Stage 2 backstop) or 90+ DPD (Stage 3 backstop) fired',
    pd_at_origination               DECIMAL(8,6)  COMMENT '12-month PD assigned at origination — the baseline SICR compares against',
    pd_at_reporting_date            DECIMAL(8,6)  COMMENT 'Current 12-month PD as of this reporting date',
    pd_deterioration_ratio          DECIMAL(8,4)  COMMENT 'pd_at_reporting_date / pd_at_origination -- a model-driven SICR signal independent of DPD',
    rating_notches_downgraded       INT         COMMENT 'Internal credit rating notches downgraded since origination',
    watchlist_flag                  BOOLEAN     COMMENT 'Placed on credit risk committee watchlist',
    forbearance_flag                BOOLEAN     COMMENT 'Subject to forbearance/restructuring due to financial difficulty',
    unlikely_to_pay_flag            BOOLEAN     COMMENT 'Assessed unlikely to pay in full without collateral realisation -- a Stage 3 qualitative trigger',

    sicr_backstop_rebutted          BOOLEAN     COMMENT 'TRUE if the 30+/90+ DPD presumption was rebutted with documented evidence -- see rebuttal_reason',
    rebuttal_reason                 STRING      COMMENT 'Required if sicr_backstop_rebutted = TRUE; e.g. documented administrative delay by a financially healthy borrower',

    primary_trigger                 STRING      COMMENT 'The single trigger that determined this classification, e.g. DPD_30_BACKSTOP | RATING_DOWNGRADE_2_NOTCH | WATCHLIST | PD_DETERIORATION | DPD_90_BACKSTOP | UNLIKELY_TO_PAY',
    classification_method           STRING      COMMENT 'AUTOMATED_RULE | MANUAL_OVERRIDE',
    override_approved_by            STRING      COMMENT 'Populated only when classification_method = MANUAL_OVERRIDE -- analyst/committee approving the override',
    override_justification          STRING      COMMENT 'Required narrative when a manual override changes what the automated rules would have produced',

    credit_policy_version           STRING      COMMENT 'Version of the SICR/default credit policy rules applied -- thresholds are a policy choice, not an IFRS 9-prescribed number, and the version used must be traceable',
    classified_at                   TIMESTAMP   COMMENT 'When this classification was computed/recorded',
    batch_date                      DATE        COMMENT 'Partition column -- the ECL batch run date'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/ecl/exposure_stage_history/';

-- Notes:
--   * A loan's CURRENT stage at any point in time is the row with the most
--     recent reporting_date for that loan_id -- there is no separate
--     "current state" table; querying for the latest row IS the current
--     state, consistent with the append-only philosophy used throughout
--     the rest of this architecture (see sql/bronze/*.sql).
--   * Every stage classification -- not just transitions -- is recorded
--     each reporting period (stage_transition_type = NO_CHANGE is a valid,
--     expected, frequent value), so the full population's stage history is
--     always queryable for any past reporting_date without gaps.
--   * dpd_backstop_triggered can be TRUE while current_stage remains lower
--     than the backstop implies, ONLY if sicr_backstop_rebutted = TRUE and a
--     rebuttal_reason is recorded -- the rebuttal itself is never silent.
