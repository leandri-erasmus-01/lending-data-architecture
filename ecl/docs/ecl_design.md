# IFRS 9 ECL Data Model — Design Doc

## Purpose

Extends the existing lending data architecture (`mart.fact_loan_performance`, `mart.fact_credit_decision`) with the structures needed to calculate and audit IFRS 9 Expected Credit Loss (ECL) provisions: stage classification, versioned risk parameters (PD/LGD/EAD), point-in-time vs. through-the-cycle parameter tracking, and a full audit trail for stage transitions and provision calculations.

## Staging design

`exposure_stage_history` follows the same append-only philosophy as the rest of this architecture (see `sql/bronze/`): every reporting period writes a new row per loan, including `NO_CHANGE` periods, so the full population's stage history has no gaps. A loan's current stage is simply its most recent row — there is no separate "current state" table to keep in sync.

Stage assignment combines **regulatory backstops** (30+ DPD → Stage 2, 90+ DPD → Stage 3 — both rebuttable, with `sicr_backstop_rebutted` and `rebuttal_reason` capturing any override) with **policy-defined triggers** (rating downgrade ≥2 notches, watchlist, forbearance, and a PD-deterioration ratio comparing current vs. origination PD). These thresholds are credit-policy choices, not IFRS 9-prescribed numbers — `credit_policy_version` makes the specific thresholds applied at any point in time traceable. `classification_method` and `override_approved_by` distinguish automated classifications from analyst overrides, since IFRS 9 explicitly allows judgment on top of model output.

## PD / LGD / EAD design

PD is stored as a **term structure** (`period_number` per future period), not a scalar — Stage 2/3 lifetime ECL requires summing marginal PD × LGD × EAD per period and discounting, which a single PD value cannot represent. Stage 1 uses `horizon_type = '12_MONTH'` with no term structure.

**PIT and TTC are separate tables** (`risk_parameters_pit`, `risk_parameters_ttc`) rather than a single table with a type flag, because they differ structurally: PIT is scenario-conditional (joins to `macro_scenario`); TTC is a cycle-average with no scenario dependency. The ECL actually booked always derives from PIT; TTC exists for Basel capital purposes and as a model-governance benchmark via `pit_vs_ttc_reconciliation.sql`.

Every parameter row carries `model_id` and `model_version`, since models are redeveloped periodically and a historical ECL figure must be reproducible using the model that was actually live at the time — not the current model.

## ECL calculation design

`ecl_calculation` stores one row **per scenario** plus one final row where `scenario_id IS NULL` (`is_probability_weighted_result = TRUE`) — the per-scenario breakdown is preserved, not discarded, so the probability-weighted figure is explainable, not a black box. `ecl_lifetime_period_detail` holds the per-period term-structure breakdown for Stage 2/3 loans, since `gross_ecl_undiscounted` for a lifetime calculation is a sum, not a single multiplication.

`management_overlay_amount` is a first-class, separately-visible field, never silently blended into the model output — IFRS 9 permits management judgment on top of model results, but it must be auditable as a distinct adjustment with `overlay_justification` and `overlay_approved_by`.

## Key assumptions

- **SICR thresholds adopted** (30/90 DPD backstops, 2-notch downgrade, PD-doubling) are common industry defaults, not values IFRS 9 itself prescribes — a real implementation requires credit-policy sign-off on these specific thresholds.
- **Mal's three products are treated as predominantly unsecured** — LGD is modelled at the product/segment level (`model_segment`) rather than via per-loan collateral valuation, since personal finance, BNPL, and the credit-card alternative are not asset-backed.
- **EAD for the credit-card alternative (revolving exposure)** must project further drawdown on undrawn limits, not just the current balance — this is a modelling input baked into `parameter_value`, not a separate schema construct.
- **A 3-scenario set (baseline/adverse/severe)** is the illustrative minimum to demonstrate the methodology; a production economics function would maintain a richer scenario suite.
- **PD/LGD/EAD model development is out of scope.** This schema stores and versions model *outputs*; building the statistical models themselves is a model-risk/quant function, not a data-engineering one.
- **As a new lender, Mal will lack sufficient internal default history for a robust PD/TTC curve at launch** — industry practice is to anchor early estimates to bureau-level/industry benchmarks and recalibrate as internal data accumulates, consistent with the vintage-analysis sequencing already noted as post-launch in the wider architecture.
