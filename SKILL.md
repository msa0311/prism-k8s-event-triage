---
name: k8s-event-triage
description: >-
  React to Kubernetes Warning/error events in real time. A lightweight background
  watcher streams the cluster's event watch API and, when a Warning appears,
  schedules a one-shot "run now" triage task; the task reads the captured events
  and triages the ongoing issue (root cause, severity, suggested action). It does
  NOT use or change the agent's heartbeat. Follow this skill when a k8s-event-triage
  task fires, or when setting up / when the user asks to monitor, watch, or triage
  Kubernetes events, pod failures, crashloops, image-pull errors, scheduling
  failures, or cluster warnings.
---

# Kubernetes event triage

Real-time triage of Kubernetes `Warning` events — no webhooks, and **no heartbeat
involvement**. A background **watcher** streams Warning events off the Kubernetes
`watch` API, appends each to a logfile, and (debounced) **schedules a one-shot
"run now" triage task** through the runtime's cron API. When that task fires, the
agent — following Part A below — reads the captured events and triages the issue.
Because a task is created only when real events appear, there are no empty/"all
clear" runs to suppress.

```
kubectl watch (type=Warning) ──append──► /data/k8s-watcher/events.jsonl
        │ (debounced)                                  │ read when the task runs
        └─ POST /agents/cron-tasks  (run-now one-shot) ─► triage task ─► triage ─► user
```

## Paths & config (defaults)

- State dir: `/data/k8s-watcher` (persistent volume; survives restarts)
- Events file: `/data/k8s-watcher/events.jsonl`
- Watcher script (stable copy): `/data/k8s-watcher/k8s-event-watcher.sh`
- Cron API: `http://localhost:3003/agents/cron-tasks`

---

## Part A — When a `k8s-event-triage` task fires, do this

The watcher schedules a one-shot task whose instruction points here. On that run:

### 1. Read the new events (atomic rotate — no growth, no races)

The watcher appends with a fresh open each time, so renaming the file is race-free:

```bash
if [ -s /data/k8s-watcher/events.jsonl ]; then
  mv /data/k8s-watcher/events.jsonl /data/k8s-watcher/events.consuming
  cat /data/k8s-watcher/events.consuming
fi
```

New events now flow into a fresh `events.jsonl`; `events.consuming` is yours to
process. Each line is one event: `{ts, ns, kind, name, reason, type, count, message, uid}`.
When done, `rm -f /data/k8s-watcher/events.consuming`. **If the file was empty
(nothing to triage), reply with nothing** — the task makes no report.

### 2. Triage and report

**Read `references/triage-runbook.md` and follow it** — it has the full triage method,
a severity rubric, a per-symptom playbook (CrashLoopBackOff, ImagePullBackOff, OOMKilled,
FailedScheduling, FailedMount, probe Unhealthy, FailedCreate/quota, node pressure, HPA
metric failures, …) with the exact diagnostic commands, likely causes, remediations, the
output format, and safety rules. Essentials:

- **Group** related events (same `involvedObject` / `reason`); triage the owning workload
  (Pod → ReplicaSet → Deployment/Job/StatefulSet), not each raw line.
- **Scope the blast radius** (one pod vs. whole workload vs. node vs. cluster) — it drives
  severity more than the event count.
- **Gather evidence** with `kubectl`: `describe` the object, current + `--previous` logs,
  the object's recent events, `kubectl top` for resource pressure, node conditions.
- **Report** per the runbook's format: what/where, severity, root-cause hypothesis (with
  confidence + evidence), suggested immediate + durable fix, and what to watch.
- **Safety:** default to read-only. Never run mutating commands (`delete`, `scale`,
  `rollout restart`, `edit`, `apply`, `drain`, `patch`) without **explicit user
  confirmation** — propose the exact command instead.

---

## Part B — The watcher (capture + schedule triage)

The watcher (`scripts/k8s-event-watcher.sh`) streams `Warning` events, appends them to
the logfile, and — debounced (default 15s) — POSTs a one-shot triage task to the cron API
(`{name, schedule:"in 1 second", instruction}`). A burst of events collapses into a single
triage run; the task drains *all* accumulated lines when it fires.

**(Re)start it via the `shell_spawn` tool** (NOT `shell_exec` — it must outlive the turn).
First copy the script to the stable state-dir path so it doesn't depend on where the skill
is installed:

```bash
mkdir -p /data/k8s-watcher
cp "<this-skill-dir>/scripts/k8s-event-watcher.sh" /data/k8s-watcher/k8s-event-watcher.sh
chmod +x /data/k8s-watcher/k8s-event-watcher.sh
```

Then `shell_spawn`:
```
bash /data/k8s-watcher/k8s-event-watcher.sh
```

The watcher runs a **preflight** and exits immediately with a clear message if `kubectl`
can't reach the cluster. If it reports `localhost:8080` refused, `kubectl` has no
kubeconfig in the spawned process's context (a spawned process doesn't inherit an
interactive shell's un-exported `KUBECONFIG` or `kubectl` aliases) — spawn it with an
explicit path: `K8S_WATCHER_KUBECONFIG=/path/to/kubeconfig bash …/k8s-event-watcher.sh`.

Check whether it's already running: `pgrep -f k8s-event-watcher`. `<this-skill-dir>` is
where this `SKILL.md` was loaded from (`find / -name k8s-event-watcher.sh 2>/dev/null | head -1`).

---

## Setup (one-time)

1. **Install the skill:** `npx skills add github:lensapp/prism-k8s-event-triage -g -a claude-code --copy`,
   or drop this bundle into `<DATA>/skills/`.
2. **Verify cluster access:** `kubectl get events -A --request-timeout=5s`. If it fails, the
   kubeconfig is missing/invalid — report that and stop (don't spawn a blind watcher).
3. **Spawn the watcher** (Part B). From then on, every Warning event schedules a triage task.

> **This skill does not use or change the agent's heartbeat.** Triage runs on dedicated
> one-shot cron tasks the watcher schedules on demand — not on the heartbeat, and not on a
> fixed poll.

**Keeping the watcher alive across restarts.** A `shell_spawn` watcher dies if the container
restarts, and a dead watcher can't schedule its own resurrection. Pick one:
- **Recurring keep-alive task** — a low-frequency cron task (e.g. `every 10 minutes`) whose
  instruction is *"if `pgrep -f k8s-event-watcher` finds nothing, re-spawn the watcher via
  shell_spawn; otherwise reply with nothing."* (Silent-when-healthy relies on the runtime
  skipping empty cron output.)
- **Heartbeat watchdog** — if you already run a heartbeat, add one line to `heartbeatMd`:
  *"ensure the k8s-event-watcher is running; re-spawn it if not."* Its DELIVER/SUPPRESS gate
  keeps the healthy case silent. (This is supervision only — triage still runs off the tasks.)
- **In-cluster Deployment** — run the watcher as a k8s `Deployment` so the cluster restarts
  it; fully decoupled from the agent lifecycle (heaviest, most durable).

## Notes & limits

- **One-shot tasks auto-delete** after running, so they don't accumulate.
- **Debounce** (default 15s) coalesces event storms into one triage run; no event is dropped
  because the task drains all accumulated lines.
- **No heartbeat coupling and no empty runs:** a task is created only when events appear, so
  there's nothing to suppress.
- The cron API is reached at `localhost:3003` (same-host runtime); requires that loopback is
  reachable from where the watcher runs.
