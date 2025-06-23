#!/bin/bash

set -e
set -o pipefail

# --- Configuration ---
SUPERSET_URL="${SUPERSET_URL:-http://localhost:8088}"
SUPERSET_USERNAME="${SUPERSET_USERNAME:-admin}"
SUPERSET_PASSWORD="${SUPERSET_PASSWORD:-admin}"

DB_NAME="Postgres_Market_Data"
SQLALCHEMY_URI="postgresql://pguser:pgpass@postgres:5432/pgdb"

DATASET_TABLE_NAME="avg_price_bid_ask_spread"
DATASET_NAME="Avg Price Bid Ask Spread Data"
CHART_1_NAME="Average Price and Bid-Ask Spread Over Time"
CHART_2_NAME="Bid-Ask Spread Distribution"
DASHBOARD_TITLE="Market Data Analysis Dashboard"

# --- Pre-requisite Checks ---
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    echo "Error: 'curl' and 'jq' are required. Please install them to run this script." >&2
    exit 1
fi

# --- Helper Function for Idempotent Asset Creation ---
# CRITICAL: All logging messages (echo) are redirected to standard error (>&2).
# This ensures that only the final 'echo $id' (the return value) is sent to standard output
# and correctly captured by the variable assignments (e.g., VAR=$(...)).
get_or_create_asset() {
    local asset_type="$1"
    local asset_name="$2"
    local filter_q="$3"
    local create_payload="$4"
    local existing_id=""

    echo "--- Managing ${asset_type^}: '$asset_name' ---" >&2

    local get_response
    get_response=$(curl -s -G "$SUPERSET_URL/api/v1/$asset_type/" \
      -H "Authorization: Bearer $TOKEN" \
      --data-urlencode "$filter_q")
    
    existing_id=$(echo "$get_response" | jq -r '.result[0].id // empty')

    if [[ -n "$existing_id" ]]; then
        echo "✅ ${asset_type^} '$asset_name' already exists with ID: $existing_id" >&2
        echo "$existing_id" # This is the return value to stdout
        return
    fi

    echo "➡️ ${asset_type^} '$asset_name' not found, creating it..." >&2
    local create_response
    create_response=$(curl -s -X POST "$SUPERSET_URL/api/v1/$asset_type/" \
        -H "Authorization: Bearer $TOKEN" \
        -H "X-CSRFToken: $CSRF_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$create_payload")

    local new_id
    new_id=$(echo "$create_response" | jq -r '.id // empty')

    if [[ -z "$new_id" ]]; then
        echo "❌ Failed to create ${asset_type} '$asset_name'. Response: $create_response" >&2
        exit 1
    fi
    
    echo "✅ ${asset_type^} '$asset_name' created with ID: $new_id" >&2
    echo "$new_id" # This is the return value to stdout
}


# --- 1. Authentication ---
echo "⏳ Waiting for Superset API..." >&2
until curl -s "$SUPERSET_URL/api/v1/ping" &> /dev/null; do sleep 1 && printf "."; done
echo -e "\n✅ Superset is up." >&2

echo "🔐 Logging in to Superset..." >&2
LOGIN_RESPONSE=$(curl -s -X POST "$SUPERSET_URL/api/v1/security/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\": \"$SUPERSET_USERNAME\", \"password\": \"$SUPERSET_PASSWORD\", \"provider\": \"db\"}")

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.access_token // empty')
[[ -z "$TOKEN" ]] && echo "❌ Login failed. Response: $LOGIN_RESPONSE" >&2 && exit 1
echo "🔑 Login successful." >&2

CSRF_TOKEN=$(curl -s -H "Authorization: Bearer $TOKEN" "$SUPERSET_URL/api/v1/security/csrf_token/" | jq -r '.result // empty')
[[ -z "$CSRF_TOKEN" ]] && echo "❌ Failed to get CSRF token." >&2 && exit 1
echo "✅ Got CSRF token." >&2


# --- 2. Create Database ---
DB_FILTER_Q="q=$(jq -n --arg name "$DB_NAME" '{filters:[{col:"database_name",opr:"eq",value:$name}]}')"
CREATE_DB_PAYLOAD=$(jq -n \
    --arg name "$DB_NAME" \
    --arg uri "$SQLALCHEMY_URI" \
    '{database_name: $name, sqlalchemy_uri: $uri, expose_in_sqllab: true}')
DB_ID=$(get_or_create_asset "database" "$DB_NAME" "$DB_FILTER_Q" "$CREATE_DB_PAYLOAD")


# --- 3. Create Dataset ---
DATASET_FILTER_Q="q=$(jq -n --arg name "$DATASET_TABLE_NAME" --argjson db_id "$DB_ID" '{filters:[{col:"table_name",opr:"eq",value:$name},{col:"database_id",opr:"eq",value:($db_id | tonumber)}] }')"
CREATE_DATASET_PAYLOAD=$(jq -n \
    --argjson db_id "$DB_ID" \
    --arg table_name "$DATASET_TABLE_NAME" \
    '{database: ($db_id | tonumber), table_name: $table_name, schema: "public", owners: [1]}')
DATASET_ID=$(get_or_create_asset "dataset" "$DATASET_NAME" "$DATASET_FILTER_Q" "$CREATE_DATASET_PAYLOAD")


# --- 4. Synchronize Dataset Columns & Add Metrics ---
echo "--- Synchronizing columns and metrics for dataset '$DATASET_NAME' ---" >&2
curl -s -X PUT "$SUPERSET_URL/api/v1/dataset/$DATASET_ID/refresh" -H "Authorization: Bearer $TOKEN" -H "X-CSRFToken: $CSRF_TOKEN" > /dev/null
DESIRED_METRICS=$(jq -n '{"average_price": "AVG(average_price)","bid_ask_spread": "AVG(bid_ask_spread)","count": "COUNT(*)"}')
CURRENT_DATASET_DETAILS=$(curl -s -X GET "$SUPERSET_URL/api/v1/dataset/$DATASET_ID?q=\{\"columns\":[\"metrics\"]}" -H "Authorization: Bearer $TOKEN")
FINAL_METRICS=$(echo "$CURRENT_DATASET_DETAILS" | jq '.result.metrics // []')
METRICS_WERE_MODIFIED=0
for metric_name in $(echo "$DESIRED_METRICS" | jq -r 'keys[]'); do
    metric_exists=$(echo "$FINAL_METRICS" | jq --arg name "$metric_name" 'any(.metric_name == $name)')
    if [[ "$metric_exists" == "false" ]]; then
        echo "    - Metric '$metric_name' not found, preparing to add it." >&2
        expression=$(echo "$DESIRED_METRICS" | jq -r ".${metric_name}")
        verbose_name=$(echo "$metric_name" | tr '_' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')
        FINAL_METRICS=$(echo "$FINAL_METRICS" | jq --arg name "$metric_name" --arg expr "$expression" --arg vname "$verbose_name" '. + [{"metric_name": $name, "expression": $expr, "verbose_name": $vname}]')
        METRICS_WERE_MODIFIED=1
    else
        echo "    - Metric '$metric_name' already exists." >&2
    fi
done
if [[ "$METRICS_WERE_MODIFIED" -eq 1 ]]; then
    echo "    - Updating dataset with new metrics..." >&2
    UPDATE_PAYLOAD=$(jq -n --argjson metrics "$FINAL_METRICS" '{metrics: $metrics}')
    UPDATE_RESPONSE=$(curl -s -X PUT "$SUPERSET_URL/api/v1/dataset/$DATASET_ID" -H "Authorization: Bearer $TOKEN" -H "X-CSRFToken: $CSRF_TOKEN" -H "Content-Type: application/json" -d "$UPDATE_PAYLOAD")
    if echo "$UPDATE_RESPONSE" | jq -e '.result' > /dev/null; then echo "✅ Dataset metrics updated successfully." >&2; else echo "❌ Failed to update dataset metrics. Response: $UPDATE_RESPONSE" >&2; exit 1; fi
else
    echo "✅ All required metrics are present." >&2
fi


# --- 5. Create Charts ---
DATETIME_COLUMN=$(curl -s -G "$SUPERSET_URL/api/v1/dataset/$DATASET_ID" -H "Authorization: Bearer $TOKEN" --data-urlencode 'q={"columns":["columns"]}' | jq -r '.result.columns[]? | select(.type_generic == 2 or .is_dttm == true) | .column_name' | head -1)
[[ -z "$DATETIME_COLUMN" ]] && DATETIME_COLUMN="timestamp"
echo "✅ Using datetime column: '$DATETIME_COLUMN'" >&2
CHART_1_FILTER_Q="q=$(jq -n --arg name "$CHART_1_NAME" --argjson ds_id "$DATASET_ID" '{filters:[{col:"slice_name",opr:"eq",value:$name},{col:"datasource_id",opr:"eq",value:$ds_id}]}')"
CHART_1_PARAMS=$(jq -n --arg dt_col "$DATETIME_COLUMN" '{viz_type:"line", datasource:($ARGS.positional[0]+"__table"), granularity_sqla:$dt_col, time_range:"No filter", metrics:["average_price","bid_ask_spread"], groupby:["asset_id"], show_legend:true, row_limit:10000}' --args "$DATASET_ID" | jq -c . | jq -Rs .)
CREATE_CHART_1_PAYLOAD=$(jq -n --arg name "$CHART_1_NAME" --argjson ds_id "$DATASET_ID" --arg params "$CHART_1_PARAMS" '{slice_name:$name, viz_type:"line", datasource_id:$ds_id, datasource_type:"table", params:$params, owners:[1]}')
CHART_1_ID=$(get_or_create_asset "chart" "$CHART_1_NAME" "$CHART_1_FILTER_Q" "$CREATE_CHART_1_PAYLOAD")
CHART_2_FILTER_Q="q=$(jq -n --arg name "$CHART_2_NAME" --argjson ds_id "$DATASET_ID" '{filters:[{col:"slice_name",opr:"eq",value:$name},{col:"datasource_id",opr:"eq",value:$ds_id}]}')"
CHART_2_PARAMS=$(jq -n '{viz_type:"dist_bar", datasource:($ARGS.positional[0]+"__table"), metrics:["count"], groupby:["bid_ask_spread"], row_limit:50}' --args "$DATASET_ID" | jq -c . | jq -Rs .)
CREATE_CHART_2_PAYLOAD=$(jq -n --arg name "$CHART_2_NAME" --argjson ds_id "$DATASET_ID" --arg params "$CHART_2_PARAMS" '{slice_name:$name, viz_type:"dist_bar", datasource_id:$ds_id, datasource_type:"table", params:$params, owners:[1]}')
CHART_2_ID=$(get_or_create_asset "chart" "$CHART_2_NAME" "$CHART_2_FILTER_Q" "$CREATE_CHART_2_PAYLOAD")


# --- 6. Create Dashboard and Add Charts ---
DASHBOARD_FILTER_Q="q=$(jq -n --arg title "$DASHBOARD_TITLE" '{filters:[{col:"dashboard_title",opr:"eq",value:$title}]}')"
POSITION_JSON=$(jq -n --argjson c1_id "$CHART_1_ID" --argjson c2_id "$CHART_2_ID" '{"uuid-root": {type: "ROOT", id: "uuid-root", children: ["uuid-grid"]},"uuid-grid": {type: "GRID", id: "uuid-grid", children: ["uuid-header", "uuid-row-1"], meta: {}},"uuid-header": {type: "HEADER", id: "uuid-header", meta: {text: "Market Data Analysis Dashboard"}},"uuid-row-1": {type: "ROW", id: "uuid-row-1", children: ["uuid-chart-1", "uuid-chart-2"], meta: {background: "BACKGROUND_TRANSPARENT"}},"uuid-chart-1": {type: "CHART", id: "uuid-chart-1", children: [], meta: {width: 6, height: 50, chartId: $c1_id, uuid: "c1-uuid"}},"uuid-chart-2": {type: "CHART", id: "uuid-chart-2", children: [], meta: {width: 6, height: 50, chartId: $c2_id, uuid: "c2-uuid"}}}' | jq -c . | jq -Rs .)
CREATE_DASHBOARD_PAYLOAD=$(jq -n --arg title "$DASHBOARD_TITLE" --argjson charts "[$CHART_1_ID, $CHART_2_ID]" --arg position "$POSITION_JSON" '{dashboard_title: $title, charts: $charts, position_json: $position, published: true, owners: [1]}')
DASHBOARD_ID=$(get_or_create_asset "dashboard" "$DASHBOARD_TITLE" "$DASHBOARD_FILTER_Q" "$CREATE_DASHBOARD_PAYLOAD")

# --- Final ---
echo ""
echo "🎉 SUCCESS! Superset setup complete!"
echo "🌐 Visit your dashboard: $SUPERSET_URL/superset/dashboard/$DASHBOARD_ID/"