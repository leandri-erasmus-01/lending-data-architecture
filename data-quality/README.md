# Data Quality Rules

Implements the two-tier data quality model from Architecture Doc §6.

## Must-pass rules (`must_pass_rules.py`)

Blocking. A failure on any rule prevents the record from reaching
`gold.decision_input` — it is tagged `BLOCKED` and excluded from the build,
remaining visible in `silver.application_inputs` for investigation rather
than being silently dropped.

| Rule | What it checks |
|---|---|
| `uuid_present` | `internal_uuid` is present and resolvable |
| `emirates_id_format` | Emirates ID matches `784-YYYY-NNNNNNN-C` |
| `no_duplicate_application_id` | No duplicate `application_id` within a batch |
| `dob_present` | DOB present on AML and internal records |
| `aecb_freshness` | AECB record not stale beyond 30 days |
| `aml_resolved` | AML `match_decision` is not `NO_MATCH` |
| `identity_validated` | AECB and Fraud responses pass deterministic cross-validation |

Each rule exposes both a pandas `check()` function (for local/notebook
validation or a Great Expectations-style suite) and a `spark_condition()`
(for direct use inside the Glue/Spark Gold build job — see
`etl/gold_transforms/build_decision_input.py`).

## Warning rules (`warning_rules.py`)

Non-blocking. Feed `gold.dq_scorecard` and drive CloudWatch → SNS/PagerDuty
alerting, but do not stop a record from proceeding.

| Rule | Metric | Warn | Page |
|---|---|---|---|
| `source_completeness` | % non-null on required fields | < 95% | < 90% |
| `duplicate_rate` | Duplicate rate across a batch | > 1% | > 5% |
| `fraud_score_drift_psi` | Population Stability Index vs. baseline | > 0.1 | > 0.2 |
| `aecb_arrival_lag_hours` | AECB response time vs. SLA | > 2h | > 4h |
| `manual_review_queue_age_hours` | Oldest item in the manual-review queue | > 4h | > 8h |

## Running locally

```bash
pip install pandas pyspark jellyfish
python data_quality/must_pass_rules.py
python data_quality/warning_rules.py
```

Both files include a runnable `__main__` block with a small worked example.
