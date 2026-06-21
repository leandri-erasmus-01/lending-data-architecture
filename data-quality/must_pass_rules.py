"""
data_quality/must_pass_rules.py

Must-pass / blocking data quality rules.

A failure on any of these rules should prevent a record from reaching Gold.
"""

import re
from dataclasses import dataclass
from typing import Callable, List

import pandas as pd
from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql.column import Column
from pyspark.sql.window import Window


EMIRATES_ID_PATTERN = re.compile(r"^784-\d{4}-\d{7}-\d$")
AECB_FRESHNESS_THRESHOLD_DAYS = 30


@dataclass
class MustPassRule:
    name: str
    description: str
    check: Callable[[pd.DataFrame], pd.Series]
    spark_condition: Callable[[], Column]


# -----------------------------------------------------------------------------
# Pandas checks
# -----------------------------------------------------------------------------

def _check_uuid_present(df: pd.DataFrame) -> pd.Series:
    return df["internal_uuid"].notna() & (df["internal_uuid"].astype(str).str.len() > 0)


def _check_emirates_id_format(df: pd.DataFrame) -> pd.Series:
    return df["emirates_id"].apply(
        lambda v: bool(EMIRATES_ID_PATTERN.match(str(v))) if pd.notna(v) else False
    )


def _check_no_duplicate_application_id(df: pd.DataFrame) -> pd.Series:
    return ~df["application_id"].duplicated(keep=False)


def _check_dob_present(df: pd.DataFrame) -> pd.Series:
    return df["dob"].notna()


def _check_aecb_freshness(df: pd.DataFrame) -> pd.Series:
    age_days = (
        pd.Timestamp.now().normalize()
        - pd.to_datetime(df["aecb_report_date"], errors="coerce")
    ).dt.days

    return age_days <= AECB_FRESHNESS_THRESHOLD_DAYS


def _check_aml_resolved(df: pd.DataFrame) -> pd.Series:
    return df["aml_match_decision"] != "NO_MATCH"


def _check_identity_validated(df: pd.DataFrame) -> pd.Series:
    return (
        (df["aecb_identity_status"] == "MATCH")
        & (df["fraud_identity_status"] == "MATCH")
    )


# -----------------------------------------------------------------------------
# Spark row-level checks
# -----------------------------------------------------------------------------

def _spark_uuid_present() -> Column:
    return F.col("internal_uuid").isNotNull() & (F.length(F.col("internal_uuid")) > 0)


def _spark_emirates_id_format() -> Column:
    return F.col("emirates_id").rlike(r"^784-\d{4}-\d{7}-\d$")


def _spark_no_duplicate_application_id() -> Column:
    """
    This expects duplicate_count_application_id to already exist on the DataFrame.

    Duplicate checks are aggregate/window-based, so we create the count column
    in add_duplicate_count_columns().
    """
    return F.col("duplicate_count_application_id") == 1


def _spark_dob_present() -> Column:
    return F.col("dob").isNotNull()


def _spark_aecb_freshness() -> Column:
    return (
        F.col("aecb_report_date").isNotNull()
        & (F.datediff(F.current_date(), F.col("aecb_report_date")) <= AECB_FRESHNESS_THRESHOLD_DAYS)
    )


def _spark_aml_resolved() -> Column:
    return F.col("aml_match_decision") != F.lit("NO_MATCH")


def _spark_identity_validated() -> Column:
    return (
        (F.col("aecb_identity_status") == F.lit("MATCH"))
        & (F.col("fraud_identity_status") == F.lit("MATCH"))
    )


# -----------------------------------------------------------------------------
# Rule definitions
# -----------------------------------------------------------------------------

rule_uuid_present = MustPassRule(
    name="uuid_present",
    description="internal_uuid is present and resolvable.",
    check=_check_uuid_present,
    spark_condition=_spark_uuid_present,
)

rule_emirates_id_format = MustPassRule(
    name="emirates_id_format",
    description="Emirates ID is present and format-valid.",
    check=_check_emirates_id_format,
    spark_condition=_spark_emirates_id_format,
)

rule_no_duplicate_application_id = MustPassRule(
    name="no_duplicate_application_id",
    description="No duplicate application_id within the dataset/batch.",
    check=_check_no_duplicate_application_id,
    spark_condition=_spark_no_duplicate_application_id,
)

rule_dob_present = MustPassRule(
    name="dob_present",
    description="DOB is present.",
    check=_check_dob_present,
    spark_condition=_spark_dob_present,
)

rule_aecb_freshness = MustPassRule(
    name="aecb_freshness",
    description=f"AECB report is not older than {AECB_FRESHNESS_THRESHOLD_DAYS} days.",
    check=_check_aecb_freshness,
    spark_condition=_spark_aecb_freshness,
)

rule_aml_resolved = MustPassRule(
    name="aml_resolved",
    description="AML match decision is not NO_MATCH.",
    check=_check_aml_resolved,
    spark_condition=_spark_aml_resolved,
)

rule_identity_validated = MustPassRule(
    name="identity_validated",
    description="AECB and Fraud identities match the internal customer profile.",
    check=_check_identity_validated,
    spark_condition=_spark_identity_validated,
)


MUST_PASS_RULES: List[MustPassRule] = [
    rule_uuid_present,
    rule_emirates_id_format,
    rule_no_duplicate_application_id,
    rule_dob_present,
    rule_aecb_freshness,
    rule_aml_resolved,
    rule_identity_validated,
]


# -----------------------------------------------------------------------------
# Pandas evaluator
# -----------------------------------------------------------------------------

def evaluate_all(df: pd.DataFrame) -> pd.DataFrame:
    """
    Runs all must-pass rules against a pandas DataFrame.

    Returns the original DataFrame plus:
    - passes_<rule_name> columns
    - dq_status = PASS or BLOCKED
    """

    results = df.copy()
    pass_columns = []

    for rule in MUST_PASS_RULES:
        col_name = f"passes_{rule.name}"
        results[col_name] = rule.check(df)
        pass_columns.append(col_name)

    results["dq_status"] = results[pass_columns].all(axis=1).map(
        {True: "PASS", False: "BLOCKED"}
    )

    return results


# -----------------------------------------------------------------------------
# Spark evaluator
# -----------------------------------------------------------------------------

def add_duplicate_count_columns(df: DataFrame) -> DataFrame:
    """
    Adds duplicate-count columns required for aggregate DQ rules.

    For this assessment, duplicate application_id is checked within the incoming
    dataset/batch being processed.
    """

    application_window = Window.partitionBy("application_id")

    return df.withColumn(
        "duplicate_count_application_id",
        F.count("*").over(application_window)
    )


def evaluate_all_spark(df: DataFrame) -> DataFrame:
    """
    Runs all must-pass rules against a Spark DataFrame.

    Returns the original DataFrame plus:
    - duplicate_count_application_id
    - passes_<rule_name> columns
    - dq_status = PASS or BLOCKED
    """

    results = add_duplicate_count_columns(df)
    pass_columns = []

    for rule in MUST_PASS_RULES:
        col_name = f"passes_{rule.name}"
        results = results.withColumn(col_name, rule.spark_condition())
        pass_columns.append(col_name)

    overall_pass_condition = None

    for col_name in pass_columns:
        condition = F.col(col_name)

        if overall_pass_condition is None:
            overall_pass_condition = condition
        else:
            overall_pass_condition = overall_pass_condition & condition

    results = results.withColumn(
        "dq_status",
        F.when(overall_pass_condition, F.lit("PASS")).otherwise(F.lit("BLOCKED"))
    )

    return results


def get_blocked_records(df: DataFrame) -> DataFrame:
    """
    Returns only records that fail at least one must-pass rule.
    """

    evaluated_df = evaluate_all_spark(df)

    return evaluated_df.filter(F.col("dq_status") == "BLOCKED")


def get_passed_records(df: DataFrame) -> DataFrame:
    """
    Returns only records that pass all must-pass rules.
    """

    evaluated_df = evaluate_all_spark(df)

    return evaluated_df.filter(F.col("dq_status") == "PASS")
