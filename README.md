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
kube-state-metrics ─► Prometheus ─► Alertmanager ────POST────► POST /agents/webhooks/k8s-alerts
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
- **The webhook is yours to set up** — the skill makes no assumptions about how the endpoint is
  exposed, addressed, or authenticated; that depends on your Prism deployment. You create it once in
  Prism's **Web UI** (Webhooks page) and point your Alertmanager at it.

Because the trigger lives in the cluster (not the sandbox), a runtime/sandbox restart never breaks
triage — there's nothing to keep alive.

## Install

```bash
npx skills add github:msa0311/prism-k8s-event-triage -g -a claude-code --copy
```
…or drop this bundle into the agent's `<DATA>/skills/` directory (refreshes on mtime, no restart).

Then one **one-time setup** remains, done by you (see **`SKILL.md` → Part B**): create the
`k8s-alerts` webhook in **Prism's Web UI** (Webhooks page — enable webhooks, add the subscription
with its prompt template, copy the endpoint URL), then configure your **Alertmanager** (or
event-exporter) to POST firing alerts to that URL. How the endpoint is exposed and authenticated
depends on your Prism deployment and is up to you; `references/in-cluster-setup.md` has example
config to start from.

## Requirements

- An in-cluster alerter: **Prometheus + Alertmanager** (`kube-prometheus-stack`, one Helm install) for
  the primary path, or **`kubernetes-event-exporter`** for raw events.
- A webhook endpoint your cluster can reach — created in Prism's Web UI; exposure and auth are
  deployment-specific and configured by you.
- The agent's read-only `kubectl` access to the monitored cluster (for triage investigation).

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | The agent-facing playbook: Part A (triage a `k8s-alerts` webhook run via Claude Code) + Part B (one-time setup). |
| `references/in-cluster-setup.md` | Example in-cluster config: subscription prompt template, Alertmanager receiver/route, optional event-exporter Deployment/RBAC. |
| `references/triage-runbook.md` | Triage method, severity rubric, per-symptom playbook (CrashLoopBackOff, ImagePullBackOff, OOMKilled, FailedScheduling, FailedMount, probe failures, quota, node pressure, HPA, …), output format, safety rails, and the `lens://` launcher-link format. |

## Configuration

The webhook subscription is named **`k8s-alerts`** (delivery to Slack, chat, or all channels — your
choice in the Web UI). The in-cluster sender POSTs to the subscription's endpoint URL, shown with a
copy button on the Web UI's Webhooks page. Alertmanager dedup knobs (`group_by`, `repeat_interval`,
…) and the optional Lens cluster specifier for launcher links are covered in
`references/in-cluster-setup.md`.

## License

Apache-2.0
