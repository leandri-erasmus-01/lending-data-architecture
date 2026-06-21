# ECL — IFRS 9 Credit Loss Provisioning

Extends `lending-data-architecture` with the data model required to calculate and audit IFRS 9 Expected Credit Loss (ECL) provisions for Mal's credit portfolio. Builds on `mart.fact_loan_performance` and `mart.fact_credit_decision` rather than duplicating them.

## Structure

```
ecl/
├── sql/
│   ├── schema/
│   │   ├── ecl_exposure_stage_history.sql   <- Stage 1/2/3 classification + transition audit trail
│   │   ├── ecl_risk_parameters_pit.sql      <- point-in-time PD/LGD/EAD, scenario-conditional
│   │   ├── ecl_risk_parameters_ttc.sql      <- through-the-cycle PD/LGD/EAD, for Basel + benchmarking
│   │   ├── ecl_macro_scenario.sql           <- forward-looking scenario set and weights
│   │   └── ecl_ecl_calculation.sql          <- the ECL figure itself + lifetime term-structure detail
│   └── queries/
│       ├── stage_classification_logic.sql   <- automated Stage 1/2/3 recommendation
│       ├── provision_calculation.sql        <- PD x LGD x EAD, scenario-weighted, Stage 1 and Stage 2/3
│       └── pit_vs_ttc_reconciliation.sql    <- model-governance benchmark query
└── docs/
    └── ECL_DESIGN.md                        <- 1-page design rationale
```

## Requirements mapping

| Requirement | Where it lives |
|---|---|
| Stage 1/2/3 classification | `sql/schema/ecl_exposure_stage_history.sql`, `sql/queries/stage_classification_logic.sql` |
| PD / LGD / EAD calculations | `sql/schema/ecl_risk_parameters_pit.sql`, `sql/schema/ecl_ecl_calculation.sql`, `sql/queries/provision_calculation.sql` |
| PIT vs. TTC parameter versioning | `sql/schema/ecl_risk_parameters_pit.sql` + `ecl_risk_parameters_ttc.sql`, `sql/queries/pit_vs_ttc_reconciliation.sql` |
| Audit trail for transitions and calculations | `sql/schema/ecl_exposure_stage_history.sql` (transitions), `sql/schema/ecl_ecl_calculation.sql` (calculations — per-scenario detail preserved, never just the final number) |

See `docs/ECL_DESIGN.md` for the full design rationale and stated assumptions.
