#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

API_BASE="${API_BASE:-https://markets-service-production.up.railway.app}"
API_BASE_PRIMARY="$API_BASE"
API_BASE_BACKUP="${API_BASE_BACKUP:-${API_BASE_FALLBACK:-}}"
if [ -z "$API_BASE_BACKUP" ] && [ -n "${RAILWAY_SERVICE_MARKETS_SERVICE_URL:-}" ]; then
  case "$RAILWAY_SERVICE_MARKETS_SERVICE_URL" in
    http://*|https://*) API_BASE_BACKUP="$RAILWAY_SERVICE_MARKETS_SERVICE_URL" ;;
    *) API_BASE_BACKUP="https://$RAILWAY_SERVICE_MARKETS_SERVICE_URL" ;;
  esac
fi
ASSET_ADDRESS="${ASSET_ADDRESS:-0xCE2846771074E20fEc739CF97a60E6075D1E464b}"
SUB_ID="${SUB_ID:-1782777600}"

MATCHING_ADDRESS="${MATCHING_ADDRESS:-0x1599636347FD5bA1fBE21D58AfE0b8B9cbe283FF}"
TRADE_MODULE_ADDRESS="${TRADE_MODULE_ADDRESS:-0x0AAE65AaA66Fe7f54486cDbD007956d3De611990}"
RPC_URL="${RPC_URL:-https://base-sepolia-rpc.publicnode.com}"
CHAIN_ID="${CHAIN_ID:-84532}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
OWNER_PRIVATE_KEY="${OWNER_PRIVATE_KEY:-$PRIVATE_KEY}"
SIGNER_PRIVATE_KEY="${SIGNER_PRIVATE_KEY:-$PRIVATE_KEY}"

EXECUTION_SERVICE_DIR="${EXECUTION_SERVICE_DIR:-../execution-service}"
GENERATOR="${GENERATOR:-$EXECUTION_SERVICE_DIR/scripts/generate_trade_order.mjs}"

ASK_SUBACCOUNT_ID="${ASK_SUBACCOUNT_ID:-6}"
BUY_SUBACCOUNT_ID="${BUY_SUBACCOUNT_ID:-7}"

SMALL_UI_SIZE="${SMALL_UI_SIZE:-0.001}"
SMALL_ATOMIC_SIZE="${SMALL_ATOMIC_SIZE:-1000000000000000}"
ASK_UI_PRICE="${ASK_UI_PRICE:-1390}"
BUY_UI_PRICE="${BUY_UI_PRICE:-1391}"
ASK_ATOMIC_PRICE="${ASK_ATOMIC_PRICE:-1390000000000000000000}"
BUY_ATOMIC_PRICE="${BUY_ATOMIC_PRICE:-1391000000000000000000}"
AUTO_PRICE_FROM_BOOK="${AUTO_PRICE_FROM_BOOK:-true}"

VOLUME_CROSSES="${VOLUME_CROSSES:-10}"
PARTIAL_TAKERS="${PARTIAL_TAKERS:-5}"
PARTIAL_RESTING_UI_SIZE="${PARTIAL_RESTING_UI_SIZE:-0.010}"
PARTIAL_RESTING_ATOMIC_SIZE="${PARTIAL_RESTING_ATOMIC_SIZE:-10000000000000000}"

TRADE_INCREMENT_TIMEOUT_SECS="${TRADE_INCREMENT_TIMEOUT_SECS:-20}"
ORDER_STATUS_TIMEOUT_SECS="${ORDER_STATUS_TIMEOUT_SECS:-20}"
ORDER_STATUS_POLL_SECS="${ORDER_STATUS_POLL_SECS:-1}"

KPI_WINDOW_HOURS="${KPI_WINDOW_HOURS:-6}"
KPI_MIN_SUCCESS_RATE="${KPI_MIN_SUCCESS_RATE:-99}"
STATE_BACKEND="${STATE_BACKEND:-auto}"
STATE_KEY="${STATE_KEY:-jun-deposited-cross}"
SMOKE_STATE_DATABASE_URL="${SMOKE_STATE_DATABASE_URL:-${DATABASE_URL:-}}"
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/.smoke/state.json}"

NOW="$(date +%s)"
RUN_ID="${RUN_ID:-${NOW}-${RANDOM}}"
EXPIRY="$((NOW + 3600))"
NONCE_COUNTER="${NONCE_COUNTER:-$((NOW * 1000000 + RANDOM))}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ORDER_IDS=()
STATUS_JSON='{}'
STATUS_JSON_FILE="$TMP_DIR/status.json"
FAILURE_CLASS=""
FAILURE_DETAIL=""
FAILURE_CLASS_FILE="$TMP_DIR/failure_class.txt"
FAILURE_DETAIL_FILE="$TMP_DIR/failure_detail.txt"
NEXT_NONCE=""
EFFECTIVE_STATE_BACKEND=""
API_FAILOVER_USED="false"
printf '%s' '{}' > "$STATUS_JSON_FILE"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd jq
require_cmd node

if [ -z "$PRIVATE_KEY" ] && [ -z "$OWNER_PRIVATE_KEY" ]; then
  echo "PRIVATE_KEY (or OWNER_PRIVATE_KEY) is required" >&2
  exit 1
fi
if [ ! -f "$GENERATOR" ]; then
  echo "generator script not found at $GENERATOR" >&2
  exit 1
fi

if [ "$PARTIAL_TAKERS" -le 0 ] || [ "$VOLUME_CROSSES" -lt 0 ]; then
  echo "VOLUME_CROSSES and PARTIAL_TAKERS must be non-negative integers" >&2
  exit 1
fi

if [ "$PARTIAL_RESTING_ATOMIC_SIZE" -le "$PARTIAL_TAKERS" ]; then
  echo "PARTIAL_RESTING_ATOMIC_SIZE must be greater than PARTIAL_TAKERS for a true partial-fill scenario" >&2
  exit 1
fi

determine_state_backend() {
  case "$STATE_BACKEND" in
    postgres)
      require_cmd psql
      if [ -z "$SMOKE_STATE_DATABASE_URL" ]; then
        echo "SMOKE_STATE_DATABASE_URL (or DATABASE_URL) is required when STATE_BACKEND=postgres" >&2
        exit 1
      fi
      EFFECTIVE_STATE_BACKEND="postgres"
      ;;
    file)
      EFFECTIVE_STATE_BACKEND="file"
      ;;
    auto|*)
      if [ -n "$SMOKE_STATE_DATABASE_URL" ] && command -v psql >/dev/null 2>&1; then
        EFFECTIVE_STATE_BACKEND="postgres"
      else
        EFFECTIVE_STATE_BACKEND="file"
      fi
      ;;
  esac
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

state_store_init() {
  if [ "$EFFECTIVE_STATE_BACKEND" = "postgres" ]; then
    psql "$SMOKE_STATE_DATABASE_URL" -v ON_ERROR_STOP=1 -qAt <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS smoke_runner_state (
  state_key text PRIMARY KEY,
  state jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
SQL
    return
  fi
  local dir
  dir="$(dirname "$STATE_FILE")"
  mkdir -p "$dir"
  if [ ! -f "$STATE_FILE" ]; then
    printf '%s' '{"runs":[],"incident":{"active":false}}' > "$STATE_FILE"
  fi
}

load_state() {
  local key_escaped row
  if [ "$EFFECTIVE_STATE_BACKEND" = "postgres" ]; then
    key_escaped="$(sql_escape "$STATE_KEY")"
    row="$(psql "$SMOKE_STATE_DATABASE_URL" -v ON_ERROR_STOP=1 -qAt -c "SELECT state::text FROM smoke_runner_state WHERE state_key = '$key_escaped' LIMIT 1;" || true)"
    if [ -z "$row" ]; then
      printf '%s' '{"runs":[],"incident":{"active":false}}'
    else
      printf '%s' "$row"
    fi
    return
  fi
  cat "$STATE_FILE"
}

save_state() {
  local state_json="$1"
  local key_escaped state_escaped
  if [ "$EFFECTIVE_STATE_BACKEND" = "postgres" ]; then
    key_escaped="$(sql_escape "$STATE_KEY")"
    state_escaped="$(sql_escape "$state_json")"
    psql "$SMOKE_STATE_DATABASE_URL" -v ON_ERROR_STOP=1 -qAt -c "INSERT INTO smoke_runner_state(state_key, state, updated_at) VALUES ('$key_escaped', '$state_escaped'::jsonb, now()) ON CONFLICT (state_key) DO UPDATE SET state = EXCLUDED.state, updated_at = now();" >/dev/null
    return
  fi
  printf '%s' "$state_json" > "$STATE_FILE"
}

next_nonce() {
  NONCE_COUNTER=$((NONCE_COUNTER + 1))
  NEXT_NONCE="$NONCE_COUNTER"
}

append_order_id() {
  ORDER_IDS+=("$1")
}

record_status_json() {
  local order_id="$1"
  local payload="$2"
  STATUS_JSON="$(printf '%s' "$STATUS_JSON" | jq --arg id "$order_id" --argjson payload "$payload" '. + {($id): $payload}')"
  printf '%s' "$STATUS_JSON" > "$STATUS_JSON_FILE"
}

fail() {
  local class="$1"
  local message="$2"
  local ids
  local statuses
  ids="$(IFS=,; echo "${ORDER_IDS[*]-}")"
  statuses="$(printf '%s' "$STATUS_JSON" | jq -c . 2>/dev/null || echo '{}')"
  if [ "$statuses" = "{}" ] && [ -s "$STATUS_JSON_FILE" ]; then
    statuses="$(jq -c . "$STATUS_JSON_FILE" 2>/dev/null || echo '{}')"
  fi
  FAILURE_CLASS="$class"
  FAILURE_DETAIL="$message | order_ids=$ids | statuses=$statuses"
  printf '%s' "$FAILURE_CLASS" > "$FAILURE_CLASS_FILE"
  printf '%s' "$FAILURE_DETAIL" > "$FAILURE_DETAIL_FILE"
  return 1
}

is_infra_failure_class() {
  local class="${1:-}"
  [ "$class" = "api_dns_resolution" ] || [ "$class" = "api_connectivity" ]
}

classify_transport_failure() {
  local code="${1:-0}"
  if [ "$code" -eq 6 ]; then
    printf '%s' "api_dns_resolution"
    return
  fi
  printf '%s' "api_connectivity"
}

api_request() {
  local method="$1"
  local path="$2"
  local mode="${3:-none}"
  local payload="${4:-}"
  local url response body code rc stderr_file stderr_text failure_class
  local attempt=1

  while [ "$attempt" -le 2 ]; do
    url="${API_BASE}${path}"
    stderr_file="$TMP_DIR/curl_${RUN_ID}_${attempt}.stderr"
    rm -f "$stderr_file"

    case "$mode" in
      file)
        response="$(curl -sS -X "$method" "$url" -H 'content-type: application/json' --data @"$payload" -w $'\n%{http_code}' 2>"$stderr_file")"
        rc=$?
        ;;
      json)
        response="$(curl -sS -X "$method" "$url" -H 'content-type: application/json' --data "$payload" -w $'\n%{http_code}' 2>"$stderr_file")"
        rc=$?
        ;;
      *)
        response="$(curl -sS -X "$method" "$url" -w $'\n%{http_code}' 2>"$stderr_file")"
        rc=$?
        ;;
    esac

    if [ "$rc" -ne 0 ]; then
      stderr_text="$(tr '\n' ' ' < "$stderr_file" 2>/dev/null || true)"
      if [ "$rc" -eq 6 ] && [ "$attempt" -eq 1 ] && [ "$API_BASE" = "$API_BASE_PRIMARY" ] && [ -n "$API_BASE_BACKUP" ] && [ "$API_BASE_BACKUP" != "$API_BASE_PRIMARY" ]; then
        API_BASE="$API_BASE_BACKUP"
        API_FAILOVER_USED="true"
        attempt=$((attempt + 1))
        continue
      fi
      failure_class="$(classify_transport_failure "$rc")"
      fail "$failure_class" "$method $path transport failure curl_exit=$rc base=$API_BASE stderr=$stderr_text" || true
      return 1
    fi

    body="$(printf '%s' "$response" | sed '$d')"
    code="$(printf '%s' "$response" | tail -n1)"
    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
      fail "api_http_error" "$method $path returned http_status=$code base=$API_BASE body=$(printf '%s' "$body" | tr '\n' ' ')" || true
      return 1
    fi

    API_RESP_BODY="$body"
    API_RESP_CODE="$code"
    return 0
  done

  fail "api_connectivity" "$method $path exhausted retry attempts base=$API_BASE" || true
  return 1
}

fetch_trade_count() {
  local trades
  if ! api_request "GET" "/v1/trades?asset_address=$ASSET_ADDRESS&sub_id=$SUB_ID"; then
    return 1
  fi
  trades="$API_RESP_BODY"
  printf '%s' "$trades" | jq -r '.trades[0].trade_id // 0'
}

fetch_latest_trade() {
  local trades
  if ! api_request "GET" "/v1/trades?asset_address=$ASSET_ADDRESS&sub_id=$SUB_ID"; then
    return 1
  fi
  trades="$API_RESP_BODY"
  printf '%s' "$trades" | jq '.trades[0]'
}

scale_price_atomic() {
  local ui_price="$1"
  printf '%s000000000000000000' "$ui_price"
}

determine_cross_prices() {
  if [ "$AUTO_PRICE_FROM_BOOK" != "true" ]; then
    return 0
  fi
  local book best_ask
  if ! api_request "GET" "/v1/book?asset_address=$ASSET_ADDRESS&sub_id=$SUB_ID"; then
    return 1
  fi
  book="$API_RESP_BODY"
  best_ask="$(printf '%s' "$book" | jq -r '.asks[0].limit_price // empty')"
  if [ -z "$best_ask" ] || [ "$best_ask" -le 1 ]; then
    return 0
  fi

  ASK_UI_PRICE="$((best_ask - 1))"
  BUY_UI_PRICE="$best_ask"
  ASK_ATOMIC_PRICE="$(scale_price_atomic "$ASK_UI_PRICE")"
  BUY_ATOMIC_PRICE="$(scale_price_atomic "$BUY_UI_PRICE")"
}

wait_for_trade_increment() {
  local baseline="$1"
  local required_delta="$2"
  local deadline=$(( $(date +%s) + TRADE_INCREMENT_TIMEOUT_SECS ))
  local current
  while [ "$(date +%s)" -le "$deadline" ]; do
    if ! current="$(fetch_trade_count)"; then
      return 1
    fi
    if [ "$current" -ge $((baseline + required_delta)) ]; then
      printf '%s' "$current"
      return 0
    fi
    sleep 1
  done
  fail "no_trade_count_increment" "latest trade_id did not increase by $required_delta from baseline=$baseline within timeout=$TRADE_INCREMENT_TIMEOUT_SECS" || true
  return 1
}

build_order_payload() {
  local order_id="$1"
  local subaccount_id="$2"
  local nonce="$3"
  local side="$4"
  local ui_price="$5"
  local atomic_price="$6"
  local ui_size="$7"
  local atomic_size="$8"

  RPC_URL="$RPC_URL" \
  CHAIN_ID="$CHAIN_ID" \
  MATCHING_ADDRESS="$MATCHING_ADDRESS" \
  TRADE_MODULE_ADDRESS="$TRADE_MODULE_ADDRESS" \
  PRIVATE_KEY="$PRIVATE_KEY" \
  OWNER_PRIVATE_KEY="$OWNER_PRIVATE_KEY" \
  SIGNER_PRIVATE_KEY="$SIGNER_PRIVATE_KEY" \
  ORDER_ID="$order_id" \
  SUBACCOUNT_ID="$subaccount_id" \
  RECIPIENT_ID="$subaccount_id" \
  NONCE="$nonce" \
  EXPIRY="$EXPIRY" \
  ASSET_ADDRESS="$ASSET_ADDRESS" \
  SUB_ID="$SUB_ID" \
  LIMIT_PRICE="$atomic_price" \
  DESIRED_AMOUNT="$atomic_size" \
  WORST_FEE="0" \
  SIDE="$side" \
  node "$GENERATOR" > "$TMP_DIR/${order_id}.raw.json"

  jq --arg ds "$ui_size" --arg lp "$ui_price" \
    'del(.debug) | .desired_amount = $ds | .limit_price = $lp' \
    "$TMP_DIR/${order_id}.raw.json" > "$TMP_DIR/${order_id}.json"
}

submit_order_file() {
  local order_file="$1"
  if ! api_request "POST" "/v1/orders" "file" "$order_file"; then
    return 1
  fi
  printf '%s' "$API_RESP_BODY"
}

fetch_order_status() {
  local order_id="$1"
  local response
  if ! api_request "GET" "/v1/orders/$order_id"; then
    return 1
  fi
  response="$API_RESP_BODY"
  record_status_json "$order_id" "$response"
  printf '%s' "$response"
}

wait_for_terminal_status() {
  local order_id="$1"
  local required_remaining="$2"
  local deadline=$(( $(date +%s) + ORDER_STATUS_TIMEOUT_SECS ))
  local snapshot status remaining
  while [ "$(date +%s)" -le "$deadline" ]; do
    if ! snapshot="$(fetch_order_status "$order_id")"; then
      return 1
    fi
    status="$(printf '%s' "$snapshot" | jq -r '.status')"
    remaining="$(printf '%s' "$snapshot" | jq -r '.remaining_amount')"

    if [ "$status" = "match_failed" ]; then
      fail "smoke_order_not_terminal_or_ended_in_match_failed" "order $order_id ended in match_failed" || true
      return 1
    fi

    if [ "$status" != "active" ] && [ "$status" != "matching" ]; then
      if [ -n "$required_remaining" ] && [ "$remaining" != "$required_remaining" ]; then
        fail "smoke_order_not_terminal_or_ended_in_match_failed" "order $order_id terminal with unexpected remaining_amount=$remaining expected=$required_remaining" || true
        return 1
      fi
      return 0
    fi

    sleep "$ORDER_STATUS_POLL_SECS"
  done

  fail "smoke_order_not_terminal_or_ended_in_match_failed" "order $order_id remained non-terminal after timeout=$ORDER_STATUS_TIMEOUT_SECS" || true
  return 1
}

assert_not_resting_on_book() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  local book ids_csv
  if ! api_request "GET" "/v1/book?asset_address=$ASSET_ADDRESS&sub_id=$SUB_ID"; then
    return 1
  fi
  book="$API_RESP_BODY"
  ids_csv="$(printf '%s' "$*" | tr ' ' '|')"
  if printf '%s' "$book" | rg -q "$ids_csv"; then
    fail "smoke_order_still_resting_on_book" "one or more smoke orders still present in book" || true
    return 1
  fi
}

cancel_order() {
  local owner_address="$1"
  local nonce="$2"
  local reason="$3"
  local body
  body="$(jq -cn --arg owner "$owner_address" --arg nonce "$nonce" --arg reason "$reason" '{owner_address:$owner,nonce:$nonce,reason:$reason}')"
  if ! api_request "POST" "/v1/orders/cancel" "json" "$body"; then
    return 1
  fi
}

preflight_cleanup_prefixed_orders() {
  local max_rounds="${1:-5}"
  local round book rows row owner nonce order_id
  for round in $(seq 1 "$max_rounds"); do
    if ! api_request "GET" "/v1/book?asset_address=$ASSET_ADDRESS&sub_id=$SUB_ID"; then
      return 1
    fi
    book="$API_RESP_BODY"

    rows="$(printf '%s' "$book" | jq -r '
      [(.asks // []), (.bids // [])] | add
      | map(select((.order_id // "") | startswith("validation:") or startswith("smoke:") or startswith("manual:")))
      | map("\(.owner_address) \(.nonce) \(.order_id)")
      | unique
      | .[]?
    ')"
    if [ -z "$rows" ]; then
      return 0
    fi

    while IFS= read -r row; do
      [ -z "$row" ] && continue
      owner="$(printf '%s' "$row" | awk '{print $1}')"
      nonce="$(printf '%s' "$row" | awk '{print $2}')"
      order_id="$(printf '%s' "$row" | awk '{print $3}')"
      if ! cancel_order "$owner" "$nonce" "smoke_preflight_cleanup"; then
        fail "api_http_error" "preflight cleanup failed to cancel $order_id owner=$owner nonce=$nonce" || true
        return 1
      fi
    done <<< "$rows"
    sleep 1
  done

  fail "smoke_order_still_resting_on_book" "preflight cleanup could not clear prefixed resting orders within rounds=$max_rounds" || true
  return 1
}

run_full_cross() {
  local tag="$1"
  local baseline_count="$2"
  local ask_id buy_id
  local ask_nonce buy_nonce ask_resp buy_resp ask_oid buy_oid

  next_nonce
  ask_id="smoke:${tag}:ask:${RUN_ID}:${NEXT_NONCE}"
  next_nonce
  buy_id="smoke:${tag}:buy:${RUN_ID}:${NEXT_NONCE}"
  next_nonce
  ask_nonce="$NEXT_NONCE"
  next_nonce
  buy_nonce="$NEXT_NONCE"

  append_order_id "$ask_id"
  append_order_id "$buy_id"

  build_order_payload "$ask_id" "$ASK_SUBACCOUNT_ID" "$ask_nonce" "sell" "$ASK_UI_PRICE" "$ASK_ATOMIC_PRICE" "$SMALL_UI_SIZE" "$SMALL_ATOMIC_SIZE"
  build_order_payload "$buy_id" "$BUY_SUBACCOUNT_ID" "$buy_nonce" "buy" "$BUY_UI_PRICE" "$BUY_ATOMIC_PRICE" "$SMALL_UI_SIZE" "$SMALL_ATOMIC_SIZE"

  if ! ask_resp="$(submit_order_file "$TMP_DIR/${ask_id}.json")"; then
    return 1
  fi
  if ! buy_resp="$(submit_order_file "$TMP_DIR/${buy_id}.json")"; then
    return 1
  fi

  ask_oid="$(printf '%s' "$ask_resp" | jq -r '.order.order_id // empty')"
  buy_oid="$(printf '%s' "$buy_resp" | jq -r '.order.order_id // empty')"
  if [ "$ask_oid" != "$ask_id" ] || [ "$buy_oid" != "$buy_id" ]; then
    fail "api_http_error" "submit responses did not echo expected order ids for tag=$tag" || true
    return 1
  fi

  if ! CURRENT_TRADE_COUNT="$(wait_for_trade_increment "$baseline_count" 1)"; then
    return 1
  fi

  if ! wait_for_terminal_status "$ask_id" "0"; then
    return 1
  fi
  if ! wait_for_terminal_status "$buy_id" "0"; then
    return 1
  fi

  if ! assert_not_resting_on_book "$ask_id" "$buy_id"; then
    return 1
  fi

  return 0
}

run_partial_fill_scenario() {
  local baseline_count="$1"
  local resting_id
  local resting_nonce owner desired_before remaining_before filled_before remaining expected_remaining expected_filled i taker_id taker_nonce taker_resp taker_oid snapshot status filled

  next_nonce
  resting_id="smoke:partial:resting-ask:${RUN_ID}:${NEXT_NONCE}"
  next_nonce
  resting_nonce="$NEXT_NONCE"
  append_order_id "$resting_id"

  build_order_payload "$resting_id" "$ASK_SUBACCOUNT_ID" "$resting_nonce" "sell" "$ASK_UI_PRICE" "$ASK_ATOMIC_PRICE" "$PARTIAL_RESTING_UI_SIZE" "$PARTIAL_RESTING_ATOMIC_SIZE"

  if ! submit_order_file "$TMP_DIR/${resting_id}.json" >/dev/null; then
    return 1
  fi

  owner="$(jq -r '.owner_address' "$TMP_DIR/${resting_id}.json")"

  if ! snapshot="$(fetch_order_status "$resting_id")"; then
    return 1
  fi
  status="$(printf '%s' "$snapshot" | jq -r '.status')"
  filled_before="$(printf '%s' "$snapshot" | jq -r '.filled_amount')"
  remaining_before="$(printf '%s' "$snapshot" | jq -r '.remaining_amount')"
  if ! [[ "$filled_before" =~ ^[0-9]+$ ]] || ! [[ "$remaining_before" =~ ^[0-9]+$ ]]; then
    fail "smoke_order_not_terminal_or_ended_in_match_failed" "resting partial order missing numeric filled/remaining before takers snapshot=$(printf '%s' "$snapshot" | tr '\n' ' ')" || true
    return 1
  fi
  desired_before=$((filled_before + remaining_before))
  if [ "$status" = "match_failed" ]; then
    fail "smoke_order_not_terminal_or_ended_in_match_failed" "resting partial order ended in match_failed before takers" || true
    return 1
  fi

  CURRENT_TRADE_COUNT="$baseline_count"
  for i in $(seq 1 "$PARTIAL_TAKERS"); do
    next_nonce
    taker_id="smoke:partial:taker:${RUN_ID}:${i}:${NEXT_NONCE}"
    next_nonce
    taker_nonce="$NEXT_NONCE"
    append_order_id "$taker_id"

    build_order_payload "$taker_id" "$BUY_SUBACCOUNT_ID" "$taker_nonce" "buy" "$BUY_UI_PRICE" "$BUY_ATOMIC_PRICE" "$SMALL_UI_SIZE" "$SMALL_ATOMIC_SIZE"
    if ! taker_resp="$(submit_order_file "$TMP_DIR/${taker_id}.json")"; then
      return 1
    fi
    taker_oid="$(printf '%s' "$taker_resp" | jq -r '.order.order_id // empty')"
    if [ "$taker_oid" != "$taker_id" ]; then
      fail "api_http_error" "partial taker submit response missing expected order id for $taker_id" || true
      return 1
    fi

    if ! CURRENT_TRADE_COUNT="$(wait_for_trade_increment "$CURRENT_TRADE_COUNT" 1)"; then
      return 1
    fi
    if ! wait_for_terminal_status "$taker_id" "0"; then
      return 1
    fi
  done

  if ! snapshot="$(fetch_order_status "$resting_id")"; then
    return 1
  fi
  status="$(printf '%s' "$snapshot" | jq -r '.status')"
  filled="$(printf '%s' "$snapshot" | jq -r '.filled_amount')"
  remaining="$(printf '%s' "$snapshot" | jq -r '.remaining_amount')"

  expected_filled="$PARTIAL_TAKERS"
  expected_remaining="$((desired_before - PARTIAL_TAKERS))"

  if [ "$status" = "match_failed" ]; then
    fail "smoke_order_not_terminal_or_ended_in_match_failed" "resting partial order ended in match_failed after takers" || true
    return 1
  fi

  if [ "$filled" != "$expected_filled" ] || [ "$remaining" != "$expected_remaining" ]; then
    fail "smoke_order_not_terminal_or_ended_in_match_failed" "partial fill mismatch on resting order expected filled=$expected_filled remaining=$expected_remaining got filled=$filled remaining=$remaining status=$status" || true
    return 1
  fi

  if [ "$remaining" -gt 0 ]; then
    if ! cancel_order "$owner" "$resting_nonce" "smoke_partial_cleanup"; then
      return 1
    fi
    if ! wait_for_terminal_status "$resting_id" "$expected_remaining"; then
      return 1
    fi
  fi

  if ! assert_not_resting_on_book "$resting_id"; then
    return 1
  fi

  return 0
}

run_smoke_suite() {
  local before_count latest_trade expected_total_delta

  if ! preflight_cleanup_prefixed_orders 8; then
    return 1
  fi
  if ! determine_cross_prices; then
    return 1
  fi

  if ! before_count="$(fetch_trade_count)"; then
    return 1
  fi
  CURRENT_TRADE_COUNT="$before_count"

  if ! run_full_cross "baseline" "$CURRENT_TRADE_COUNT"; then
    return 1
  fi

  for i in $(seq 1 "$VOLUME_CROSSES"); do
    if ! run_full_cross "volume${i}" "$CURRENT_TRADE_COUNT"; then
      return 1
    fi
  done

  if ! run_partial_fill_scenario "$CURRENT_TRADE_COUNT"; then
    return 1
  fi

  if ! latest_trade="$(fetch_latest_trade)"; then
    return 1
  fi

  expected_total_delta=$((1 + VOLUME_CROSSES + PARTIAL_TAKERS))
  if [ "$CURRENT_TRADE_COUNT" -lt $((before_count + expected_total_delta)) ]; then
    fail "no_trade_count_increment" "total smoke trade_id delta below expectation expected >= $expected_total_delta got $((CURRENT_TRADE_COUNT - before_count))" || true
    return 1
  fi

  SMOKE_SUMMARY="smoke passed | order_count=${#ORDER_IDS[@]} | trade_id: $before_count -> $CURRENT_TRADE_COUNT | latest_trade=$(printf '%s' "$latest_trade" | jq -c .)"
  return 0
}

finalize_with_kpi() {
  local run_success="$1"
  local state cutoff metrics total success rate matching_metrics matching_total matching_success matching_rate effective_failure_class effective_failure_detail incident_active alert_scope

  state_store_init
  state="$(load_state)"

  state="$(printf '%s' "$state" | jq \
    --argjson ts "$NOW" \
    --arg run_id "$RUN_ID" \
    --argjson success "$run_success" \
    --arg failure_class "$FAILURE_CLASS" \
    --arg failure_detail "$FAILURE_DETAIL" \
    '.runs += [{ts:$ts,run_id:$run_id,success:$success,failure_class:$failure_class,failure_detail:$failure_detail}]')"

  cutoff=$((NOW - KPI_WINDOW_HOURS * 3600))
  state="$(printf '%s' "$state" | jq --argjson cutoff "$cutoff" '.runs |= map(select(.ts >= $cutoff))')"
  metrics="$(printf '%s' "$state" | jq '{total:(.runs|length),success:(.runs|map(select(.success==true))|length)}')"
  total="$(printf '%s' "$metrics" | jq -r '.total')"
  success="$(printf '%s' "$metrics" | jq -r '.success')"
  matching_metrics="$(printf '%s' "$state" | jq '{
    total: (.runs | map(select((.failure_class // "") != "api_dns_resolution" and (.failure_class // "") != "api_connectivity")) | length),
    success: (.runs | map(select((.failure_class // "") != "api_dns_resolution" and (.failure_class // "") != "api_connectivity" and .success == true)) | length)
  }')"
  matching_total="$(printf '%s' "$matching_metrics" | jq -r '.total')"
  matching_success="$(printf '%s' "$matching_metrics" | jq -r '.success')"

  if [ "$total" -eq 0 ]; then
    rate="100.00"
  else
    rate="$(awk -v s="$success" -v t="$total" 'BEGIN { printf "%.2f", (s/t)*100 }')"
  fi
  if [ "$matching_total" -eq 0 ]; then
    matching_rate="100.00"
  else
    matching_rate="$(awk -v s="$matching_success" -v t="$matching_total" 'BEGIN { printf "%.2f", (s/t)*100 }')"
  fi

  effective_failure_class="$FAILURE_CLASS"
  effective_failure_detail="$FAILURE_DETAIL"
  if [ -z "$effective_failure_class" ] && [ -s "$FAILURE_CLASS_FILE" ]; then
    effective_failure_class="$(cat "$FAILURE_CLASS_FILE")"
  fi
  if [ -z "$effective_failure_detail" ] && [ -s "$FAILURE_DETAIL_FILE" ]; then
    effective_failure_detail="$(cat "$FAILURE_DETAIL_FILE")"
  fi

  if awk -v r="$rate" -v min="$KPI_MIN_SUCCESS_RATE" 'BEGIN { exit !(r < min) }'; then
    if [ -z "$effective_failure_class" ]; then
      effective_failure_class="kpi_below_threshold"
      effective_failure_detail="success_rate=${rate}% threshold=${KPI_MIN_SUCCESS_RATE}% window_hours=${KPI_WINDOW_HOURS} runs=${total} successes=${success}"
    fi
  fi

  incident_active="$(printf '%s' "$state" | jq -r '.incident.active // false')"

  if [ -n "$effective_failure_class" ]; then
    alert_scope="exchange_matching"
    if is_infra_failure_class "$effective_failure_class"; then
      alert_scope="platform_network"
    fi
    if [ "$incident_active" != "true" ]; then
      state="$(printf '%s' "$state" | jq \
        --argjson ts "$NOW" \
        --arg class "$effective_failure_class" \
        --arg detail "$effective_failure_detail" \
        '.incident = {active:true,first_ts:$ts,class:$class,detail:$detail,last_seen_ts:$ts}')"
      save_state "$state"
      echo "ALERT first_failure class=$effective_failure_class"
      echo "alert_scope=$alert_scope"
      echo "detail: $effective_failure_detail"
      echo "kpi_success_rate: ${rate}% (${success}/${total}) over ${KPI_WINDOW_HOURS}h"
      echo "matching_path_kpi_success_rate: ${matching_rate}% (${matching_success}/${matching_total}) over ${KPI_WINDOW_HOURS}h"
      exit 1
    fi

    state="$(printf '%s' "$state" | jq --argjson ts "$NOW" '.incident.last_seen_ts = $ts')"
    save_state "$state"
    echo "suppressed_repeat_failure class=$effective_failure_class"
    echo "alert_scope=$alert_scope"
    echo "detail: $effective_failure_detail"
    echo "kpi_success_rate: ${rate}% (${success}/${total}) over ${KPI_WINDOW_HOURS}h"
    echo "matching_path_kpi_success_rate: ${matching_rate}% (${matching_success}/${matching_total}) over ${KPI_WINDOW_HOURS}h"
    exit 0
  fi

  if [ "$incident_active" = "true" ]; then
    echo "RECOVERED previous_failure_class=$(printf '%s' "$state" | jq -r '.incident.class // ""')"
  fi

  state="$(printf '%s' "$state" | jq '.incident = {active:false}')"
  save_state "$state"
  echo "$SMOKE_SUMMARY"
  if [ "$API_FAILOVER_USED" = "true" ]; then
    echo "api_base_failover: true primary=$API_BASE_PRIMARY backup=$API_BASE_BACKUP active=$API_BASE"
  fi
  echo "kpi_success_rate: ${rate}% (${success}/${total}) over ${KPI_WINDOW_HOURS}h"
  echo "matching_path_kpi_success_rate: ${matching_rate}% (${matching_success}/${matching_total}) over ${KPI_WINDOW_HOURS}h"
  exit 0
}

SMOKE_SUMMARY=""
determine_state_backend
if run_smoke_suite; then
  finalize_with_kpi true
else
  finalize_with_kpi false
fi
