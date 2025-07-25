DROP SOURCE IF EXISTS raw_market_data;
CREATE SOURCE raw_market_data (
  asset_id     INT,
  timestamp    TIMESTAMPTZ,
  price        DOUBLE,
  volume       INT,
  bid_price    DOUBLE,
  ask_price    DOUBLE
) WITH (
  connector                   = 'kafka',
  topic                       = 'raw_market_data',
  properties.bootstrap.server = 'kafka:9092',
  scan.startup.mode           = 'earliest'
) FORMAT PLAIN ENCODE JSON;

DROP SOURCE IF EXISTS enrichment_data;
CREATE SOURCE enrichment_data (
  asset_id              INT,
  sector                VARCHAR,
  historical_volatility DOUBLE,
  sector_performance    DOUBLE,
  sentiment_score       DOUBLE,
  timestamp             TIMESTAMPTZ
) WITH (
  connector                   = 'kafka',
  topic                       = 'enrichment_data',
  properties.bootstrap.server = 'kafka:9092',
  scan.startup.mode           = 'earliest'
) FORMAT PLAIN ENCODE JSON;

CREATE MATERIALIZED VIEW avg_price_bid_ask_spread AS
SELECT
  asset_id,
  timestamp,
  ROUND(
    AVG(price) OVER (
      PARTITION BY asset_id
      ORDER BY timestamp
      RANGE BETWEEN INTERVAL '3 seconds' PRECEDING AND CURRENT ROW
    )::NUMERIC, 2
  ) AS average_price,
  ROUND(
    AVG(ask_price - bid_price) OVER (
      PARTITION BY asset_id
      ORDER BY timestamp
      RANGE BETWEEN INTERVAL '3 seconds' PRECEDING AND CURRENT ROW
    )::NUMERIC, 2
  ) AS bid_ask_spread
FROM raw_market_data;


CREATE MATERIALIZED VIEW rolling_volatility AS
SELECT
  asset_id,
  timestamp,
  ROUND(
    stddev_samp(price) OVER (
      PARTITION BY asset_id
      ORDER BY timestamp
      RANGE BETWEEN INTERVAL '3 seconds' PRECEDING AND CURRENT ROW
    )::NUMERIC, 2
  ) AS rolling_volatility
FROM raw_market_data;

CREATE MATERIALIZED VIEW enriched_market_data AS
SELECT
  r.asset_id,
  ap.average_price,
  (r.price - ap.average_price) / ap.average_price * 100 AS price_change,
  ap.bid_ask_spread,
  rv.rolling_volatility,
  e.sector_performance,
  e.sentiment_score,
  r.timestamp
FROM raw_market_data AS r
JOIN avg_price_bid_ask_spread AS ap
  ON r.asset_id = ap.asset_id
 AND r.timestamp BETWEEN ap.timestamp - INTERVAL '3 seconds'
                     AND ap.timestamp + INTERVAL '3 seconds'
JOIN rolling_volatility AS rv
  ON r.asset_id = rv.asset_id
 AND r.timestamp BETWEEN rv.timestamp - INTERVAL '3 seconds'
                     AND rv.timestamp + INTERVAL '3 seconds'
JOIN enrichment_data AS e
  ON r.asset_id = e.asset_id
 AND r.timestamp BETWEEN e.timestamp - INTERVAL '3 seconds'
                     AND e.timestamp + INTERVAL '3 seconds';