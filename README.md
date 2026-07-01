# prism-k8s-event-triage

A [Prism](https://github.com/lensapp) Agent Skill that makes the agent **triage
Kubernetes Warning/error events immediately as they appear** — no webhook
infrastructure required.

## How it works

Kubernetes does not POST webhooks for Event objects, but it exposes a native
streaming `watch` API. This skill uses it — and drives triage through dedicated
one-shot tasks, **not the heartbeat**:

```
kubectl watch (type=Warning) ──append──► /data/k8s-watcher/events.jsonl
        │ (debounced)                                  │ read when the task runs
        └─ POST /agents/cron-tasks  (run-now one-shot) ─► triage task ─► triage ─► user
```

- A lightweight background **watcher** (`scripts/k8s-event-watcher.sh`, spawned by
  the agent via `shell_spawn`) streams `Warning` events and appends each to a logfile
  on the persistent `/data` volume.
- A flusher checks the logfile every ~15s and, **only if it has content**, renames it to a
  unique batch file and **schedules a one-shot triage task** for that batch via the runtime's
  cron API (`POST /agents/cron-tasks`, `schedule:"in 1 minute"` — the runtime rejects
  sub-minute one-shots). No content ⇒ no task, so there are no empty runs.
- When the task fires, the agent (driven by `SKILL.md`) delegates the investigation to the
  **`claude_code`** tool (plan/read-only mode), which reads the batch, follows the triage
  runbook, and returns a report (root cause, severity, suggested fix). The one-shot task
  then auto-deletes.

Triage is **event-driven and near-real-time** (~1 min): a task is scheduled only when real events
appear, so there are no empty/"all clear" runs, and the heartbeat is never touched.

## Install

```bash
npx skills add github:msa0311/prism-k8s-event-triage -g -a claude-code --copy
```

…or drop this bundle into the agent's `<DATA>/skills/` directory. The catalog
refreshes on directory mtime, so the skill appears without a restart.

Then verify cluster access and spawn the watcher (the agent does this by following
`SKILL.md`): `kubectl get events -A --request-timeout=5s` must work, then the watcher is
started via `shell_spawn`. From then on, every Warning event schedules a triage task.

The skill **does not use or change the agent's heartbeat.** Triage runs on dedicated
one-shot cron tasks the watcher schedules on demand. To keep the watcher alive across
container restarts, see the "Keeping the watcher alive" options in `SKILL.md` (recurring
keep-alive task, heartbeat watchdog, or in-cluster Deployment).

## Requirements

- A kubeconfig + `kubectl` in the sandbox with cluster access — the watcher runs as a
  plain background process and uses ordinary `kubectl`. The skill verifies access on each
  run and reports clearly if the kubeconfig is missing or the API server is unreachable.
- `jq` and `curl` (present in the agent-runtime container).

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | The agent-facing playbook (verify access, supervise the watcher, read events, triage). |
| `references/triage-runbook.md` | Comprehensive triage reference: method, severity rubric, per-symptom playbook (CrashLoopBackOff, ImagePullBackOff, OOMKilled, FailedScheduling, FailedMount, probe failures, quota, node pressure, HPA, …), output format, safety rules. Loaded on demand. |
| `scripts/k8s-event-watcher.sh` | The background watcher: streams Warning events, appends them to the logfile, and debounced-schedules a one-shot triage task via the cron API; self-reconnecting. |

## Configuration (watcher env, all optional)

| Env var | Default | Purpose |
|---------|---------|---------|
| `K8S_WATCHER_STATE_DIR` | `/data/k8s-watcher` | Where the logfile / pidfile live. |
| `K8S_WATCHER_KUBECONFIG` | _(ambient `KUBECONFIG`)_ | Explicit kubeconfig path. Set this if `kubectl` in the watcher's process hits `localhost:8080` — a spawned process doesn't inherit an interactive shell's un-exported `KUBECONFIG` or `kubectl` aliases. |
| `K8S_WATCHER_CRON_URL` | `http://localhost:3003/agents/cron-tasks` | Runtime cron API used to schedule the one-shot triage task. |
| `K8S_WATCHER_DEBOUNCE_SECONDS` | `15` | Minimum gap between scheduled triage tasks (coalesces event bursts). |
| `K8S_WATCHER_NAMESPACE` | _(all)_ | Scope the watch to a single namespace. |
| `K8S_WATCHER_TASK_NAME` | `k8s-event-triage` | Name used for the scheduled triage task. |
| `LENS_CLUSTER_SPECIFIER` | _(compute from kubeconfig)_ | Pins the cluster specifier for `lens://` deep links, passed into the triage task. **Set this when the agent reaches the cluster via a tunnel** (its kubeconfig server URL differs from the user's local Lens, so a computed hash won't match). Value = `sha256(<server URL the user's Lens uses>)[:32]`. |
| `LENS_CONNECTION_TYPE` | `direct` | `direct` (kubeconfig cluster) or `teamwork` (Lens Spaces). |

## License

Apache-2.0
