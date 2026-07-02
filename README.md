# prism-k8s-event-triage

A [Prism](https://github.com/lensapp) Agent Skill that makes the agent **triage Kubernetes
problems in real time**, driven by **standard, off-the-shelf in-cluster alerting** — no custom
watcher, no in-sandbox daemon.

## How it works

A Kubernetes-supervised alerter in the user's cluster detects problems and POSTs them to this
agent's webhook; the agent investigates and reports. Kubernetes supervises the sender, and
**deduplication is handled off-the-shelf** (Alertmanager), so there's no fragile daemon and no
alert spam.

```
User's cluster                                             Prism (this agent)
──────────────                                             ──────────────────
kube-state-metrics ─► Prometheus ─► Alertmanager ─POST(Bearer)─► POST /agents/webhooks/k8s-alerts
  (± kubernetes-event-exporter for raw Warning events)             │ subscription prompt template
                     dedup / group / silence here                  ▼ agent triages via Claude Code
                                                                     (read-only) + the runbook
                                                                     ─► "Open in Lens" link
                                                                     ─► deliver to Slack
```

- **Primary trigger — Alertmanager** (via `kube-prometheus-stack` + `kube-state-metrics`, which ship
  the rules: `KubePodCrashLooping`, `KubePodNotReady`, image-pull, OOM, HPA, node pressure, …). Its
  `group_by` / `repeat_interval` / inhibition / silences **are the deduplication**.
- **Optional — `kubernetes-event-exporter`** for raw Warning *events* not backed by metrics
  (FailedMount/FailedScheduling, Flux/ArgoCD controller events). Dedup there is only k8s event
  `count` aggregation, so prefer Alertmanager for anything you want deduped.
- **Auth** — the webhook stays private; the in-cluster sender authenticates with a **Nexus API key**
  (Bearer), reusing the existing edge auth. No public endpoint, no per-subscription secret.

Because the trigger lives in the cluster (not the sandbox), a runtime/sandbox restart never breaks
triage — there's nothing to keep alive.

## Install

```bash
npx skills add github:msa0311/prism-k8s-event-triage -g -a claude-code --copy
```
…or drop this bundle into the agent's `<DATA>/skills/` directory (refreshes on mtime, no restart).

Then follow **`SKILL.md` → Part B (Setup)**: the agent creates the `k8s-alerts` webhook subscription
and reports its URL; an operator mints a Nexus API key; the agent generates the Alertmanager /
event-exporter manifests (`references/in-cluster-setup.md`) and the **user applies them** (the agent's
kubectl is read-only).

## Requirements

- An in-cluster alerter: **Prometheus + Alertmanager** (`kube-prometheus-stack`, one Helm install) for
  the primary path, or **`kubernetes-event-exporter`** for raw events.
- A **Nexus API key** (org-scoped) for the sender's Bearer auth. ⚠️ It reaches the whole agent API for
  the org — store it in a Kubernetes `Secret`; agent/project-scoped tokens are future hardening.
- The agent's read-only `kubectl` access to the monitored cluster (for triage investigation).

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | The agent-facing playbook: Part A (triage a `k8s-alerts` webhook run via Claude Code) + Part B (one-time setup). |
| `references/in-cluster-setup.md` | The in-cluster manifests/config: webhook subscription, token Secret, Alertmanager receiver/route, optional event-exporter Deployment/RBAC. |
| `references/triage-runbook.md` | Triage method, severity rubric, per-symptom playbook (CrashLoopBackOff, ImagePullBackOff, OOMKilled, FailedScheduling, FailedMount, probe failures, quota, node pressure, HPA, …), output format, safety rails, and the `lens://` launcher-link format. |

## Configuration

The webhook subscription is named **`k8s-alerts`** (`deliverTo: slack`/`all`). The in-cluster sender
posts to `https://<sandbox-slug>.<SANDBOX_INGRESS_HOST>/agents/webhooks/k8s-alerts` with
`Authorization: Bearer <nexus-api-key>`. Alertmanager dedup knobs (`group_by`, `repeat_interval`, …)
and the optional Lens cluster specifier for launcher links are covered in
`references/in-cluster-setup.md`.

## License

Apache-2.0
