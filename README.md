# prism-k8s-event-triage

A [Prism](https://github.com/lensapp) Agent Skill that makes the agent **triage
Kubernetes Warning/error events immediately as they appear** — no webhook
infrastructure required.

## How it works

Kubernetes does not POST webhooks for Event objects, but it exposes a native
streaming `watch` API. This skill uses it:

```
kubectl watch (type=Warning) ──append──► /data/k8s-watcher/events.jsonl
        │ (debounced)                              │ read on each heartbeat
        └─ POST /agents/heartbeat/trigger ─► heartbeat (skill) ─► triage ─► user
                                                    └─ watcher dead? re-spawn it
```

- A lightweight background **watcher** (`scripts/k8s-event-watcher.sh`, spawned by
  the agent via `shell_spawn`) streams `Warning` events, appends each to a results
  file on the persistent `/data` volume, and — debounced — pokes the agent's
  existing heartbeat trigger.
- The **heartbeat** (driven by `SKILL.md`) reads the captured events and triages
  them (root cause, severity, suggested action), reusing the runtime's
  DELIVER/SUPPRESS gate and 24h duplicate suppression for noise control.
- The heartbeat also **supervises** the watcher — re-spawning it if it died — so the
  system self-heals after a crash or container restart.

Triage is **event-driven**: the watcher's pokes are the cadence. The timer heartbeat
runs infrequently and only acts as a watchdog.

## Install

```bash
npx skills add github:lensapp/prism-k8s-event-triage -g -a claude-code --copy
```

…or drop this bundle into the agent's `<DATA>/skills/` directory. The catalog
refreshes on directory mtime, so the skill appears without a restart.

Then set the agent's `heartbeatMd` to:

> On each heartbeat, follow the **k8s-event-triage** skill: ensure the Kubernetes
> event watcher is running and triage any new Warning events it has captured.

Set the heartbeat interval to your acceptable watcher-restart recovery window
(e.g. 30–60 min) — it is a watchdog, not the triage cadence.

## Requirements

- A background shell `kubectl` with cluster credentials in the agent's environment
  (the watcher runs as a plain process, so it cannot use the lens MCP `kubectl`
  *tool*). The skill verifies this on first run.
- **Fallback:** if shell `kubectl` has no cluster access, the skill automatically
  falls back to **poll mode** — querying recent Warning events via the lens MCP
  `kubectl` tool on each heartbeat (latency = heartbeat interval).
- `jq` and `curl` (present in the agent-runtime container).

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | The agent-facing playbook (mode detection, supervise, read, triage, fallback). |
| `references/triage-runbook.md` | Comprehensive triage reference: method, severity rubric, per-symptom playbook (CrashLoopBackOff, ImagePullBackOff, OOMKilled, FailedScheduling, FailedMount, probe failures, quota, node pressure, HPA, …), output format, safety rules. Loaded on demand. |
| `scripts/k8s-event-watcher.sh` | The background watcher: streams Warning events, appends to the results file, debounced heartbeat poke, self-reconnecting. |

## Configuration (watcher env, all optional)

| Env var | Default | Purpose |
|---------|---------|---------|
| `K8S_WATCHER_STATE_DIR` | `/data/k8s-watcher` | Where the results file / pidfile live. |
| `K8S_WATCHER_TRIGGER_URL` | `http://localhost:3003/agents/heartbeat/trigger` | Heartbeat trigger endpoint. |
| `K8S_WATCHER_DEBOUNCE_SECONDS` | `20` | Minimum gap between heartbeat pokes. |
| `K8S_WATCHER_NAMESPACE` | _(all)_ | Scope the watch to a single namespace. |

## License

Apache-2.0
