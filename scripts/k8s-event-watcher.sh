#!/usr/bin/env bash
#
# k8s-event-watcher — streams Kubernetes Warning events off the watch API and
# pokes the prism-agent heartbeat so the agent triages them immediately.
#
# Designed to run as a long-lived background process started by the agent via
# the `shell_spawn` tool. It is intentionally dependency-light: bash + kubectl +
# jq + curl (all present in the agent-runtime container).
#
# Behavior:
#   - Watches `kubectl get events -A --watch-only --field-selector type=Warning`
#     (--watch-only skips the initial dump so a reconnect doesn't re-flood).
#   - Appends one compact JSON record per event to $STATE_DIR/events.jsonl.
#   - Debounced: POSTs the heartbeat trigger at most once per $DEBOUNCE_SECONDS,
#     coalescing event bursts. A coalesced poke never loses an event — the
#     heartbeat reads ALL new lines in events.jsonl each run.
#   - Self-healing stream: if the watch connection drops, it reconnects.
#   - Writes a pidfile and touches an alive marker for observability.
#
# Config via env (all optional):
#   K8S_WATCHER_STATE_DIR       default /data/k8s-watcher   (persistent volume)
#   K8S_WATCHER_TRIGGER_URL     default http://localhost:3003/agents/heartbeat/trigger
#   K8S_WATCHER_DEBOUNCE_SECONDS default 20
#   K8S_WATCHER_NAMESPACE       default "" (all namespaces; set to scope to one)
#
set -uo pipefail

STATE_DIR="${K8S_WATCHER_STATE_DIR:-/data/k8s-watcher}"
TRIGGER_URL="${K8S_WATCHER_TRIGGER_URL:-http://localhost:3003/agents/heartbeat/trigger}"
DEBOUNCE_SECONDS="${K8S_WATCHER_DEBOUNCE_SECONDS:-20}"
NAMESPACE="${K8S_WATCHER_NAMESPACE:-}"

EVENTS_FILE="$STATE_DIR/events.jsonl"
PID_FILE="$STATE_DIR/watcher.pid"
ALIVE_FILE="$STATE_DIR/watcher.alive"
LOG_PREFIX="[k8s-event-watcher]"

mkdir -p "$STATE_DIR"
echo "$$" > "$PID_FILE"
touch "$ALIVE_FILE"

# Scope: all namespaces unless one is pinned.
if [[ -n "$NAMESPACE" ]]; then
  SCOPE_ARGS=(--namespace "$NAMESPACE")
else
  SCOPE_ARGS=(--all-namespaces)
fi

cleanup() {
  rm -f "$PID_FILE"
  echo "$LOG_PREFIX exiting" >&2
}
trap cleanup EXIT INT TERM

last_trigger=0

poke_heartbeat() {
  local now
  now="$(date +%s)"
  if (( now - last_trigger >= DEBOUNCE_SECONDS )); then
    last_trigger="$now"
    # Fire-and-forget; never let a failed poke kill the watcher.
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$TRIGGER_URL" --max-time 10 2>/dev/null || echo 000)"
    echo "$LOG_PREFIX poked heartbeat (http $code)" >&2
  fi
}

# jq transform: emit one compact line per event with the fields triage needs.
# Field fallbacks cover both core/v1 and slight schema variations.
JQ_FILTER='{
  ts: (.lastTimestamp // .eventTime // .firstTimestamp // .metadata.creationTimestamp),
  ns: .involvedObject.namespace,
  kind: .involvedObject.kind,
  name: .involvedObject.name,
  reason: .reason,
  type: .type,
  count: .count,
  message: .message,
  uid: .metadata.uid
}'

echo "$LOG_PREFIX starting (state=$STATE_DIR trigger=$TRIGGER_URL debounce=${DEBOUNCE_SECONDS}s ns=${NAMESPACE:-ALL})" >&2

# Outer loop reconnects the watch stream if it ends or errors.
while true; do
  # Process substitution keeps the read loop in the main shell so $last_trigger
  # persists across events within a connection.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '%s\n' "$line" >> "$EVENTS_FILE"
    touch "$ALIVE_FILE"
    poke_heartbeat
  done < <(
    kubectl get events "${SCOPE_ARGS[@]}" \
      --watch-only \
      --field-selector type=Warning \
      -o json 2>>"$STATE_DIR/watcher.err" \
      | jq -c --unbuffered "$JQ_FILTER" 2>>"$STATE_DIR/watcher.err"
  )

  echo "$LOG_PREFIX watch stream ended; reconnecting in 2s" >&2
  sleep 2
done
