-- =============================================================================
-- ECL: PIT vs. TTC Reconciliation
-- =============================================================================
-- Compares point-in-time risk parameters (used for the IFRS 9 ECL actually
-- booked) against through-the-cycle parameters (used for Basel regulatory
-- capital and as a model-governance benchmark). A large, sustained
-- divergence is a signal worth investigating -- either the PIT model is
-- over/under-reacting to current conditions, or the TTC cycle window needs
-- recalibration.
-- =============================================================================

SELECT
    pit.loan_id,
    pit.reporting_date,
    pit.parameter_type,
    pit.horizon_type,

    ms.scenario_name AS pit_scenario,
    pit.parameter_value AS pit_value,
    ttc.parameter_value AS ttc_value,

    (pit.parameter_value - ttc.parameter_value) AS absolute_divergence,
    ROUND(100.0 * (pit.parameter_value - ttc.parameter_value) / ttc.parameter_value, 2) AS pct_divergence,

    CASE
        WHEN ABS(100.0 * (pit.parameter_value - ttc.parameter_value) / ttc.parameter_value) > 50 THEN 'INVESTIGATE'
        WHEN ABS(100.0 * (pit.parameter_value - ttc.parameter_value) / ttc.parameter_value) > 20 THEN 'MONITOR'
        ELSE 'WITHIN_TOLERANCE'
    END AS divergence_flag

FROM ecl.risk_parameters_pit pit
JOIN ecl.macro_scenario ms
  ON ms.scenario_id = pit.scenario_id
JOIN ecl.risk_parameters_ttc ttc
  ON ttc.loan_id = pit.loan_id
 AND ttc.reporting_date = pit.reporting_date
 AND ttc.parameter_type = pit.parameter_type
 AND ttc.horizon_type = pit.horizon_type
 AND COALESCE(ttc.period_number, -1) = COALESCE(pit.period_number, -1)
WHERE pit.reporting_date = :reporting_date
  AND ms.scenario_name = 'BASELINE'   -- compare TTC against the baseline PIT scenario, the most natural like-for-like comparison
ORDER BY ABS(pct_divergence) DESC;
