"""
etl/gold_transforms/build_decision_input.py

Illustrative PySpark job that assembles gold.decision_input from
silver.application_inputs, applying the must-pass data quality gates from
data_quality/must_pass_rules.py BEFORE a record becomes eligible for the
online decision path.

Run on the same 24-hour Gold batch cadence as the rest of the pipeline
(see Architecture Doc §3.3). The corresponding SQL DDL and an equivalent
SQL-only build statement live in sql/gold/gold_decision_input.sql — this
module shows the same logic expressed as a Spark job, which is what would
actually run under AWS Glue.
"""

from datetime import date

from pyspark.sql import SparkSession, DataFrame
from pyspark.sql import functions as F

from data_quality.must_pass_rules import MUST_PASS_RULES


def get_spark() -> SparkSession:
    return (
        SparkSession.builder
        .appName("gold_decision_input_build")
        .config("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog")
        .getOrCreate()
    )


def load_todays_silver_inputs(spark: SparkSession, batch_date: date) -> DataFrame:
    return (
        spark.table("silver.application_inputs")
        .filter(F.col("batch_date") == batch_date)
    )


def apply_must_pass_gates(df: DataFrame) -> DataFrame:
    """
    Applies every rule registered in MUST_PASS_RULES. Each rule contributes a
    boolean pass/fail column; a record must pass ALL of them to be flagged
    dq_status = 'PASS' and become eligible for decision_input. Records that
    fail any rule are tagged 'BLOCKED' and excluded from the final write,
    rather than silently dropped — they remain visible in
    silver.application_inputs for investigation.
    """
    result = df
    rule_columns = []

    for rule in MUST_PASS_RULES:
        col_name = f"_passes_{rule.name}"
        result = result.withColumn(col_name, rule.spark_condition())
        rule_columns.append(col_name)

    result = result.withColumn(
        "dq_status",
        F.when(
            F.array_min(F.array(*[F.col(c) for c in rule_columns])) == 1,
            F.lit("PASS"),
        ).otherwise(F.lit("BLOCKED")),
    )

    return result.drop(*rule_columns)


def build_decision_input(spark: SparkSession, batch_date: date) -> DataFrame:
    silver_df = load_todays_silver_inputs(spark, batch_date)
    gated_df = apply_must_pass_gates(silver_df)

    decision_input_df = (
        gated_df
        .filter(F.col("dq_status") == "PASS")
        .filter(F.size(F.col("pending_sources")) == 0)  # all three sources have responded
        .select(
            "application_id",
            "internal_uuid",
            "application_date",
            "aecb_score",
            "aecb_band",
            "total_outstanding",
            "fraud_score",
            "risk_band",
            "aml_status",
            "pep_flag",
            "match_score",
            "dq_status",
            "pending_sources",
        )
        .withColumn("assembled_at", F.current_timestamp())
        .withColumn("batch_date", F.lit(batch_date))
    )

    return decision_input_df


def sync_to_feature_store(decision_input_df: DataFrame) -> None:
    """
    Pushes the assembled rows into the low-latency feature store (DynamoDB)
    that the online decision service actually reads from. NOTE: in practice
    this batch sync is a secondary/reconciliation path — the feature store is
    primarily populated in near-real-time as each vendor response arrives
    (see etl/ingestion/*), since the decision cannot wait for a 24-hour Gold
    batch. This sync exists so the feature store and the governed Gold record
    stay consistent.
    """
    (
        decision_input_df.write
        .format("dynamodb")
        .option("tableName", "decision_input_feature_store")
        .mode("append")
        .save()
    )


def main():
    spark = get_spark()
    batch_date = date.today()

    decision_input_df = build_decision_input(spark, batch_date)

    (
        decision_input_df.writeTo("gold.decision_input")
        .partitionedBy("batch_date")
        .append()
    )

    sync_to_feature_store(decision_input_df)

    blocked_count = (
        load_todays_silver_inputs(spark, batch_date)
        .transform(apply_must_pass_gates)
        .filter(F.col("dq_status") == "BLOCKED")
        .count()
    )
    print(f"Gold decision_input build complete for {batch_date}. "
          f"Blocked records this run: {blocked_count}")


if __name__ == "__main__":
    main()
