-- =============================================================================
-- ECL: Macro Scenario
-- =============================================================================
-- IFRS 9 requires ECL to reflect "reasonable and supportable forward-looking
-- information" -- in practice, this means running PD (and therefore ECL)
-- under multiple macroeconomic scenarios and probability-weighting the
-- result, rather than using a single deterministic forecast. This table
-- defines the scenario set and weights used for a given reporting date.
-- =============================================================================

CREATE TABLE ecl.macro_scenario (
    scenario_id               STRING      COMMENT 'Surrogate key, referenced by ecl.risk_parameters_pit.scenario_id',
    reporting_date            DATE        COMMENT 'The reporting date this scenario set applies to -- weights are reassessed each period',

    scenario_name             STRING      COMMENT 'BASELINE | ADVERSE | SEVERE -- the conventional minimum 3-scenario set',
    scenario_weight           DECIMAL(5,4) COMMENT 'Probability weight assigned to this scenario; weights across all scenarios for a reporting_date must sum to 1.0',

    -- Illustrative macro variables the PD models are sensitive to. The
    -- specific variable set is a model-design choice; these are representative
    -- for a UAE consumer-lending portfolio.
    uae_unemployment_rate     DECIMAL(6,4),
    eibor_3m                  DECIMAL(6,4),
    oil_price_usd_bbl         DECIMAL(8,2)    COMMENT 'Relevant given UAE GDP sensitivity to oil, even for a consumer lender',
    real_gdp_growth_pct       DECIMAL(6,4),

    scenario_set_version      STRING      COMMENT 'Version tag for the scenario assumptions -- the macro forecasts themselves are revised periodically by the economics/risk function',
    approved_by               STRING      COMMENT 'Risk committee or equivalent sign-off on the scenario weights for this reporting_date',
    defined_at                TIMESTAMP,
    batch_date                DATE        COMMENT 'Partition column'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/ecl/macro_scenario/';

-- Note: a CHECK constraint enforcing SUM(scenario_weight) = 1.0 per
-- reporting_date is not expressible as a column-level constraint in this
-- engine; it is enforced as a batch-level validation rule (see
-- data_quality/ for the established pattern) rather than at the DDL level.
