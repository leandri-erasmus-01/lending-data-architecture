-- =============================================================================
-- ECL: Risk Parameters -- Point-in-Time (PIT)
-- =============================================================================
-- Stores PIT PD, LGD, and EAD -- the parameters actually used to calculate
-- the ECL booked under IFRS 9, since IFRS 9 requires current, forward-looking
-- estimates rather than cycle-smoothed ones. PD is stored as a TERM STRUCTURE
-- (one row per future period, not a single number) because Stage 2/3 lifetime
-- ECL requires a marginal PD per period, discounted back to present value --
-- a single scalar PD cannot represent this.
--
-- Every parameter set is versioned (model_version) and tied to the specific
-- macro scenario it was generated under, since PIT parameters are inherently
-- scenario-conditional (a PIT PD under a "severe" macro scenario differs from
-- the same loan's PIT PD under "baseline").
-- =============================================================================

CREATE TABLE ecl.risk_parameters_pit (
    parameter_id                 STRING      COMMENT 'Surrogate key (UUID)',
    loan_id                      STRING      COMMENT 'Joins to mart.fact_loan_performance.loan_id',
    reporting_date               DATE        COMMENT 'The reporting date this parameter set applies to',
    scenario_id                  STRING      COMMENT 'Joins to ecl.macro_scenario -- PIT parameters are scenario-conditional',

    parameter_type               STRING      COMMENT 'PD | LGD | EAD',
    horizon_type                 STRING      COMMENT '12_MONTH | LIFETIME -- 12_MONTH for Stage 1 PD; LIFETIME term structure for Stage 2/3',
    period_number                INT         COMMENT 'For LIFETIME PD term structures: 1, 2, 3... periods ahead. NULL for 12_MONTH PD, and for LGD/EAD (point estimates, not term structures)',

    parameter_value              DECIMAL(12,6) COMMENT 'The PD (as a decimal probability), LGD (as a decimal loss rate), or EAD (as a currency amount), per parameter_type',

    model_id                     STRING      COMMENT 'Identifies which PD/LGD/EAD model produced this value',
    model_version                STRING      COMMENT 'Version of that model -- required so a historical ECL figure can be reproduced using the model that was actually live at the time',
    model_segment                STRING      COMMENT 'The model segment/cohort this loan was scored under, e.g. product_type + risk_grade band',

    calculated_at                TIMESTAMP,
    batch_date                   DATE        COMMENT 'Partition column'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/ecl/risk_parameters_pit/';

-- Notes:
--   * EAD for revolving/flexible products (e.g. the credit-card alternative)
--     should reflect projected further drawdown on undrawn limits, not just
--     the current outstanding balance -- this is a modelling input baked
--     into parameter_value at calculation time, not a separate field here.
--   * LGD is typically modelled at the segment level (product_type x
--     collateral_type) rather than per-loan from first principles -- the
--     model_segment column makes this traceable without requiring a
--     separate collateral-valuation schema for what is, for Mal's three
--     products, predominantly unsecured lending.
