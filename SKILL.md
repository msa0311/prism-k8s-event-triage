---
name: k8s-event-triage
description: >-
  React to Kubernetes Warning/error events immediately. Runs a lightweight
  background watcher on the cluster's event watch API that pokes your heartbeat
  the moment a Warning event appears, then triages the new events (root cause,
  severity, suggested action). Use this skill on every heartbeat to keep the
  watcher alive and process any events it has captured. Mention this skill when
  the user asks to monitor, watch, or triage Kubernetes events, pod failures,
  crashloops, image-pull errors, scheduling failures, or cluster warnings.
---

# Kubernetes event triage

This skill makes Prism react to Kubernetes `Warning` events **as they happen**,
without any webhook infrastructure. A small background **watcher** streams
Warning events off the Kubernetes `watch` API and pokes the agent's heartbeat
trigger; the heartbeat (this skill) then reads and triages whatever the watcher
captured. The heartbeat also keeps the watcher alive, so the system self-heals
after a crash or container restart.

```
kubectl watch (type=Warning) ──append──► /data/k8s-watcher/events.jsonl
        │ (debounced)                              │ read on each heartbeat
        └─ POST /agents/heartbeat/trigger ─► heartbeat (this skill) ─► triage ─► user
                                                    └─ watcher dead? re-spawn it
```

## Paths and config (defaults)

- State dir: `/data/k8s-watcher` (persistent volume; survives restarts)
- Events file: `/data/k8s-watcher/events.jsonl`
- Watcher script (stable copy): `/data/k8s-watcher/k8s-event-watcher.sh`
- Trigger URL: `http://localhost:3003/agents/heartbeat/trigger`

---

## Run this every heartbeat — step by step

### 1. Verify cluster access

The sandbox provides a kubeconfig and `kubectl`. Confirm it works before (re)starting the
watcher:

```bash
kubectl get events -A --request-timeout=5s >/dev/null 2>&1 && echo OK || echo NO_KUBECTL
```

- `OK` → continue to step 2.
- `NO_KUBECTL` → cluster access is broken (missing/invalid kubeconfig, or the API server is
  unreachable). Don't spawn a watcher that can't reach the cluster — report this plainly to
  the user so they can fix the kubeconfig, and stop here.

### 2. Ensure the watcher is running (supervise)

```bash
pgrep -f k8s-event-watcher >/dev/null && echo RUNNING || echo DEAD
```

If `DEAD`, (re)start it. First copy the script to the stable state-dir location so the
spawn path doesn't depend on where this skill is installed, then spawn it **with the
`shell_spawn` tool** (NOT `shell_exec` — it must outlive this turn):

```bash
mkdir -p /data/k8s-watcher
cp "<this-skill-dir>/scripts/k8s-event-watcher.sh" /data/k8s-watcher/k8s-event-watcher.sh
chmod +x /data/k8s-watcher/k8s-event-watcher.sh
```

Then `shell_spawn`:

```
bash /data/k8s-watcher/k8s-event-watcher.sh
```

`<this-skill-dir>` is the directory this `SKILL.md` was loaded from. If unsure, find it:
`find / -name k8s-event-watcher.sh 2>/dev/null | head -1`.

### 3. Read the new events (atomic rotate — no growth, no races)

The watcher appends with a fresh open each time, so renaming the file is race-free:

```bash
if [ -s /data/k8s-watcher/events.jsonl ]; then
  mv /data/k8s-watcher/events.jsonl /data/k8s-watcher/events.consuming
  cat /data/k8s-watcher/events.consuming
fi
```

New events now flow into a fresh `events.jsonl`; `events.consuming` is yours to process.
Each line is one event: `{ts, ns, kind, name, reason, type, count, message, uid}`.
When done, `rm -f /data/k8s-watcher/events.consuming`.

### 4. Triage and report

**Read `references/triage-runbook.md` and follow it** — it contains the full triage method,
a severity rubric, a per-symptom playbook (CrashLoopBackOff, ImagePullBackOff, OOMKilled,
FailedScheduling, FailedMount, probe Unhealthy, FailedCreate/quota, node pressure, HPA
metric failures, …) with the exact diagnostic commands, likely causes, and remediations,
plus the required output format and safety rules. The essentials:

- **Group** related events (same `involvedObject` / `reason`); triage the owning workload
  (Pod → ReplicaSet → Deployment/Job/StatefulSet), not each raw line.
- **Scope the blast radius** (one pod vs. whole workload vs. node vs. cluster) — it drives
  severity more than the event count.
- **Gather evidence** with `kubectl`: `describe` the object, current + `--previous` logs,
  the object's recent events, `kubectl top` for resource pressure, node conditions. Match
  the symptom to its runbook section for the right probes.
- **Report** per the runbook's format: what/where, severity, root-cause hypothesis (with
  confidence + evidence), suggested immediate + durable fix, and what to watch.
- **Safety:** default to read-only. Never run mutating commands (`delete`, `scale`,
  `rollout restart`, `edit`, `apply`, `drain`, `patch`) without **explicit user
  confirmation** — propose the exact command instead.
- If there were **no** new events and the watcher is healthy, produce a brief all-clear —
  the heartbeat's DELIVER/SUPPRESS gate will suppress it. Never comment on the mechanism
  itself.

Then a quick **catch-up sweep** to cover any gap while the watcher was down (e.g. just
after a restart, before re-spawn):

```bash
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp -o wide | tail -30
```

Report only genuinely new/actionable items; the 24h duplicate suppression handles repeats.

---

## One-time setup (operator / first conversation)

1. **Install the skill** so the runtime can find it:
   - `npx skills add github:lensapp/prism-k8s-event-triage -g -a claude-code --copy`, or
   - drop this bundle into `<DATA>/skills/` directly.
2. **Point the heartbeat at it.** Set `heartbeatMd` (via the agent-config tool or the UI) to:
   > On each heartbeat, follow the **k8s-event-triage** skill: ensure the Kubernetes event
   > watcher is running and triage any new Warning events it has captured.
3. **Set the heartbeat interval as a watchdog, not a triage cadence.** Triage is driven by
   the watcher's pokes; the timer only needs to re-spawn a dead watcher after a crash or
   container restart (the runtime does **not** run a heartbeat at boot — the first timer
   tick fires one full interval later). Pick the interval = your acceptable worst-case
   recovery window after a restart, e.g. **30–60 min**.
4. The first heartbeat will detect the watcher is absent and spawn it; from then on it
   self-heals.

## Notes & limits

- The trigger carries **no payload** by design — the agent reads `events.jsonl` for detail.
- The watcher debounces pokes (default 20s); a coalesced poke never drops an event because
  step 3 reads *all* accumulated lines.
- A `shell_spawn` watcher dies if the container restarts; the watchdog heartbeat re-spawns
  it and the catch-up sweep covers the gap (Kubernetes events have a ~1h TTL).
- For a watcher that survives container loss without relying on the heartbeat, deploy it as
  an in-cluster `Deployment` instead (future hardening).
