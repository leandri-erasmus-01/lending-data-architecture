-- =============================================================================
-- ECL: Risk Parameters -- Through-the-Cycle (TTC)
-- =============================================================================
-- Stores TTC PD, LGD, and EAD -- cycle-averaged risk parameters used for
-- Basel regulatory capital purposes and as a benchmark/sanity-check against
-- the PIT parameters actually driving the IFRS 9 ECL booked. TTC parameters
-- are NOT scenario-conditional (that is the defining difference from PIT --
-- they are smoothed across a full economic cycle specifically to remove
-- short-term macro sensitivity), so there is no scenario_id here.
--
-- Structurally near-identical to risk_parameters_pit by design: this makes
-- the PIT-vs-TTC reconciliation query (see queries/) a straightforward join
-- rather than a schema-mapping exercise.
-- =============================================================================

CREATE TABLE ecl.risk_parameters_ttc (
    parameter_id                 STRING      COMMENT 'Surrogate key (UUID)',
    loan_id                      STRING      COMMENT 'Joins to mart.fact_loan_performance.loan_id',
    reporting_date               DATE        COMMENT 'The reporting date this parameter set applies to',

    parameter_type               STRING      COMMENT 'PD | LGD | EAD',
    horizon_type                 STRING      COMMENT '12_MONTH | LIFETIME',
    period_number                INT         COMMENT 'For LIFETIME PD term structures: 1, 2, 3... periods ahead. NULL otherwise',

    parameter_value              DECIMAL(12,6) COMMENT 'The cycle-averaged PD, LGD, or EAD',

    cycle_window_start           DATE        COMMENT 'Start of the economic cycle window the average is computed over',
    cycle_window_end             DATE        COMMENT 'End of the economic cycle window',

    model_id                     STRING      COMMENT 'Identifies which PD/LGD/EAD model produced this value',
    model_version                STRING,
    model_segment                STRING      COMMENT 'product_type + risk_grade band, consistent with risk_parameters_pit',

    calculated_at                TIMESTAMP,
    batch_date                   DATE        COMMENT 'Partition column'
)
PARTITIONED BY (batch_date)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/ecl/risk_parameters_ttc/';

-- Notes:
--   * TTC parameters are retained primarily as a regulatory-capital input
--     and a model-validation benchmark -- the ECL actually booked under
--     IFRS 9 (ecl.ecl_calculation) is always derived from PIT parameters,
--     never TTC. A large, sustained divergence between a loan's PIT and TTC
--     PD is itself a useful model-governance signal, surfaced via
--     queries/pit_vs_ttc_reconciliation.sql.
--   * For a new lender such as Mal, an internally-derived TTC curve will not
--     be credible until enough of a credit cycle has been observed --
--     industry practice is to anchor early TTC estimates to bureau-level or
--     industry benchmark data and recalibrate as internal history
--     accumulates (see docs/ECL_DESIGN.md).
