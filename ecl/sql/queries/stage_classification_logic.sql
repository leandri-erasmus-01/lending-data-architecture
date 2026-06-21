-- =============================================================================
-- ECL: Stage Classification Logic
-- =============================================================================
-- Demonstrates the IFRS 9 staging rules described in docs/ECL_DESIGN.md,
-- applied as a single query producing a stage recommendation per loan as of
-- a given reporting date. This is the AUTOMATED_RULE path -- a credit risk
-- analyst can still apply a MANUAL_OVERRIDE on top (see
-- ecl.exposure_stage_history.classification_method), but every override
-- must reference what the automated rules would have produced.
--
-- Backstop thresholds (30+ DPD -> Stage 2, 90+ DPD -> Stage 3), the 2-notch
-- rating downgrade trigger, and the PD-deterioration ratio threshold are
-- CREDIT POLICY CHOICES, not values prescribed by IFRS 9 itself -- see
-- docs/ECL_DESIGN.md for why these specific defaults were adopted.
-- =============================================================================

WITH loan_snapshot AS (
    SELECT
        lp.loan_id,
        lp.product_type,
        lp.days_past_due,
        lp.outstanding_amount,
        lp.status,
        :reporting_date AS reporting_date
    FROM mart.fact_loan_performance lp
    WHERE lp.snapshot_date = :reporting_date
      AND lp.status = 'ACTIVE'
),

risk_signals AS (
    -- In production this joins to a credit risk system for rating/watchlist/
    -- forbearance data not currently modelled in fact_loan_performance.
    -- Represented here as a placeholder source for a self-contained example.
    SELECT
        loan_id,
        current_rating_notch,
        origination_rating_notch,
        watchlist_flag,
        forbearance_flag,
        unlikely_to_pay_flag
    FROM ecl._credit_risk_signals_placeholder
),

pd_comparison AS (
    SELECT
        pit.loan_id,
        pit.parameter_value AS pd_at_reporting_date,
        orig.parameter_value AS pd_at_origination,
        pit.parameter_value / orig.parameter_value AS pd_deterioration_ratio
    FROM ecl.risk_parameters_pit pit
    JOIN ecl.risk_parameters_pit orig
      ON orig.loan_id = pit.loan_id
     AND orig.parameter_type = 'PD'
     AND orig.horizon_type = '12_MONTH'
     AND orig.reporting_date = (
            SELECT MIN(reporting_date) FROM ecl.risk_parameters_pit
            WHERE loan_id = pit.loan_id AND parameter_type = 'PD'
         )  -- origination PD = the earliest PD ever recorded for this loan
    WHERE pit.parameter_type = 'PD'
      AND pit.horizon_type = '12_MONTH'
      AND pit.reporting_date = :reporting_date
      AND pit.scenario_id = (SELECT scenario_id FROM ecl.macro_scenario
                              WHERE reporting_date = :reporting_date AND scenario_name = 'BASELINE')
),

classification AS (
    SELECT
        s.loan_id,
        s.reporting_date,
        s.days_past_due,

        -- Stage 3 backstop and qualitative triggers
        CASE
            WHEN s.days_past_due >= 90 THEN TRUE
            WHEN r.unlikely_to_pay_flag = TRUE THEN TRUE
            ELSE FALSE
        END AS stage_3_triggered,

        -- Stage 2 backstop and triggers (only relevant if not already Stage 3)
        CASE
            WHEN s.days_past_due >= 30 THEN TRUE
            WHEN r.watchlist_flag = TRUE THEN TRUE
            WHEN r.forbearance_flag = TRUE THEN TRUE
            WHEN (r.origination_rating_notch - r.current_rating_notch) >= 2 THEN TRUE
            WHEN p.pd_deterioration_ratio >= 2.0 THEN TRUE   -- credit policy threshold: PD has doubled since origination
            ELSE FALSE
        END AS stage_2_triggered,

        r.watchlist_flag, r.forbearance_flag, r.unlikely_to_pay_flag,
        (r.origination_rating_notch - r.current_rating_notch) AS rating_notches_downgraded,
        p.pd_at_origination, p.pd_at_reporting_date, p.pd_deterioration_ratio

    FROM loan_snapshot s
    LEFT JOIN risk_signals r ON r.loan_id = s.loan_id
    LEFT JOIN pd_comparison p ON p.loan_id = s.loan_id
)

SELECT
    loan_id,
    reporting_date,
    CASE
        WHEN stage_3_triggered THEN 3
        WHEN stage_2_triggered THEN 2
        ELSE 1
    END AS recommended_stage,

    CASE
        WHEN stage_3_triggered AND days_past_due >= 90 THEN 'DPD_90_BACKSTOP'
        WHEN stage_3_triggered AND unlikely_to_pay_flag THEN 'UNLIKELY_TO_PAY'
        WHEN stage_2_triggered AND days_past_due >= 30 THEN 'DPD_30_BACKSTOP'
        WHEN stage_2_triggered AND watchlist_flag THEN 'WATCHLIST'
        WHEN stage_2_triggered AND forbearance_flag THEN 'FORBEARANCE'
        WHEN stage_2_triggered AND rating_notches_downgraded >= 2 THEN 'RATING_DOWNGRADE_2_NOTCH'
        WHEN stage_2_triggered AND pd_deterioration_ratio >= 2.0 THEN 'PD_DETERIORATION'
        ELSE 'NO_TRIGGER'
    END AS primary_trigger,

    days_past_due,
    pd_at_origination,
    pd_at_reporting_date,
    pd_deterioration_ratio,
    rating_notches_downgraded,
    watchlist_flag,
    forbearance_flag,
    unlikely_to_pay_flag

FROM classification
ORDER BY recommended_stage DESC, days_past_due DESC;

-- Note: this query produces a RECOMMENDATION. Writing the result to
-- ecl.exposure_stage_history additionally requires comparing against the
-- prior reporting_date's stage (to set stage_transition_type and
-- previous_stage) and checking for a 30+/90+ DPD rebuttal -- omitted here
-- for clarity; see ecl.exposure_stage_history schema comments.
