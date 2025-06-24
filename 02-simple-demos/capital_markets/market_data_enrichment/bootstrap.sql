-- Base tables
CREATE TABLE raw_market_data (
  asset_id INT,
  timestamp TIMESTAMPTZ,
  price NUMERIC,
  volume INT,
  bid_price NUMERIC,
  ask_price NUMERIC
);

CREATE TABLE enrichment_data (
  asset_id INT,
  sector VARCHAR,
  historical_volatility NUMERIC,
  sector_performance NUMERIC,
  sentiment_score NUMERIC,
  timestamp TIMESTAMPTZ
);

-- Materialized Views
CREATE MATERIALIZED VIEW avg_price_bid_ask_spread AS
SELECT
    asset_id,
    ROUND(AVG(price) OVER (PARTITION BY asset_id ORDER BY timestamp RANGE INTERVAL '5 MINUTES' PRECEDING), 2) AS average_price,
    ROUND(AVG(ask_price - bid_price) OVER (PARTITION BY asset_id ORDER BY timestamp RANGE INTERVAL '5 MINUTES' PRECEDING), 2) AS bid_ask_spread,
    timestamp
FROM raw_market_data;

CREATE MATERIALIZED VIEW rolling_volatility AS
SELECT
    asset_id,
    ROUND(stddev_samp(price) OVER (PARTITION BY asset_id ORDER BY timestamp RANGE INTERVAL '15 MINUTES' PRECEDING), 2) AS rolling_volatility,
    timestamp
FROM raw_market_data;

CREATE MATERIALIZED VIEW enriched_market_data AS
SELECT
    rmd.asset_id,
    ap.average_price,
    (rmd.price - ap.average_price) / ap.average_price * 100 AS price_change,
    ap.bid_ask_spread,
    rv.rolling_volatility,
    ed.sector_performance,
    ed.sentiment_score,
    rmd.timestamp
FROM
    raw_market_data AS rmd
JOIN 
    avg_price_bid_ask_spread AS ap ON rmd.asset_id = ap.asset_id
    AND rmd.timestamp BETWEEN ap.timestamp - INTERVAL '2 seconds' AND ap.timestamp + INTERVAL '2 seconds'
JOIN 
    rolling_volatility AS rv ON rmd.asset_id = rv.asset_id
    AND rmd.timestamp BETWEEN rv.timestamp - INTERVAL '2 seconds' AND rv.timestamp + INTERVAL '2 seconds'
JOIN 
    enrichment_data AS ed ON rmd.asset_id = ed.asset_id
    AND rmd.timestamp BETWEEN ed.timestamp - INTERVAL '2 seconds' AND ed.timestamp + INTERVAL '2 seconds';

-- Sinks
CREATE SINK sink_avg_price
FROM avg_price_bid_ask_spread
WITH (
  connector = 'postgres',
  type = 'append-only',
  force_append_only = 'true',
  host = 'postgres',
  port = 5432,
  user = 'pguser',
  password = 'pgpass',
  database = 'pgdb',
  table = 'avg_price_sink'
);

CREATE SINK sink_rolling_volatility
FROM rolling_volatility
WITH (
  connector = 'postgres',
  type = 'append-only',
  force_append_only = 'true',
  host = 'postgres',
  port = 5432,
  user = 'pguser',
  password = 'pgpass',
  database = 'pgdb',
  table = 'rolling_volatility_sink'
);

CREATE SINK sink_enriched
FROM enriched_market_data
WITH (
  connector = 'postgres',
  type = 'append-only',
  force_append_only = 'true',
  host = 'postgres',
  port = 5432,
  user = 'pguser',
  password = 'pgpass',
  database = 'pgdb',
  table = 'enriched_market_data_sink'
);
