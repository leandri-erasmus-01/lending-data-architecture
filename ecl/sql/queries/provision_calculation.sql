-- =============================================================================
-- ECL: Provision Calculation
-- =============================================================================
-- Demonstrates ECL = PD x LGD x EAD, per scenario, then probability-weighted
-- across scenarios, for both Stage 1 (12-month, single-period) and
-- Stage 2/3 (lifetime, term-structure) loans. Two queries:
--   1. Stage 1 -- simple per-scenario multiplication, then weighting
--   2. Stage 2/3 -- term-structure summation with discounting, then weighting
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Stage 1: 12-month ECL, probability-weighted across macro scenarios
-- -----------------------------------------------------------------------------

WITH stage_1_loans AS (
    SELECT esh.loan_id, esh.reporting_date
    FROM ecl.exposure_stage_history esh
    WHERE esh.current_stage = 1
      AND esh.reporting_date = :reporting_date
),

per_scenario_ecl AS (
    SELECT
        l.loan_id,
        l.reporting_date,
        ms.scenario_id,
        ms.scenario_name,
        ms.scenario_weight,

        pd.parameter_value AS pd_used,
        lgd.parameter_value AS lgd_used,
        ead.parameter_value AS ead_used,

        (pd.parameter_value * lgd.parameter_value * ead.parameter_value) AS scenario_ecl

    FROM stage_1_loans l
    JOIN ecl.macro_scenario ms
      ON ms.reporting_date = l.reporting_date
    JOIN ecl.risk_parameters_pit pd
      ON pd.loan_id = l.loan_id AND pd.reporting_date = l.reporting_date
     AND pd.parameter_type = 'PD' AND pd.horizon_type = '12_MONTH'
     AND pd.scenario_id = ms.scenario_id
    JOIN ecl.risk_parameters_pit lgd
      ON lgd.loan_id = l.loan_id AND lgd.reporting_date = l.reporting_date
     AND lgd.parameter_type = 'LGD' AND lgd.scenario_id = ms.scenario_id
    JOIN ecl.risk_parameters_pit ead
      ON ead.loan_id = l.loan_id AND ead.reporting_date = l.reporting_date
     AND ead.parameter_type = 'EAD' AND ead.scenario_id = ms.scenario_id
)

SELECT
    loan_id,
    reporting_date,
    1 AS stage,
    SUM(scenario_ecl * scenario_weight) AS probability_weighted_ecl,

    -- per-scenario breakdown, preserved for audit (not just the final number)
    MAX(CASE WHEN scenario_name = 'BASELINE' THEN scenario_ecl END) AS baseline_ecl,
    MAX(CASE WHEN scenario_name = 'ADVERSE'  THEN scenario_ecl END) AS adverse_ecl,
    MAX(CASE WHEN scenario_name = 'SEVERE'   THEN scenario_ecl END) AS severe_ecl

FROM per_scenario_ecl
GROUP BY loan_id, reporting_date
ORDER BY probability_weighted_ecl DESC;


-- -----------------------------------------------------------------------------
-- 2. Stage 2/3: lifetime ECL via term-structure summation + discounting,
--    probability-weighted across macro scenarios
-- -----------------------------------------------------------------------------

WITH stage_23_loans AS (
    SELECT esh.loan_id, esh.reporting_date, esh.current_stage
    FROM ecl.exposure_stage_history esh
    WHERE esh.current_stage IN (2, 3)
      AND esh.reporting_date = :reporting_date
),

-- Stage 3 simplification: lifetime PD is effectively 100% (default has
-- already occurred), so ECL collapses to LGD x EAD directly -- no term
-- structure summation is needed. Modelled here as a single "period 0" row
-- for schema consistency with the Stage 2 term-structure case below.
stage_3_ecl AS (
    SELECT
        l.loan_id, l.reporting_date, ms.scenario_id, ms.scenario_name, ms.scenario_weight,
        (lgd.parameter_value * ead.parameter_value) AS scenario_ecl  -- PD = 1.0, omitted from the multiplication
    FROM stage_23_loans l
    JOIN ecl.macro_scenario ms ON ms.reporting_date = l.reporting_date
    JOIN ecl.risk_parameters_pit lgd
      ON lgd.loan_id = l.loan_id AND lgd.reporting_date = l.reporting_date
     AND lgd.parameter_type = 'LGD' AND lgd.scenario_id = ms.scenario_id
    JOIN ecl.risk_parameters_pit ead
      ON ead.loan_id = l.loan_id AND ead.reporting_date = l.reporting_date
     AND ead.parameter_type = 'EAD' AND ead.scenario_id = ms.scenario_id
    WHERE l.current_stage = 3
),

-- Stage 2: full lifetime term-structure summation with discounting
stage_2_period_shortfalls AS (
    SELECT
        l.loan_id, l.reporting_date, ms.scenario_id, ms.scenario_name, ms.scenario_weight,
        pd.period_number,
        pd.parameter_value AS marginal_pd,
        lgd.parameter_value AS lgd_used,
        ead.parameter_value AS ead_this_period,

        (pd.parameter_value * lgd.parameter_value * ead.parameter_value) AS undiscounted_shortfall,
        -- discount factor using the loan's effective interest rate, assumed
        -- available via mart.dim_loan_terms (not shown) keyed by loan_id
        POWER(1 + lt.effective_interest_rate, -pd.period_number) AS discount_factor

    FROM stage_23_loans l
    JOIN ecl.macro_scenario ms ON ms.reporting_date = l.reporting_date
    JOIN ecl.risk_parameters_pit pd
      ON pd.loan_id = l.loan_id AND pd.reporting_date = l.reporting_date
     AND pd.parameter_type = 'PD' AND pd.horizon_type = 'LIFETIME'
     AND pd.scenario_id = ms.scenario_id
    JOIN ecl.risk_parameters_pit lgd
      ON lgd.loan_id = l.loan_id AND lgd.reporting_date = l.reporting_date
     AND lgd.parameter_type = 'LGD' AND lgd.scenario_id = ms.scenario_id
    JOIN ecl.risk_parameters_pit ead
      ON ead.loan_id = l.loan_id AND ead.reporting_date = l.reporting_date
     AND ead.parameter_type = 'EAD' AND ead.scenario_id = ms.scenario_id
     AND ead.period_number = pd.period_number   -- EAD amortises per period for fixed-schedule products
    JOIN mart.dim_loan_terms lt ON lt.loan_id = l.loan_id
    WHERE l.current_stage = 2
),

stage_2_ecl AS (
    SELECT
        loan_id, reporting_date, scenario_id, scenario_name, scenario_weight,
        SUM(undiscounted_shortfall * discount_factor) AS scenario_ecl   -- sum across the lifetime term structure
    FROM stage_2_period_shortfalls
    GROUP BY loan_id, reporting_date, scenario_id, scenario_name, scenario_weight
),

combined_23 AS (
    SELECT loan_id, reporting_date, scenario_id, scenario_name, scenario_weight, scenario_ecl FROM stage_2_ecl
    UNION ALL
    SELECT loan_id, reporting_date, scenario_id, scenario_name, scenario_weight, scenario_ecl FROM stage_3_ecl
)

SELECT
    c.loan_id,
    c.reporting_date,
    l.current_stage AS stage,
    SUM(c.scenario_ecl * c.scenario_weight) AS probability_weighted_ecl,

    MAX(CASE WHEN c.scenario_name = 'BASELINE' THEN c.scenario_ecl END) AS baseline_ecl,
    MAX(CASE WHEN c.scenario_name = 'ADVERSE'  THEN c.scenario_ecl END) AS adverse_ecl,
    MAX(CASE WHEN c.scenario_name = 'SEVERE'   THEN c.scenario_ecl END) AS severe_ecl

FROM combined_23 c
JOIN stage_23_loans l ON l.loan_id = c.loan_id AND l.reporting_date = c.reporting_date
GROUP BY c.loan_id, c.reporting_date, l.current_stage
ORDER BY stage DESC, probability_weighted_ecl DESC;


-- -----------------------------------------------------------------------------
-- 3. Portfolio-level provision roll-up (total ECL by stage, by product)
-- -----------------------------------------------------------------------------

SELECT
    lp.product_type,
    esh.current_stage,
    COUNT(DISTINCT ec.loan_id)              AS loan_count,
    SUM(ec.ecl_present_value)                  AS total_ecl_provision,
    AVG(ec.ecl_present_value)                     AS avg_ecl_per_loan
FROM ecl.ecl_calculation ec
JOIN ecl.exposure_stage_history esh
  ON esh.stage_history_id = ec.stage_history_id
JOIN mart.fact_loan_performance lp
  ON lp.loan_id = ec.loan_id AND lp.snapshot_date = ec.reporting_date
WHERE ec.is_probability_weighted_result = TRUE
  AND ec.reporting_date = :reporting_date
GROUP BY lp.product_type, esh.current_stage
ORDER BY lp.product_type, esh.current_stage;
