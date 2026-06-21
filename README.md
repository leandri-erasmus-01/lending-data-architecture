# Unified Credit Decision-Input Data Pipeline

Data engineering case study: a medallion-architecture pipeline that ingests
four structurally incompatible sources (AECB credit bureau, fraud detection,
AML/PEP screening, internal customer profile), resolves them onto a single
customer identity, and produces a governed, auditable decision-input record
for three Q2 2025 credit products (personal finance, BNPL, credit-card
alternative).

This repo contains the working SQL schemas, Python ETL samples, and data
quality rules.

## How this maps to the assignment requirements

| Requirement | Where it lives |
|---|---|
| Medallion architecture (bronze/silver/gold) | `sql/bronze/`, `sql/silver/`, `sql/gold/` |
| Conflict resolution for customer key matching | `sql/silver/silver_match_audit.sql`, `etl/silver_transforms/entity_resolution.py` |
| Decision traceability | `sql/gold/gold_lending_application_request.sql`, `sql/gold/gold_lending_application_response.sql`, `docs/DECISIONS.md` (§4) |
| Data quality scorecard, must-pass rules, alert thresholds | `data_quality/`, `sql/gold/gold_dq_scorecard.sql` |
| Portfolio monitoring mart for risk dashboards | `sql/mart/` |

## Repo structure

```
credit-decision-pipeline/
├── README.md                       <- you are here
├── sql/
│   ├── bronze/                     <- raw, immutable landing tables (one per source)
│   ├── silver/                     <- conformed + cross-validated tables, match audit
│   ├── gold/                       <- decision_input, decision_outcomes, fact_credit_decision, dq_scorecard
│   └── mart/                       <- fact_loan_performance, dimensions, example analytical queries
├── etl/
│   ├── ingestion/                  <- one sample per ingestion PATTERN, not per source
│   │   ├── aecb_sftp_loader.py         (async, file-based)
│   │   ├── aml_webhook_handler.py      (async, webhook, idempotent)
│   │   └── fraud_sync_client.py        (synchronous, real-time, decoupled persist)
│   ├── silver_transforms/
│   │   └── entity_resolution.py    <- deterministic + probabilistic matching logic
│   └── gold_transforms/
│       └── build_decision_input.py <- applies must-pass DQ gates, assembles decision_input
├── data_quality/
│   ├── must_pass_rules.py          <- blocking rules (row-level)
│   ├── warning_rules.py            <- non-blocking rules (batch-level, feeds alerting)
│   └── README.md
```

## Why ingestion samples are organised by pattern, not by source

There are four sources but only three genuinely distinct ingestion
*mechanisms*, and the mechanism is what drives the
engineering decisions:

| Pattern | Source | Why |
|---|---|---|
| Async, file-based | AECB | Request triggered per application; AECB drops a response file on SFTP minutes-to-hours later |
| Synchronous, real-time | Fraud | Sub-second REST call made inline as part of the live decision |
| Async, webhook | AML | Screening requested at application time; provider calls back independently — requires us to pass our own correlation ID so it can be echoed back |

The internal profile (continuous CDC) is a fourth, simpler pattern not
included as a standalone sample since it's a standard DMS configuration
rather than custom application code.

## Identity & matching model

`internal_uuid` is the single canonical key throughout the pipeline. Every
external response is validated against the internal profile using
source-specific identifiers — never blindly merged on the assumption that a
response belongs to whoever was asked about:

- **AECB / Fraud** — deterministic equality checks (exact key lookups; Emirates
  ID, phone, email)
- **AML** — probabilistic similarity scoring (name similarity +
  exact DOB), because AML screening matches against external government
  watchlists with transliterated name variants, not our own data

Conflicts (mismatched Emirates ID, a phone/email resolving to a different
UUID, or a weak name/DOB match) are routed to `silver.match_audit` and
exception queues rather than silently merged. See
`etl/silver_transforms/entity_resolution.py` and Architecture Doc §4.

## Running the samples locally

These are illustrative samples demonstrating the design, not a runnable
production deployment (no real AWS resources, vendor APIs, or PySpark
cluster are wired up). They are written to be read, and the pure-Python
logic (entity resolution, DQ rules) runs standalone for verification.


The ingestion modules (`etl/ingestion/*`) and the Gold build job
(`etl/gold_transforms/build_decision_input.py`) reference AWS services
(S3, SQS, DynamoDB, Glue/Spark) and are intended to be read as
infrastructure-as-code-adjacent samples, not executed directly without that
infrastructure in place.

