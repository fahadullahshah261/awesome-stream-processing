# Streaming Financial Transactions to Apache Iceberg with RisingWave, Lakekeeper, and ClickHouse

Modern financial platforms process millions of transactions every day — payments, transfers, balance updates, and more — all in real time. The data engineering challenge is twofold: you need **low-latency stream processing** to react to events as they happen, and **open, durable storage** so that data analysts, ML teams, and compliance tools can all query the same data without copies or pipelines between them.

This blog walks through a practical solution using four open tools:

- **RisingWave** — a streaming SQL database that ingests, transforms, and sinks data in real time
- **Lakekeeper** — a production-grade Apache Iceberg REST catalog (backed by PostgreSQL)
- **Apache Iceberg** — the open table format stored on MinIO (S3-compatible object storage)
- **ClickHouse** — a high-performance columnar analytics database that queries the same Iceberg tables directly

By the end, you will have a working stack where RisingWave streams financial transaction data into Iceberg tables registered in Lakekeeper — and ClickHouse queries that same data without moving or duplicating it.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Data Flow                                       │
│                                                                         │
│   INSERT / CDC           Iceberg Sink           REST Catalog            │
│  ─────────────►  RisingWave  ──────────►  Lakekeeper  ──────────►  MinIO│
│                                                                    (S3) │
│                                               │                         │
│                                               ▼                         │
│                                          ClickHouse                     │
│                                       (analytics queries)               │
└─────────────────────────────────────────────────────────────────────────┘
```

**Components:**

| Service | Role | Default Port |
|---|---|---|
| RisingWave | Stream processing + Iceberg sink | `4566` |
| Lakekeeper | Iceberg REST catalog | `8181` |
| MinIO | S3-compatible object storage (Iceberg data files) | `9301` |
| PostgreSQL (metadata) | RisingWave metadata store | `8432` |
| PostgreSQL (lakekeeper) | Lakekeeper catalog state | `8433` |
| ClickHouse | Ad-hoc analytics on Iceberg tables | CLI |

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose (included in Docker Desktop)
- [`psql`](https://www.postgresql.org/download/) — to connect to RisingWave

---

## Step 1 — Clone the repo and start the stack

```bash
git clone https://github.com/fahadullahshah261/awesome-stream-processing.git
cd awesome-stream-processing/07-iceberg-demos/risingwave_lakekeeper_iceberg_clickhouse_fintxn

docker compose up -d
```

The Compose file starts all services and runs a `lakekeeper-bootstrap` container that:
1. Bootstraps the Lakekeeper server
2. Creates a warehouse named `risingwave-warehouse` backed by MinIO

Wait ~30 seconds for all services to be healthy, then verify:

```bash
# RisingWave frontend
curl -s http://localhost:4566 || echo "RisingWave ready"

# Lakekeeper health
curl -s http://localhost:8181/health
```

---

## Step 2 — Connect to RisingWave

```bash
psql -h localhost -p 4566 -d dev -U root
```

---

## Step 3 — Create the Lakekeeper catalog connection

RisingWave communicates with Lakekeeper using the standard Apache Iceberg REST catalog protocol. Create a named connection:

```sql
CREATE CONNECTION lakekeeper_catalog_conn
WITH (
    type                  = 'iceberg',
    catalog.type          = 'rest',
    catalog.uri           = 'http://lakekeeper:8181/catalog/',
    warehouse.path        = 'risingwave-warehouse',
    s3.access.key         = 'hummockadmin',
    s3.secret.key         = 'hummockadmin',
    s3.path.style.access  = 'true',
    s3.endpoint           = 'http://minio-0:9301',
    s3.region             = 'us-east-1'
);
```

Set it as the default Iceberg connection for this session:

```sql
SET iceberg_engine_connection = 'public.lakekeeper_catalog_conn';
```

---

## Step 4 — Create the financial transactions table

This table models a real-time transaction stream from a digital payments platform. Every row represents a single payment event — capturing the source and destination accounts, amounts, KYC tier, channel, and terminal location for POS/ATM transactions.

The schema is structured to support the most common financial analytics patterns: channel performance, regional volume, KYC compliance reporting, and balance reconciliation.

```sql
CREATE TABLE financial_transactions (
    -- Transaction identity
    transaction_reference       VARCHAR,

    -- Account details
    source_account_number       VARCHAR,
    destination_account_number  VARCHAR,
    source_bank_code            VARCHAR,
    destination_bank_code       VARCHAR,
    source_bank_name            VARCHAR,
    destination_bank_name       VARCHAR,
    source_account_name         VARCHAR,
    destination_account_name    VARCHAR,

    -- Customer profile
    customer_id                 VARCHAR,
    customer_region             VARCHAR,
    kyc_level                   SMALLINT,   -- 1 = basic, 2 = standard, 3 = full

    -- Transaction details
    transaction_time            TIMESTAMPTZ,
    transaction_amount          BIGINT,     -- in cents (minor currency units)
    narration                   VARCHAR,
    transaction_type            VARCHAR,    -- DEBIT | CREDIT | REVERSAL
    transaction_category        VARCHAR,    -- TRANSFER | BILL_PAYMENT | POS | ATM | SUBSCRIPTION
    channel                     VARCHAR,    -- MOBILE | WEB | ACH | POS | ATM | BRANCH

    -- Account limits (in cents)
    maximum_daily_debit_limit   BIGINT,
    maximum_daily_credit_limit  BIGINT,
    maximum_single_debit_limit  BIGINT,
    maximum_single_credit_limit BIGINT,

    -- Flow flags
    is_inflow                   BOOLEAN,
    is_outflow                  BOOLEAN,

    -- Balance snapshot (in cents)
    balance_before              BIGINT,
    balance_after               BIGINT,

    -- Terminal location (POS / ATM only, null for other channels)
    terminal_serial_no          VARCHAR,
    terminal_lat                DOUBLE PRECISION,
    terminal_long               DOUBLE PRECISION,

    -- Business classification
    debtor_business_class       VARCHAR,
    creditor_business_class     VARCHAR,

    -- Processing metadata
    proc_time                   TIMESTAMPTZ,
    created_at                  TIMESTAMPTZ DEFAULT NOW()
)
WITH (commit_checkpoint_interval = 1)
ENGINE = iceberg;
```

> `ENGINE = iceberg` tells RisingWave to persist this table as an Apache Iceberg table in Lakekeeper instead of its internal Hummock storage. `commit_checkpoint_interval = 1` ensures every checkpoint flush is committed to Iceberg, giving near-real-time visibility to downstream readers like ClickHouse.

---

## Step 5 — Insert sample transaction data

The following rows simulate a realistic mix of transaction types across channels, US cities, and KYC tiers:

```sql
INSERT INTO financial_transactions VALUES
-- Mobile P2P transfer, KYC level 3, New York
('TXN-20250801-000001', 'ACC-1001', 'ACC-2045', 'BNK-001', 'BNK-002',
 'JPMorgan Chase', 'Bank of America', 'James Mitchell', 'Emily Chen',
 'CUST-1001', 'New York', 3,
 '2025-08-01 08:15:23+00', 250000, 'College tuition payment',
 'DEBIT', 'TRANSFER', 'MOBILE',
 5000000, 10000000, 500000, 2000000,
 false, true,
 1500000, 1250000,
 NULL, NULL, NULL,
 'INDIVIDUAL', 'INDIVIDUAL',
 '2025-08-01 08:15:24+00', NOW()),

-- POS grocery, KYC level 2, Los Angeles
('TXN-20250801-000002', 'ACC-2045', 'ACC-3099', 'BNK-002', 'BNK-003',
 'Bank of America', 'Wells Fargo', 'Emily Chen', 'Whole Foods Market',
 'CUST-2045', 'Los Angeles', 2,
 '2025-08-01 09:42:11+00', 18500, 'Grocery purchase',
 'DEBIT', 'POS', 'POS',
 2000000, 5000000, 200000, 1000000,
 false, true,
 980000, 961500,
 'POS-SN-00234', 34.0522, -118.2437,
 'INDIVIDUAL', 'RETAIL_MERCHANT',
 '2025-08-01 09:42:12+00', NOW()),

-- Mobile streaming subscription, KYC level 1, Chicago
('TXN-20250801-000003', 'ACC-5021', 'ACC-9001', 'BNK-005', 'BNK-009',
 'US Bank', 'Citibank', 'Robert Davis', 'Netflix LLC',
 'CUST-5021', 'Chicago', 1,
 '2025-08-01 10:05:00+00', 5000, 'Monthly streaming subscription',
 'DEBIT', 'SUBSCRIPTION', 'MOBILE',
 500000, 500000, 50000, 50000,
 false, true,
 305000, 300000,
 NULL, NULL, NULL,
 'INDIVIDUAL', 'TECH_SERVICES',
 '2025-08-01 10:05:01+00', NOW()),

-- ACH payroll direct deposit, KYC level 3, Houston
('TXN-20250801-000004', 'ACC-8810', 'ACC-1001', 'BNK-008', 'BNK-001',
 'PNC Bank', 'JPMorgan Chase', 'Acme Corp', 'James Mitchell',
 'CUST-1001', 'Houston', 3,
 '2025-08-01 11:30:45+00', 750000, 'Payroll direct deposit',
 'CREDIT', 'TRANSFER', 'ACH',
 5000000, 10000000, 500000, 2000000,
 true, false,
 1250000, 2000000,
 NULL, NULL, NULL,
 'CORPORATE', 'INDIVIDUAL',
 '2025-08-01 11:30:46+00', NOW()),

-- ATM cash withdrawal, KYC level 2, Phoenix
('TXN-20250801-000005', 'ACC-3301', 'ACC-ATM-01', 'BNK-003', 'BNK-003',
 'Wells Fargo', 'Wells Fargo', 'Michael Thompson', 'ATM Vault',
 'CUST-3301', 'Phoenix', 2,
 '2025-08-01 12:10:33+00', 40000, 'ATM cash withdrawal',
 'DEBIT', 'ATM', 'ATM',
 2000000, 5000000, 200000, 1000000,
 false, true,
 420000, 380000,
 'ATM-PHX-0047', 33.4484, -112.0740,
 'INDIVIDUAL', 'FINANCIAL_SERVICES',
 '2025-08-01 12:10:34+00', NOW()),

-- Bill payment via mobile, KYC level 3, Seattle
('TXN-20250801-000006', 'ACC-7712', 'ACC-UTIL-01', 'BNK-007', 'BNK-001',
 'TD Bank', 'JPMorgan Chase', 'Olivia Martinez', 'Seattle City Light',
 'CUST-7712', 'Seattle', 3,
 '2025-08-01 13:55:10+00', 32000, 'Electricity bill - August',
 'DEBIT', 'BILL_PAYMENT', 'MOBILE',
 5000000, 10000000, 500000, 2000000,
 false, true,
 650000, 618000,
 NULL, NULL, NULL,
 'INDIVIDUAL', 'UTILITY',
 '2025-08-01 13:55:11+00', NOW()),

-- Branch transfer, KYC level 1, Denver
('TXN-20250801-000007', 'ACC-4450', 'ACC-6680', 'BNK-004', 'BNK-006',
 'Citibank', 'Capital One', 'William Anderson', 'Sophia Lee',
 'CUST-4450', 'Denver', 1,
 '2025-08-01 14:22:05+00', 15000, 'Family transfer',
 'DEBIT', 'TRANSFER', 'BRANCH',
 500000, 500000, 50000, 50000,
 false, true,
 95000, 80000,
 NULL, NULL, NULL,
 'INDIVIDUAL', 'INDIVIDUAL',
 '2025-08-01 14:22:06+00', NOW()),

-- Subscription reversal, KYC level 1, Chicago
('TXN-20250801-000008', 'ACC-9001', 'ACC-5021', 'BNK-009', 'BNK-005',
 'Citibank', 'US Bank', 'Netflix LLC', 'Robert Davis',
 'CUST-5021', 'Chicago', 1,
 '2025-08-01 14:45:00+00', 5000, 'Streaming subscription reversal',
 'REVERSAL', 'SUBSCRIPTION', 'MOBILE',
 500000, 500000, 50000, 50000,
 true, false,
 300000, 305000,
 NULL, NULL, NULL,
 'TECH_SERVICES', 'INDIVIDUAL',
 '2025-08-01 14:45:01+00', NOW());
```

Verify the data is visible inside RisingWave:

```sql
SELECT transaction_reference, customer_region, channel,
       transaction_amount, transaction_type, kyc_level
FROM financial_transactions
ORDER BY transaction_time;
```

> **Note:** `ENGINE = iceberg` writes data on checkpoint boundaries. If the `SELECT` returns 0 rows immediately after `INSERT`, wait a few seconds for the first checkpoint to flush and re-run the query.

Expected output:

```
 transaction_reference | customer_region | channel | transaction_amount | transaction_type | kyc_level
-----------------------+-----------------+---------+--------------------+------------------+-----------
 TXN-20250801-000001   | New York        | MOBILE  |             250000 | DEBIT            |         3
 TXN-20250801-000002   | Los Angeles     | POS     |              18500 | DEBIT            |         2
 TXN-20250801-000003   | Chicago         | MOBILE  |               5000 | DEBIT            |         1
 TXN-20250801-000004   | Houston         | ACH     |             750000 | CREDIT           |         3
 TXN-20250801-000005   | Phoenix         | ATM     |              40000 | DEBIT            |         2
 TXN-20250801-000006   | Seattle         | MOBILE  |              32000 | DEBIT            |         3
 TXN-20250801-000007   | Denver          | BRANCH  |              15000 | DEBIT            |         1
 TXN-20250801-000008   | Chicago         | MOBILE  |               5000 | REVERSAL         |         1
(8 rows)
```

---

## Step 6 — Query the Iceberg table from ClickHouse

Because `ENGINE = iceberg` was used, the data is physically stored as Parquet files in MinIO and registered in the Lakekeeper catalog. ClickHouse can read the exact same table with zero data movement.

### Install ClickHouse

```bash
curl https://clickhouse.com/ | sh
```

### Map MinIO hostname

ClickHouse runs outside Docker, so it needs to resolve `minio-0` — the hostname used inside Compose:

```bash
# Linux / macOS
echo "127.0.0.1 minio-0" | sudo tee -a /etc/hosts

# Windows (run as Administrator in PowerShell)
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "127.0.0.1 minio-0"
```

### Launch ClickHouse

```bash
./clickhouse local
```

### Enable the Iceberg catalog and connect to Lakekeeper

```sql
SET allow_experimental_database_iceberg = 1;

CREATE DATABASE lakekeeper_catalog
ENGINE = DataLakeCatalog('http://127.0.0.1:8181/catalog/', 'hummockadmin', 'hummockadmin')
SETTINGS
    catalog_type     = 'rest',
    storage_endpoint = 'http://127.0.0.1:9301/',
    warehouse        = 'risingwave-warehouse';

USE lakekeeper_catalog;
```

> ClickHouse's `DataLakeCatalog` engine connects to Iceberg REST catalogs such as Lakekeeper and exposes the entire catalog as a database. You must enable `allow_experimental_database_iceberg` first. Backticks are required when querying namespaced Iceberg tables (e.g., `` `public.financial_transactions` ``).

### Verify the table is visible

```sql
SHOW TABLES;
-- Should list: public.financial_transactions

SELECT * FROM `public.financial_transactions` ORDER BY transaction_time LIMIT 5;
```

---

## Step 7 — Financial analytics queries

Run full analytics directly on the Iceberg data from ClickHouse.

### Transaction volume by channel

```sql
SELECT
    channel,
    count()                                AS total_transactions,
    sum(transaction_amount) / 100.0        AS total_volume_usd,
    avg(transaction_amount) / 100.0        AS avg_transaction_usd
FROM `public.financial_transactions`
WHERE transaction_type != 'REVERSAL'
GROUP BY channel
ORDER BY total_volume_usd DESC;
```

### Regional breakdown

```sql
SELECT
    customer_region,
    count()                            AS tx_count,
    sum(transaction_amount) / 100.0    AS total_volume_usd
FROM `public.financial_transactions`
WHERE transaction_type = 'DEBIT'
GROUP BY customer_region
ORDER BY total_volume_usd DESC;
```

### KYC tier compliance view

```sql
SELECT
    kyc_level,
    count()                                AS tx_count,
    sum(transaction_amount) / 100.0        AS total_volume_usd,
    max(transaction_amount) / 100.0        AS max_single_tx_usd
FROM `public.financial_transactions`
GROUP BY kyc_level
ORDER BY kyc_level;
```

### POS terminal activity (geospatial)

```sql
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
```

### Balance reconciliation check

```sql
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
```

### Reversal rate by category

```sql
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
```

---

## Why this stack matters for financial services

| Concern | Traditional OLAP sink | RisingWave + Iceberg + Lakekeeper |
|---|---|---|
| **Vendor lock-in** | Proprietary format | Open Iceberg format — any engine can read |
| **Multi-engine access** | Copy data per tool | ClickHouse, Spark, Trino, Flink all read the same files |
| **Time travel** | Manual snapshots | Iceberg snapshots built-in |
| **Schema evolution** | Risky, often requires re-ingestion | Iceberg handles column adds/renames safely |
| **Catalog governance** | Tool-specific | Lakekeeper provides a single REST catalog for all engines |
| **Streaming latency** | Micro-batch | RisingWave commits on checkpoint — near-real-time |
| **Storage cost** | Proprietary storage pricing | Commodity object storage (S3, MinIO, GCS) |

---

## Optional: Clean up

> **Warning:** `-v` deletes Docker volumes (all Iceberg data will be deleted).

```bash
docker compose down -v
```

---

## Summary

In this tutorial you:

1. Launched a full RisingWave + Lakekeeper + MinIO stack with a single `docker compose up`
2. Created a Lakekeeper REST catalog connection in RisingWave
3. Defined a financial transactions table backed by Apache Iceberg (`ENGINE = iceberg`)
4. Streamed realistic US transaction data covering multiple channels, cities, KYC tiers, and transaction types
5. Queried the same Iceberg table from ClickHouse — no copies, no pipelines, same files
6. Ran financial analytics: volume by channel, regional breakdown, KYC compliance, POS geolocation, and balance reconciliation

The combination of **RisingWave** for stream processing, **Lakekeeper** as the Iceberg REST catalog, and **ClickHouse** for ad-hoc analytics gives financial platforms a modern, open, and cost-effective alternative to proprietary OLAP databases — without sacrificing real-time latency or query performance.

---

## Resources

- [RisingWave Documentation](https://docs.risingwave.com)
- [RisingWave Iceberg Sink Guide](https://docs.risingwave.com/docs/current/sink-to-iceberg/)
- [Lakekeeper Documentation](https://docs.lakekeeper.io)
- [Apache Iceberg Specification](https://iceberg.apache.org/spec/)
- [ClickHouse DataLakeCatalog Engine](https://clickhouse.com/docs/engines/database-engines/iceberg)
- [Demo Repository](https://github.com/fahadullahshah261/awesome-stream-processing/tree/main/07-iceberg-demos/risingwave_lakekeeper_iceberg_clickhouse_fintxn)
