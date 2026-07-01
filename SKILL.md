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
`watch` API and appends them to a logfile. Every ~15s a flusher checks the logfile: if
(and only if) it has content, it renames it to a unique **batch file** and **schedules a
one-shot "run now" triage task** for that batch through the runtime's cron API. When the
task fires, the agent — following Part A — reads its batch and triages it.

A task is scheduled **only when real events were captured**, and each task gets **its own
batch file** — so there are no empty/"all clear" runs (nothing for the runtime to suppress)
and no two tasks race over shared state.

```
kubectl watch (type=Warning) ──append──► events.jsonl
                                             │  flush every ~15s, ONLY if non-empty
                                             ▼  (atomic rename)
                                         batch-<ts>.jsonl ──► POST /agents/cron-tasks
                                                              (run-now one-shot) ──► triage task ──► triage ──► user
```

## Paths & config (defaults)

- State dir: `/data/k8s-watcher` (persistent volume; survives restarts)
- Events file: `/data/k8s-watcher/events.jsonl`
- Watcher script (stable copy): `/data/k8s-watcher/k8s-event-watcher.sh`
- Cron API: `http://localhost:3003/agents/cron-tasks`

---

## Part A — When a `k8s-event-triage` task fires, do this

The watcher schedules a one-shot task whose instruction points here. On that run:

### 1. Read your batch file

Your triage task's instruction names a **batch file** under `/data/k8s-watcher/`
(e.g. `/data/k8s-watcher/batch-<ts>.jsonl`). Read that exact path:

```bash
cat /data/k8s-watcher/batch-<ts>.jsonl   # exact path is in your instruction
```

Each line is one event: `{ts, ns, kind, name, reason, type, count, message, uid}`. The
watcher only schedules a task when the batch is non-empty, so you always have real events
to triage — no need to guard for an empty file. When done, `rm -f` the batch file.

### 2. Triage via Claude Code

Delegate the investigation to the **`claude_code`** tool — it runs in this workspace with
the same `kubectl`/kubeconfig and can load this skill's runbook, and it's a far stronger
multi-step investigator than a single inline turn. Use **`mode: "plan"`** (analyze, don't
edit):

```
claude_code({
  mode: "plan",
  prompt: "Triage a Kubernetes incident. The captured Warning events are in <BATCH FILE>.
    Read them, then follow the k8s-event-triage skill's references/triage-runbook.md:
    group related events, scope the blast radius, and investigate the root cause with
    READ-ONLY kubectl (describe / logs --previous / get events / top / node conditions).
    Do NOT run any mutating command (delete/scale/rollout/edit/apply/drain/patch).
    Return a concise report: what is failing, where (namespace/object), severity, the
    root-cause hypothesis with evidence, and the suggested fix (as a command to PROPOSE,
    not run). If (and only if) your instruction provides a cluster specifier, add a lens://
    deep link per cited resource using it exactly (runbook's 'Deep links' section); if no
    specifier was provided, do NOT add lens:// links."
})
```

Substitute the batch path from your instruction for `<BATCH FILE>`. Then poll
`claude_code_status({ taskId })` until `completed` and **deliver its `result`** as the
triage report. Keep the read-only rule in the prompt even though plan mode blocks file
edits — plan mode does not by itself block mutating shell/`kubectl` commands.

The full method, severity rubric, and per-symptom playbook (CrashLoopBackOff,
ImagePullBackOff, OOMKilled, FailedScheduling, FailedMount, probe Unhealthy,
FailedCreate/quota, node pressure, HPA metric failures, …) live in
`references/triage-runbook.md` — that's what Claude Code follows.

---

## Part B — The watcher (capture + schedule triage)

The watcher (`scripts/k8s-event-watcher.sh`) streams `Warning` events, appends them to
the logfile, and — debounced (default 15s) — POSTs a one-shot triage task to the cron API
(`{name, schedule:"in 1 minute", instruction}` — the runtime rejects sub-minute one-shots,
so triage fires within ~1 min of a batch). A burst of events collapses into a single
triage run; the task drains *all* accumulated lines when it fires.

**(Re)start it via the `shell_spawn` tool** (NOT `shell_exec` — it must outlive the turn).
First copy the script to the stable state-dir path so it doesn't depend on where the skill
is installed:

```bash
mkdir -p /data/k8s-watcher
cp "<this-skill-dir>/scripts/k8s-event-watcher.sh" /data/k8s-watcher/k8s-event-watcher.sh
chmod +x /data/k8s-watcher/k8s-event-watcher.sh
```

**Locate the kubeconfig first — do not rely on ambient env.** A spawned process doesn't
inherit an interactive shell's un-exported `KUBECONFIG` or `kubectl` aliases, and in some
sandboxes the kubeconfig is a runtime-written file not wired into the container env — so
bare `kubectl` falls back to `localhost:8080`. Find the real path and pass it explicitly:

```bash
KUBECFG="${KUBECONFIG:-}"
[ -z "$KUBECFG" ] && KUBECFG="$(find / -maxdepth 6 -type f \( -iname '*kubeconfig*' -o -path '*kube*config*' \) 2>/dev/null | head -1)"
echo "using kubeconfig: ${KUBECFG:-<none found — kubectl will fail>}"
```

Then `shell_spawn` the watcher **pinned to that path**:
```
K8S_WATCHER_KUBECONFIG=<KUBECFG> bash /data/k8s-watcher/k8s-event-watcher.sh
```

The watcher runs a **preflight** and exits immediately with a clear message if `kubectl`
still can't reach the cluster (rather than looping) — if so, report the path problem to
the user.

Check whether it's already running: `pgrep -f k8s-event-watcher`. `<this-skill-dir>` is
where this `SKILL.md` was loaded from (`find / -name k8s-event-watcher.sh 2>/dev/null | head -1`).

---

## Setup (one-time)

1. **Install the skill:** `npx skills add github:msa0311/prism-k8s-event-triage -g -a claude-code --copy`,
   or drop this bundle into `<DATA>/skills/`.
2. **Verify cluster access:** `kubectl get events -A --request-timeout=5s`. If it fails, the
   kubeconfig is missing/invalid — report that and stop (don't spawn a blind watcher).
3. **Spawn the watcher** (Part B). From then on, every Warning event schedules a triage task.

> **This skill does not use or change the agent's heartbeat.** Triage runs on dedicated
> one-shot cron tasks the watcher schedules on demand — not on the heartbeat, and not on a
> fixed poll.

**Keeping the watcher alive across restarts.** A `shell_spawn` watcher dies if the container
restarts, and a dead watcher can't schedule its own resurrection. Pick one:
- **Recurring keep-alive task** — a **low-frequency** cron task (e.g. `every 8 hours`) whose
  instruction is *"if `pgrep -f k8s-event-watcher` finds nothing, re-spawn the watcher via
  shell_spawn; otherwise reply with nothing."* Keep it infrequent: it's only a watchdog for
  the rare case the watcher dies (container restart), not a triage cadence — triage is driven
  by the watcher's own batches. A longer interval also means fewer of its (unsuppressed)
  "healthy" posts, since cron delivers every run.
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
