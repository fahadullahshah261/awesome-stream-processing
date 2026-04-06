-- ============================================================
-- Financial analytics queries — run from ClickHouse local
-- Launch: ./clickhouse local
-- ============================================================

SET allow_experimental_database_iceberg = 1;

CREATE DATABASE lakekeeper_catalog
ENGINE = DataLakeCatalog('http://127.0.0.1:8181/catalog/', 'hummockadmin', 'hummockadmin')
SETTINGS
    catalog_type     = 'rest',
    storage_endpoint = 'http://127.0.0.1:9301/',
    warehouse        = 'risingwave-warehouse';

USE lakekeeper_catalog;

-- 1. Full table scan
SELECT * FROM `public.financial_transactions` ORDER BY transaction_time;

-- 2. Transaction volume by channel
SELECT
    channel,
    count()                                AS total_transactions,
    sum(transaction_amount) / 100.0        AS total_volume_usd,
    avg(transaction_amount) / 100.0        AS avg_transaction_usd
FROM `public.financial_transactions`
WHERE transaction_type != 'REVERSAL'
GROUP BY channel
ORDER BY total_volume_usd DESC;

-- 3. Regional breakdown (DEBIT only)
SELECT
    customer_region,
    count()                            AS tx_count,
    sum(transaction_amount) / 100.0    AS total_volume_usd
FROM `public.financial_transactions`
WHERE transaction_type = 'DEBIT'
GROUP BY customer_region
ORDER BY total_volume_usd DESC;

-- 4. KYC tier compliance view
SELECT
    kyc_level,
    count()                                AS tx_count,
    sum(transaction_amount) / 100.0        AS total_volume_usd,
    max(transaction_amount) / 100.0        AS max_single_tx_usd
FROM `public.financial_transactions`
GROUP BY kyc_level
ORDER BY kyc_level;

-- 5. POS terminal activity (geospatial)
SELECT
    terminal_serial_no,
    customer_region,
    terminal_lat,
    terminal_long,
    count()                         AS pos_transactions,
    sum(transaction_amount) / 100.0 AS total_pos_volume_usd
FROM `public.financial_transactions`
WHERE channel = 'POS'
  AND terminal_serial_no IS NOT NULL
GROUP BY terminal_serial_no, customer_region, terminal_lat, terminal_long;

-- 6. Balance reconciliation check (returns rows only if discrepancies exist)
SELECT
    transaction_reference,
    source_account_number,
    balance_before / 100.0         AS balance_before_usd,
    transaction_amount / 100.0     AS amount_usd,
    balance_after / 100.0          AS balance_after_usd,
    (balance_before - transaction_amount - balance_after) AS discrepancy
FROM `public.financial_transactions`
WHERE transaction_type = 'DEBIT'
  AND is_outflow = true
  AND (balance_before - transaction_amount - balance_after) != 0;

-- 7. Reversal rate by category
WITH all_tx AS (
    SELECT transaction_category, count() AS total
    FROM `public.financial_transactions`
    GROUP BY transaction_category
),
reversals AS (
    SELECT transaction_category, count() AS rev_count
    FROM `public.financial_transactions`
    WHERE transaction_type = 'REVERSAL'
    GROUP BY transaction_category
)
SELECT
    a.transaction_category,
    a.total,
    coalesce(r.rev_count, 0)                                     AS reversals,
    round(coalesce(r.rev_count, 0) * 100.0 / a.total, 2)        AS reversal_rate_pct
FROM all_tx a
LEFT JOIN reversals r USING (transaction_category)
ORDER BY reversal_rate_pct DESC;
