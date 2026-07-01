#!/usr/bin/env bash
#
# k8s-event-watcher — streams Kubernetes Warning events off the watch API and,
# when events have actually been captured, schedules a one-shot "run now" triage
# task via the agent-runtime's cron API, handing that task its own batch file.
# The task (driven by the k8s-event-triage skill) reads the batch and triages it.
#
# Designed to run as a long-lived background process started by the agent via
# the `shell_spawn` tool. Dependency-light: bash + kubectl + jq + curl.
#
# Two concurrent loops:
#   - capture: `kubectl … --watch-only` streams Warning events; each is appended
#     to $STATE_DIR/events.jsonl. This loop NEVER schedules tasks.
#   - flusher: every $FLUSH_SECONDS, if events.jsonl is NON-EMPTY, it is renamed
#     (atomically) to a unique batch file and ONE triage task is scheduled for
#     that batch. Non-empty check ⇒ no task is ever scheduled for an empty file;
#     unique batch file ⇒ no two tasks race over shared state; timer-based ⇒ the
#     tail of a burst is never stranded.
#
# Config via env (all optional):
#   K8S_WATCHER_STATE_DIR       default /data/k8s-watcher     (persistent volume)
#   K8S_WATCHER_CRON_URL        default http://localhost:3003/agents/cron-tasks
#   K8S_WATCHER_FLUSH_SECONDS   default 15   (batch window; coalesces event storms)
#   K8S_WATCHER_NAMESPACE       default "" (all namespaces; set to scope to one)
#   K8S_WATCHER_TASK_NAME       default k8s-event-triage
#   K8S_WATCHER_KUBECONFIG      default "" (else ambient KUBECONFIG / default)
#   K8S_WATCHER_COOLDOWN_SECONDS default 21600 (6h) — per-issue dedup window. An
#                               issue is keyed by ns/kind/name/reason. A repeat
#                               within the cooldown is SUPPRESSED (not captured),
#                               which stops CrashLoopBackOff-style events — whose
#                               .count ticks up every ~minute — from generating
#                               one identical triage per minute. First occurrence
#                               is always captured; after the cooldown expires one
#                               refresh triage is allowed.
#
set -uo pipefail

STATE_DIR="${K8S_WATCHER_STATE_DIR:-/data/k8s-watcher}"
CRON_URL="${K8S_WATCHER_CRON_URL:-http://localhost:3003/agents/cron-tasks}"
FLUSH_SECONDS="${K8S_WATCHER_FLUSH_SECONDS:-${K8S_WATCHER_DEBOUNCE_SECONDS:-15}}"
NAMESPACE="${K8S_WATCHER_NAMESPACE:-}"
TASK_NAME="${K8S_WATCHER_TASK_NAME:-k8s-event-triage}"
# One-shot schedule for the triage task. Default "in 1 minute" — the smallest the
# runtime accepts as deployed (its schedule parser rejects sub-minute one-shots with
# HTTP 400). After the runtime is redeployed to a build whose parseSchedule supports
# seconds, set K8S_WATCHER_SCHEDULE="in 1 second" (≈instant) or "in 0 seconds".
SCHEDULE="${K8S_WATCHER_SCHEDULE:-in 1 minute}"
COOLDOWN_SECONDS="${K8S_WATCHER_COOLDOWN_SECONDS:-21600}"
# Optional: pin the Lens cluster specifier for lens:// deep links. Set this when the
# agent reaches the cluster via a tunnel (its kubeconfig server URL differs from the
# user's local Lens, so a computed hash would not match). Value = sha256(<the server
# URL the user's Lens uses>)[:32]. Passed through to the triage task's instruction.
LENS_CLUSTER_SPECIFIER="${LENS_CLUSTER_SPECIFIER:-}"
LENS_CONNECTION_TYPE="${LENS_CONNECTION_TYPE:-direct}"

EVENTS_FILE="$STATE_DIR/events.jsonl"
PID_FILE="$STATE_DIR/watcher.pid"
ALIVE_FILE="$STATE_DIR/watcher.alive"
SEEN_FILE="$STATE_DIR/seen.tsv"   # per-issue dedup: <epoch>TAB<key> lines
LOG_PREFIX="[k8s-event-watcher]"

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
  exit 1
fi
echo "$LOG_PREFIX preflight OK — cluster reachable" >&2

if [[ -n "$NAMESPACE" ]]; then
  SCOPE_ARGS=(--namespace "$NAMESPACE")
else
  SCOPE_ARGS=(--all-namespaces)
fi

FLUSHER_PID=""
cleanup() {
  [[ -n "$FLUSHER_PID" ]] && kill "$FLUSHER_PID" 2>/dev/null
  rm -f "$PID_FILE"
  echo "$LOG_PREFIX exiting" >&2
}
trap cleanup EXIT INT TERM

# Schedule ONE run-now triage task for a specific, non-empty batch file.
schedule_triage_for() {
  local batch="$1"
  local instruction payload code lens_hint=""
  if [[ -n "$LENS_CLUSTER_SPECIFIER" ]]; then
    lens_hint=" Also add a lens:// deep link per cited resource (per the skill's 'Deep links' section), using connectionType=${LENS_CONNECTION_TYPE} and clusterSpecifier=${LENS_CLUSTER_SPECIFIER} EXACTLY — do NOT compute the specifier from kubectl (this cluster is reached via a tunnel, so its kubeconfig server URL differs from the user's Lens)."
  else
    lens_hint=" Do NOT add lens:// deep links — no cluster specifier is configured, and a computed one would not match the user's Lens."
  fi
  instruction="Kubernetes Warning events were captured by the k8s event watcher and saved to ${batch}. Triage them now by following the \"k8s-event-triage\" skill: read ${batch}, group and debounce the warnings, and diagnose the ongoing cluster issue using the skill's triage runbook (describe / logs / events / node conditions). Report what is failing, where (namespace/object), severity, the likely root cause with evidence, and the suggested action. Stay read-only — never run mutating kubectl commands without explicit user confirmation. When done, delete ${batch}.${lens_hint}"
  # Schedule from $SCHEDULE (default "in 1 minute"). The deployed runtime rejects
  # sub-minute one-shots (HTTP 400); a build with seconds support accepts
  # "in 1 second"/"in 0 seconds" — set K8S_WATCHER_SCHEDULE then.
  payload="$(jq -n \
    --arg name "$TASK_NAME" \
    --arg schedule "$SCHEDULE" \
    --arg instruction "$instruction" \
    '{name: $name, schedule: $schedule, instruction: $instruction}')"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$CRON_URL" \
    -H 'Content-Type: application/json' \
    -d "$payload" --max-time 10 2>/dev/null || echo 000)"
  echo "$LOG_PREFIX scheduled triage for $(basename "$batch") (http $code)" >&2
}

# Flusher loop: batch captured events and schedule triage ONLY when there's content.
flusher() {
  local batch
  while true; do
    sleep "$FLUSH_SECONDS"
    [[ -s "$EVENTS_FILE" ]] || continue          # nothing captured → no task
    batch="$STATE_DIR/batch-$(date +%s%N).jsonl"
    mv "$EVENTS_FILE" "$batch" 2>/dev/null || continue   # atomic; new events go to a fresh file
    [[ -s "$batch" ]] || { rm -f "$batch"; continue; }   # defensive
    schedule_triage_for "$batch"
  done
}

# Per-issue dedup. Returns 0 (capture) if this issue key has NOT been triaged
# within COOLDOWN_SECONDS; else 1 (suppress). On capture it records the key with
# the current timestamp so subsequent .count ticks of the same event are dropped.
# Key = ns/kind/name/reason — the identity of an ongoing problem, independent of
# the ever-incrementing event .count. SEEN_FILE is pruned of expired keys so it
# cannot grow unbounded.
should_capture() {
  local key="$1" now entry last
  now="$(date +%s)"
  if [[ -f "$SEEN_FILE" ]]; then
    last="$(awk -F"\t" -v k="$key" '$2==k{print $1}' "$SEEN_FILE" | tail -n1)"
    if [[ -n "$last" ]] && (( now - last < COOLDOWN_SECONDS )); then
      return 1   # still in cooldown → suppress
    fi
  fi
  # Record/refresh this key: drop any old line for it, prune expired, append fresh.
  local tmp="$SEEN_FILE.tmp.$$"
  if [[ -f "$SEEN_FILE" ]]; then
    awk -F"\t" -v k="$key" -v now="$now" -v cd="$COOLDOWN_SECONDS" \
      '$2!=k && (now-$1)<cd' "$SEEN_FILE" > "$tmp" 2>/dev/null || : > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\n' "$now" "$key" >> "$tmp"
  mv "$tmp" "$SEEN_FILE"
  return 0   # capture
}

flusher &
FLUSHER_PID=$!

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

echo "$LOG_PREFIX starting (state=$STATE_DIR cron=$CRON_URL flush=${FLUSH_SECONDS}s ns=${NAMESPACE:-ALL})" >&2

# Capture loop — append events only; scheduling is the flusher's job. Reconnects
# the watch stream if it ends or errors.
backoff=2
while true; do
  : > "$STATE_DIR/watcher.err"          # reset so its tail shows only the latest attempt
  stream_start="$(date +%s)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    touch "$ALIVE_FILE"   # liveness: we are receiving stream data, captured or not
    # Build the per-issue dedup key and suppress repeats within the cooldown so a
    # single ongoing problem is triaged once, not once per event .count tick.
    key="$(printf '%s' "$line" | jq -r '[(.ns//"-"),(.kind//"-"),(.name//"-"),(.reason//"-")]|join("/")' 2>/dev/null)"
    if [[ -z "$key" ]]; then
      printf '%s\n' "$line" >> "$EVENTS_FILE"   # unparseable → do not silently drop
    elif should_capture "$key"; then
      printf '%s\n' "$line" >> "$EVENTS_FILE"
    else
      echo "$LOG_PREFIX suppressed (cooldown): $key" >&2
    fi
  done < <(
    kubectl get events "${SCOPE_ARGS[@]}" \
      --watch-only \
      --field-selector type=Warning \
      -o json 2>>"$STATE_DIR/watcher.err" \
      | jq -c --unbuffered "$JQ_FILTER" 2>>"$STATE_DIR/watcher.err"
  )

  if [[ -s "$STATE_DIR/watcher.err" ]]; then
    tail -n 3 "$STATE_DIR/watcher.err" | sed "s/^/$LOG_PREFIX err: /" >&2
  fi
  elapsed=$(( $(date +%s) - stream_start ))
  if (( elapsed < 5 )); then
    (( backoff = backoff < 30 ? backoff + 5 : 30 ))
  else
    backoff=2
  fi
  echo "$LOG_PREFIX watch stream ended after ${elapsed}s; reconnecting in ${backoff}s (see $STATE_DIR/watcher.err)" >&2
  sleep "$backoff"
done
