-- =============================================================================
-- MART: Dimension Tables
-- =============================================================================
-- Shared conformed dimensions used by both gold.fact_credit_decision and
-- mart.fact_loan_performance, allowing both fact tables to be sliced
-- consistently by product, time period and customer segment.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- dim_customer
-- -----------------------------------------------------------------------------
CREATE TABLE mart.dim_customer (
    internal_uuid          STRING,
    customer_segment       STRING      COMMENT 'e.g. salaried / self-employed / new-to-credit',
    emirate                STRING      COMMENT 'Emirate of residence, where known',
    onboarded_date         DATE,
    is_active              BOOLEAN
)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/mart/dim_customer/';

-- -----------------------------------------------------------------------------
-- dim_product
-- -----------------------------------------------------------------------------
CREATE TABLE mart.dim_product (
    product_id          STRING,
    application_id      STRING      COMMENT 'Used to join product context onto fact_credit_decision at build time',
    product_type        STRING      COMMENT 'personal_finance | bnpl | credit_card_alternative',
    product_name        STRING,
    launch_date         DATE
)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/mart/dim_product/';

-- -----------------------------------------------------------------------------
-- dim_date
-- -----------------------------------------------------------------------------
CREATE TABLE mart.dim_date (
    date_key           DATE,
    day_of_week        STRING,
    month_name         STRING,
    month_number       INT,
    quarter            STRING,
    year               INT,
    is_month_end       BOOLEAN
)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/mart/dim_date/';

-- -----------------------------------------------------------------------------
-- dim_source
-- -----------------------------------------------------------------------------
CREATE TABLE mart.dim_source (
    source_system       STRING      COMMENT 'aecb | fraud | aml | internal',
    source_name         STRING,
    match_pattern       STRING      COMMENT 'DETERMINISTIC | PROBABILISTIC',
    delivery_pattern    STRING      COMMENT 'ASYNC_FILE | SYNC_API | ASYNC_WEBHOOK | CDC'
)
STORED AS PARQUET
LOCATION 's3://mal-lakehouse/mart/dim_source/';

INSERT INTO mart.dim_source VALUES
    ('aecb',     'UAE Credit Bureau',      'DETERMINISTIC',  'ASYNC_FILE'),
    ('fraud',    'Fraud Detection Provider','DETERMINISTIC', 'SYNC_API'),
    ('aml',      'AML / PEP Screening',     'PROBABILISTIC', 'ASYNC_WEBHOOK'),
    ('internal', 'Internal Customer Profile','DETERMINISTIC','CDC');
