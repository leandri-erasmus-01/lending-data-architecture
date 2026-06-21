-- =============================================================================
-- ECL: ECL Calculation
-- =============================================================================
-- The booked provision figure -- ECL = PD x LGD x EAD, per scenario, then
-- probability-weighted across scenarios per ecl.macro_scenario, then
-- (for Stage 2/3) discounted to present value using the loan's effective
-- interest rate. This table stores BOTH the per-scenario intermediate result
-- and the final probability-weighted figure, so the calculation is fully
-- reproducible and explainable to an auditor without re-running any model.
--
-- Grain: one row per loan, per reporting_date, per scenario -- plus one
-- additional row per loan/reporting_date where scenario_id IS NULL,
-- representing the final probability-weighted ECL actually booked.
-- =============================================================================

CREATE TABLE ecl.ecl_calculation (
    ecl_calculation_id                      STRING      COMMENT 'Surrogate key (UUID)',
    loan_id                                 STRING      COMMENT 'Joins to mart.fact_loan_performance.loan_id',
    reporting_date                          DATE        COMMENT 'The reporting date this ECL figure applies to',
    stage_history_id                        STRING      COMMENT 'Joins to ecl.exposure_stage_history -- the stage classification this ECL is consistent with',

    scenario_id                              STRING      COMMENT 'Joins to ecl.macro_scenario. NULL for the final probability-weighted row.',
    is_probability_weighted_result           BOOLEAN     COMMENT 'TRUE for the single row per loan/reporting_date representing the final booked ECL',

    current_stage                            INT         COMMENT 'Denormalised from exposure_stage_history for query convenience -- 1 | 2 | 3',
    ecl_horizon                              STRING      COMMENT '12_MONTH (Stage 1) | LIFETIME (Stage 2/3)',

    pd_used                                  DECIMAL(8,6)  COMMENT 'For 12_MONTH: the single 12-month PD. For LIFETIME: NULL here -- see ecl_lifetime_period_detail for the term-structure breakdown',
    lgd_used                                 DECIMAL(8,6),
    ead_used                                 DECIMAL(18,2),

    gross_ecl_undiscounted                   DECIMAL(18,2) COMMENT 'PD x LGD x EAD before discounting -- populated for Stage 1; for Stage 2/3 this is the SUM across the lifetime term structure, see ecl_lifetime_period_detail',
    effective_interest_rate                  DECIMAL(8,6)  COMMENT 'EIR used to discount future expected shortfalls to present value',
    ecl_present_value                        DECIMAL(18,2) COMMENT 'The discounted ECL figure -- for Stage 1 this typically approximates gross_ecl_undiscounted given the short 12-month horizon',

    pd_parameter_id                          STRING      COMMENT 'Joins to ecl.risk_parameters_pit -- traceability back to the exact PD value/version used',
    lgd_parameter_id                         STRING      COMMENT 'Joins to ecl.risk_parameters_pit',
    ead_parameter_id                         STRING      COMMENT 'Joins to ecl.risk_parameters_pit',

    management_overlay_amount                DECIMAL(18,2) DEFAULT 0 COMMENT 'Manual adjustment where model output is judged not to fully capture current conditions -- IFRS 9 explicitly permits this; must never be silently blended into ecl_present_value without being separately visible here',
    overlay_justification                    STRING      COMMENT 'Required narrative if management_overlay_amount <> 0',
    overlay_approved_by                      STRING,

    calculation_method_version               STRING      COMMENT 'Version of the ECL calculation logic/engine itself, distinct from the PD/LGD/EAD model versions',
    calculated_at                            TIMESTAMP,
    batch_date                               DATE        COMMENT 'Partition column'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/ecl/ecl_calculation/';


-- =============================================================================
-- ECL: Lifetime Period Detail (supporting table for Stage 2/3 term structures)
-- =============================================================================
-- Stage 2/3 lifetime ECL is a SUM across future periods of (marginal PD in
-- that period x LGD x EAD), discounted -- not a single multiplication. This
-- table holds that per-period breakdown, referenced by gross_ecl_undiscounted
-- in ecl_calculation above for any LIFETIME-horizon row.
-- =============================================================================

CREATE TABLE ecl.ecl_lifetime_period_detail (
    period_detail_id              STRING      COMMENT 'Surrogate key (UUID)',
    ecl_calculation_id            STRING      COMMENT 'Joins to ecl.ecl_calculation.ecl_calculation_id',
    period_number                 INT         COMMENT 'Periods ahead from reporting_date -- 1, 2, 3...',

    marginal_pd_this_period       DECIMAL(8,6)  COMMENT 'PD of defaulting specifically in this period, conditional on surviving to it',
    lgd_this_period               DECIMAL(8,6),
    ead_this_period               DECIMAL(18,2) COMMENT 'Projected exposure at this future period -- amortises down over time for a fixed-schedule loan',

    undiscounted_shortfall        DECIMAL(18,2) COMMENT 'marginal_pd_this_period x lgd_this_period x ead_this_period',
    discount_factor               DECIMAL(10,8) COMMENT 'Based on effective_interest_rate and period_number',
    discounted_shortfall          DECIMAL(18,2) COMMENT 'undiscounted_shortfall x discount_factor -- these sum to gross ECL for this scenario',

    batch_date                    DATE        COMMENT 'Partition column'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/ecl/ecl_lifetime_period_detail/';
