"""
data_quality/warning_rules.py

Warning-tier (non-blocking) data quality rules, per Architecture Doc §6.2.
These do NOT block a record from flowing into gold.decision_input — they feed
the dq_scorecard table and drive CloudWatch -> SNS/PagerDuty alerting.

Unlike must_pass_rules.py (row-level pass/fail), most of these are
batch-level/aggregate metrics, since they describe properties of a whole
batch (completeness %, duplicate rate, drift) rather than individual records.
"""

import math
from dataclasses import dataclass
from datetime import datetime, timezone

import pandas as pd


@dataclass
class WarningRuleResult:
    rule_name: str
    metric_value: float
    warn_threshold: float
    page_threshold: float
    severity: str  # OK | WARN | PAGE
    evaluated_at: str


def _classify(value: float, warn_threshold: float, page_threshold: float, higher_is_worse: bool) -> str:
    if higher_is_worse:
        if value >= page_threshold:
            return "PAGE"
        if value >= warn_threshold:
            return "WARN"
        return "OK"
    else:
        if value <= page_threshold:
            return "PAGE"
        if value <= warn_threshold:
            return "WARN"
        return "OK"


# -----------------------------------------------------------------------------
# Rule 1 — source completeness
# -----------------------------------------------------------------------------

def check_source_completeness(df: pd.DataFrame, required_columns: list) -> WarningRuleResult:
    """Warn < 95%, page < 90% non-null across the given required columns."""
    completeness = df[required_columns].notna().mean().mean()
    severity = _classify(completeness, warn_threshold=0.95, page_threshold=0.90, higher_is_worse=False)
    return WarningRuleResult(
        rule_name="source_completeness",
        metric_value=round(completeness, 4),
        warn_threshold=0.95,
        page_threshold=0.90,
        severity=severity,
        evaluated_at=datetime.now(timezone.utc).isoformat(),
    )


# -----------------------------------------------------------------------------
# Rule 2 — duplicate rate
# -----------------------------------------------------------------------------

def check_duplicate_rate(df: pd.DataFrame, key_column: str = "application_id") -> WarningRuleResult:
    """Warn if duplicate rate exceeds 1%."""
    dup_rate = df[key_column].duplicated(keep=False).mean()
    severity = _classify(dup_rate, warn_threshold=0.01, page_threshold=0.05, higher_is_worse=True)
    return WarningRuleResult(
        rule_name="duplicate_rate",
        metric_value=round(dup_rate, 4),
        warn_threshold=0.01,
        page_threshold=0.05,
        severity=severity,
        evaluated_at=datetime.now(timezone.utc).isoformat(),
    )


# -----------------------------------------------------------------------------
# Rule 3 — fraud-score distribution drift (Population Stability Index)
# -----------------------------------------------------------------------------

def _safe_log(x: float) -> float:
    return math.log(x) if x > 0 else 0.0


def _psi_for_bucket(expected_pct: float, actual_pct: float) -> float:
    # Avoid log(0) / division issues on empty buckets.
    expected_pct = max(expected_pct, 1e-6)
    actual_pct = max(actual_pct, 1e-6)
    return (actual_pct - expected_pct) * _safe_log(actual_pct / expected_pct)


def check_fraud_score_drift(baseline_scores: pd.Series, current_scores: pd.Series, n_buckets: int = 10) -> WarningRuleResult:
    """
    Population Stability Index between a baseline fraud-score distribution
    (e.g. last quarter) and the current batch. PSI > 0.2 is the conventional
    threshold for "investigate" — see Architecture Doc §6.2.
    """
    bins = pd.qcut(baseline_scores, q=n_buckets, duplicates="drop", retbins=True)[1]
    bins[0], bins[-1] = -float("inf"), float("inf")

    expected_pct = pd.cut(baseline_scores, bins=bins).value_counts(normalize=True).sort_index()
    actual_pct = pd.cut(current_scores, bins=bins).value_counts(normalize=True).sort_index()
    actual_pct = actual_pct.reindex(expected_pct.index, fill_value=0.0)

    psi = sum(_psi_for_bucket(e, a) for e, a in zip(expected_pct.values, actual_pct.values))

    severity = _classify(psi, warn_threshold=0.1, page_threshold=0.2, higher_is_worse=True)
    return WarningRuleResult(
        rule_name="fraud_score_drift_psi",
        metric_value=round(psi, 4),
        warn_threshold=0.1,
        page_threshold=0.2,
        severity=severity,
        evaluated_at=datetime.now(timezone.utc).isoformat(),
    )


# -----------------------------------------------------------------------------
# Rule 4 — AECB batch on-time arrival
# -----------------------------------------------------------------------------

def check_aecb_arrival_lag(submitted_at: datetime, received_at: datetime, sla_hours: float = 2.0) -> WarningRuleResult:
    """Page if the AECB response arrives more than `sla_hours` after request submission."""
    lag_hours = (received_at - submitted_at).total_seconds() / 3600
    severity = _classify(lag_hours, warn_threshold=sla_hours, page_threshold=sla_hours * 2, higher_is_worse=True)
    return WarningRuleResult(
        rule_name="aecb_arrival_lag_hours",
        metric_value=round(lag_hours, 2),
        warn_threshold=sla_hours,
        page_threshold=sla_hours * 2,
        severity=severity,
        evaluated_at=datetime.now(timezone.utc).isoformat(),
    )


# -----------------------------------------------------------------------------
# Rule 5 — AML manual-review queue depth/age
# -----------------------------------------------------------------------------

def check_manual_review_queue_age(queue_df: pd.DataFrame, age_column: str = "queued_at", sla_hours: float = 4.0) -> WarningRuleResult:
    """Warn if the oldest item in the manual-review queue has aged beyond the SLA."""
    if queue_df.empty:
        oldest_age_hours = 0.0
    else:
        now = pd.Timestamp.now(tz="UTC")
        oldest_age_hours = (now - pd.to_datetime(queue_df[age_column], utc=True)).max().total_seconds() / 3600

    severity = _classify(oldest_age_hours, warn_threshold=sla_hours, page_threshold=sla_hours * 2, higher_is_worse=True)
    return WarningRuleResult(
        rule_name="manual_review_queue_age_hours",
        metric_value=round(oldest_age_hours, 2),
        warn_threshold=sla_hours,
        page_threshold=sla_hours * 2,
        severity=severity,
        evaluated_at=datetime.now(timezone.utc).isoformat(),
    )


if __name__ == "__main__":
    sample = pd.DataFrame({
        "application_id": ["A1", "A2", "A3", "A4"],
        "aecb_score": [700, None, 650, 710],
        "fraud_score": [10, 20, 15, None],
    })
    print(check_source_completeness(sample, ["aecb_score", "fraud_score"]))
    print(check_duplicate_rate(pd.DataFrame({"application_id": ["A1", "A1", "A2", "A3"]})))
