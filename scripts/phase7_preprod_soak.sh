#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KASSADIN_BIN="${KASSADIN_BIN:-$ROOT_DIR/zig-out/bin/kassadin}"
NETWORK="${NETWORK:-preprod}"
DB_PATH="${DB_PATH:-$ROOT_DIR/db/preprod}"
DURATION_SECONDS="${DURATION_SECONDS:-86400}"
HEADERS_PER_ITERATION="${HEADERS_PER_ITERATION:-100}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"
DOLOS_GRPC="${DOLOS_GRPC:-127.0.0.1:50051}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs/phase7_soak}"

mkdir -p "$LOG_DIR"

if [[ ! -x "$KASSADIN_BIN" ]]; then
  echo "missing kassadin binary at $KASSADIN_BIN" >&2
  echo "build it first with: zig build" >&2
  exit 1
fi

SUMMARY_CSV="$LOG_DIR/summary.csv"
if [[ ! -f "$SUMMARY_CSV" ]]; then
  echo "timestamp,iteration,kassadin_tip_slot,kassadin_tip_block,dolos_tip_slot,dolos_tip_block,slot_delta,max_rss_kb,invalid_blocks,rollbacks,stopped_by_signal,status" > "$SUMMARY_CSV"
fi

end_epoch=$(( $(date +%s) + DURATION_SECONDS ))
iteration=0

parse_value() {
  local label="$1"
  local file="$2"
  awk -F': ' -v key="$label" '$1 == key { print $2; exit }' "$file"
}

while (( $(date +%s) < end_epoch )); do
  iteration=$((iteration + 1))
  timestamp="$(date -Iseconds)"
  sync_log="$LOG_DIR/sync_${iteration}.log"
  dolos_log="$LOG_DIR/dolos_${iteration}.log"

  echo "[$timestamp] iteration $iteration: running Kassadin sync batch..."

  if ! /usr/bin/time -f 'MAX_RSS_KB=%M' -o "$sync_log.time" \
    "$KASSADIN_BIN" sync \
      --network "$NETWORK" \
      --db-path "$DB_PATH" \
      --max-headers "$HEADERS_PER_ITERATION" \
      >"$sync_log" 2>&1; then
    echo "[$timestamp] iteration $iteration: kassadin sync failed" >&2
    echo "$timestamp,$iteration,,,,,,,,$(parse_value '  Invalid blocks' "$sync_log" || true),,$(parse_value '  Stopped by signal' "$sync_log" || true),sync_failed" >> "$SUMMARY_CSV"
    exit 1
  fi

  kassadin_tip_slot="$(parse_value '  Tip slot' "$sync_log")"
  kassadin_tip_block="$(parse_value '  Tip block' "$sync_log")"
  invalid_blocks="$(parse_value '  Invalid blocks' "$sync_log")"
  rollbacks="$(parse_value '  Rollbacks' "$sync_log")"
  stopped_by_signal="$(parse_value '  Stopped by signal' "$sync_log")"
  max_rss_kb="$(awk -F= '/^MAX_RSS_KB=/{print $2; exit}' "$sync_log.time")"

  dolos_tip_slot=""
  dolos_tip_block=""
  slot_delta=""
  status="ok"

  if "$KASSADIN_BIN" dolos-tip --dolos-grpc "$DOLOS_GRPC" >"$dolos_log" 2>&1; then
    dolos_tip_slot="$(parse_value '  Slot' "$dolos_log")"
    dolos_tip_block="$(parse_value '  Height' "$dolos_log")"
    if [[ -n "$kassadin_tip_slot" && -n "$dolos_tip_slot" ]]; then
      slot_delta=$(( dolos_tip_slot - kassadin_tip_slot ))
      if (( slot_delta < 0 )); then
        slot_delta=$(( -slot_delta ))
      fi
      if (( slot_delta > 2160 )); then
        status="tip_drift_exceeded"
      fi
    fi
  else
    status="dolos_unavailable"
  fi

  echo "$timestamp,$iteration,$kassadin_tip_slot,$kassadin_tip_block,$dolos_tip_slot,$dolos_tip_block,$slot_delta,$max_rss_kb,$invalid_blocks,$rollbacks,$stopped_by_signal,$status" >> "$SUMMARY_CSV"

  if [[ "$status" == "tip_drift_exceeded" ]]; then
    echo "[$timestamp] iteration $iteration: tip drift exceeded 2160 slots" >&2
    exit 1
  fi

  sleep "$SLEEP_SECONDS"
done

echo "phase 7 soak complete; summary written to $SUMMARY_CSV"
