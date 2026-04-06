-- ============================================================
-- RisingWave setup: connection, table, data, and verification
-- Run via: psql -h localhost -p 4566 -d dev -U root
-- ============================================================

-- Step 1: Create the Lakekeeper REST catalog connection
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

-- Step 2: Set as default Iceberg connection for this session
SET iceberg_engine_connection = 'public.lakekeeper_catalog_conn';

-- Step 3: Create the financial transactions table backed by Iceberg
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

-- Step 4: Insert 8 sample US transactions
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

-- Step 5: Verify (wait a few seconds after INSERT for checkpoint flush)
SELECT transaction_reference, customer_region, channel,
       transaction_amount, transaction_type, kyc_level
FROM financial_transactions
ORDER BY transaction_time;
