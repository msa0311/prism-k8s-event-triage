#!/usr/bin/env bash
#
# k8s-event-watcher — streams Kubernetes Warning events off the watch API and,
# when new events appear, schedules a one-shot "run now" triage task via the
# agent-runtime's cron API. The task (driven by the k8s-event-triage skill) then
# reads the captured events and triages the ongoing issue.
#
# Designed to run as a long-lived background process started by the agent via
# the `shell_spawn` tool. Dependency-light: bash + kubectl + jq + curl.
#
# Behavior:
#   - Watches `kubectl get events -A --watch-only --field-selector type=Warning`
#     (--watch-only skips the initial dump so a reconnect doesn't re-flood).
#   - Appends one compact JSON record per event to $STATE_DIR/events.jsonl.
#   - Debounced: schedules at most one triage task per $DEBOUNCE_SECONDS, so a
#     burst of events collapses into a single triage run. No event is lost — the
#     triage task drains ALL accumulated lines when it runs.
#   - Self-healing watch stream: reconnects if the connection drops.
#   - Writes a pidfile and touches an alive marker for supervision.
#
# Config via env (all optional):
#   K8S_WATCHER_STATE_DIR       default /data/k8s-watcher     (persistent volume)
#   K8S_WATCHER_CRON_URL        default http://localhost:3003/agents/cron-tasks
#   K8S_WATCHER_DEBOUNCE_SECONDS default 15
#   K8S_WATCHER_NAMESPACE       default "" (all namespaces; set to scope to one)
#   K8S_WATCHER_TASK_NAME       default k8s-event-triage
#
set -uo pipefail

STATE_DIR="${K8S_WATCHER_STATE_DIR:-/data/k8s-watcher}"
CRON_URL="${K8S_WATCHER_CRON_URL:-http://localhost:3003/agents/cron-tasks}"
DEBOUNCE_SECONDS="${K8S_WATCHER_DEBOUNCE_SECONDS:-15}"
NAMESPACE="${K8S_WATCHER_NAMESPACE:-}"
TASK_NAME="${K8S_WATCHER_TASK_NAME:-k8s-event-triage}"

EVENTS_FILE="$STATE_DIR/events.jsonl"
PID_FILE="$STATE_DIR/watcher.pid"
ALIVE_FILE="$STATE_DIR/watcher.alive"
LOG_PREFIX="[k8s-event-watcher]"

# The instruction the one-shot triage task runs. It points the agent at the
# skill + logfile; the skill's runbook carries the detailed triage method.
read -r -d '' TRIAGE_INSTRUCTION <<'EOF' || true
Kubernetes Warning events were captured by the k8s event watcher. Triage them now
by following the "k8s-event-triage" skill: rotate and read
/data/k8s-watcher/events.jsonl, group and debounce the warnings, and diagnose the
ongoing cluster issue using the skill's triage runbook (describe / logs / events /
node conditions). Report what is failing, where (namespace/object), severity, the
likely root cause with evidence, and the suggested action. Stay read-only — never
run mutating kubectl commands without explicit user confirmation. If, after reading,
there is nothing new or actionable, reply with nothing.
EOF

mkdir -p "$STATE_DIR"
echo "$$" > "$PID_FILE"
touch "$ALIVE_FILE"

# Kubeconfig. A spawned/background process does NOT inherit an interactive
# shell's un-exported KUBECONFIG or kubectl aliases — the usual cause of
# "connection to the server localhost:8080 was refused". Pin it explicitly when
# provided; otherwise rely on the exported KUBECONFIG / default in the env.
if [[ -n "${K8S_WATCHER_KUBECONFIG:-}" ]]; then
  export KUBECONFIG="$K8S_WATCHER_KUBECONFIG"
fi

# Preflight: fail fast (don't loop) if kubectl can't reach the cluster.
if ! kubectl get events -A --request-timeout=5s >/dev/null 2>"$STATE_DIR/preflight.err"; then
  echo "$LOG_PREFIX FATAL: kubectl cannot reach the cluster:" >&2
  tail -n 2 "$STATE_DIR/preflight.err" | sed "s/^/$LOG_PREFIX   /" >&2
  echo "$LOG_PREFIX   Point the watcher at a kubeconfig: K8S_WATCHER_KUBECONFIG=/path/to/kubeconfig" >&2
  echo "$LOG_PREFIX   (a spawned process does not inherit an interactive shell's un-exported KUBECONFIG or kubectl aliases)" >&2
  exit 1
fi
echo "$LOG_PREFIX preflight OK — cluster reachable" >&2

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

last_task=0

schedule_triage() {
  local now
  now="$(date +%s)"
  if (( now - last_task < DEBOUNCE_SECONDS )); then
    return
  fi
  last_task="$now"
  # Build the JSON body safely with jq, then POST a run-now one-shot task.
  local payload code
  payload="$(jq -n \
    --arg name "$TASK_NAME" \
    --arg schedule "in 1 second" \
    --arg instruction "$TRIAGE_INSTRUCTION" \
    '{name: $name, schedule: $schedule, instruction: $instruction}')"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$CRON_URL" \
    -H 'Content-Type: application/json' \
    -d "$payload" --max-time 10 2>/dev/null || echo 000)"
  echo "$LOG_PREFIX scheduled triage task (http $code)" >&2
}

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

echo "$LOG_PREFIX starting (state=$STATE_DIR cron=$CRON_URL debounce=${DEBOUNCE_SECONDS}s ns=${NAMESPACE:-ALL})" >&2

# Outer loop reconnects the watch stream if it ends or errors.
backoff=2
while true; do
  : > "$STATE_DIR/watcher.err"          # reset so its tail shows only the latest attempt
  stream_start="$(date +%s)"
  # Process substitution keeps the read loop in the main shell so $last_task
  # persists across events within a connection.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '%s\n' "$line" >> "$EVENTS_FILE"
    touch "$ALIVE_FILE"
    schedule_triage
  done < <(
    kubectl get events "${SCOPE_ARGS[@]}" \
      --watch-only \
      --field-selector type=Warning \
      -o json 2>>"$STATE_DIR/watcher.err" \
      | jq -c --unbuffered "$JQ_FILTER" 2>>"$STATE_DIR/watcher.err"
  )

  # Surface why the stream ended — kubectl/jq errors are captured in watcher.err.
  if [[ -s "$STATE_DIR/watcher.err" ]]; then
    tail -n 3 "$STATE_DIR/watcher.err" | sed "s/^/$LOG_PREFIX err: /" >&2
  fi
  # Fast-fail backoff: a watch that dies almost immediately is misconfigured
  # (bad selector, auth, or the stream not surviving the proxy) — don't hammer.
  elapsed=$(( $(date +%s) - stream_start ))
  if (( elapsed < 5 )); then
    (( backoff = backoff < 30 ? backoff + 5 : 30 ))
  else
    backoff=2
  fi
  echo "$LOG_PREFIX watch stream ended after ${elapsed}s; reconnecting in ${backoff}s (see $STATE_DIR/watcher.err)" >&2
  sleep "$backoff"
done
