---
name: k8s-event-triage
description: >-
  Triage Kubernetes problems in real time, driven by standard in-cluster alerting.
  A Prometheus Alertmanager (or kubernetes-event-exporter) running in the user's
  cluster POSTs firing alerts to this agent's webhook; the agent investigates the
  root cause (read-only kubectl via Claude Code) and reports severity + fix + an
  "Open in Lens" deep link. Deduplication is handled upstream by Alertmanager.
  Follow this skill when a k8s-alerts webhook run fires, or when setting up / when
  the user asks to monitor, watch, or triage Kubernetes problems, pod failures,
  crashloops, image-pull errors, scheduling failures, or cluster warnings.
---

# Kubernetes triage (in-cluster alerting → webhook)

Real-time Kubernetes triage with **no in-sandbox watcher**. A standard, Kubernetes-supervised
component in the user's cluster detects problems and POSTs them to this agent's **webhook**; the
agent triages and reports. Kubernetes supervises the sender, and **deduplication is off-the-shelf**
(Alertmanager grouping/`repeat_interval`/inhibition/silences), so there is no fragile daemon and no
alert spam.

```
User's cluster                                             Prism (this agent)
──────────────                                             ──────────────────
kube-state-metrics ─► Prometheus ─► Alertmanager ────POST────► POST /agents/webhooks/k8s-alerts
  (± kubernetes-event-exporter for raw Warning events)             │ subscription prompt template
                     dedup / group / silence here                  ▼ agent run → triage via
                                                                     Claude Code + runbook
                                                                     ─► "Open in Lens" link
                                                                     ─► deliver to Slack
```

- **Primary trigger: Alertmanager** (via `kube-prometheus-stack` + `kube-state-metrics`, which ship
  the rules — `KubePodCrashLooping`, `KubePodNotReady`, image-pull, OOM, HPA, node pressure, …). Its
  `group_by` / `repeat_interval` / inhibition / silences **are the deduplication**.
- **Optional: `kubernetes-event-exporter`** for raw Warning *events* not backed by metrics
  (FailedMount/FailedScheduling, Flux/ArgoCD controller events).
- **Webhook configuration is yours, not the skill's.** The skill makes no assumptions about how the
  webhook endpoint is exposed, addressed, or authenticated — that depends on your Prism deployment.
  You create the webhook once in Prism's **Web UI** and wire your Alertmanager to it (see Part B).

Example Alertmanager / event-exporter config is in **`references/in-cluster-setup.md`**; the triage
method is in **`references/triage-runbook.md`**.

---

## Part A — When a `k8s-alerts` webhook run fires, do this

Your run was triggered by the `k8s-alerts` webhook. **The incident payload is in your prompt** — the
Alertmanager JSON (or event-exporter event) rendered by the subscription's template (typically the
raw payload: `{"alerts":[{"labels":{"alertname","namespace","pod"/workload,…},"annotations":{"summary","description"}}, …]}`).

1. **Parse the firing alert(s)** from the payload: for each, extract the workload identity
   (`namespace`, and the `pod`/`deployment`/`statefulset`/… label) and the reason/summary. Alertmanager
   has already deduped/grouped — triage what's in this payload; don't re-poll for "all warnings".
2. **Delegate the investigation to `claude_code`** (`mode: "plan"`, read-only) following
   `references/triage-runbook.md`:

```
claude_code({
  mode: "plan",
  prompt: "Triage a Kubernetes incident. Firing alerts: <PASTE the parsed alerts: namespace/kind/name/reason/summary + startsAt>.
    Follow the k8s-event-triage skill's references/triage-runbook.md with READ-ONLY kubectl: scope the
    blast radius; gather evidence (describe / logs --previous / get events / top / node conditions); and
    CHECK WHAT CHANGED recently (rollout history, current image, recent events, pod age) and correlate
    it to the alert onset (startsAt) — if a GitHub tool is available, find the correlating commit/PR.
    Do NOT run any mutating command (delete / scale / rollout restart|undo / edit / apply / drain /
    patch); note that 'kubectl rollout history' is read-only and allowed.
    Return a concise report per the runbook's Output format, INCLUDING an 'Investigation' trail (the
    commands you ran → the decisive finding from each), a 'Recent change' line (what changed + when
    vs onset, or 'no recent change'), and a 'Class:' line with ONE root-cause class keyword from
    oom|crashloop|image-pull|scheduling|node-pressure|config|quota|network|app-error|unknown,
    then root cause (citing the trail) + the suggested fix as a
    command to PROPOSE (not run). IF a cluster specifier is available, add an 'Open in Lens' link
    per cited resource as a Markdown link (never raw lens:// / never in code), built EXACTLY as:
    https://app.k8slens.dev/lens-launcher?c=<encodeURIComponent of the inner lens:// URL>
    where the inner URL is
    lens://app/open/<connectionType>/<clusterSpecifier>/cluster<versionless apiBase, e.g. /apis/apps/deployments or /api/pods>?kube-details=<urlencoded FULL versioned selfLink, e.g. /apis/apps/v1/namespaces/<ns>/deployments/<name>>
    The inner URL MUST begin with lens://app/open/ — any other shape (e.g.
    lens://cluster/<hash>/workloads/...) fails in Lens Desktop with 'invalid host'. Details +
    worked example: the runbook's 'Deep links' section. If no specifier: omit links entirely."
})
```

   Then poll `claude_code_status({ taskId })` until `completed`. Keep the read-only rule in the
   prompt — plan mode blocks file edits, not mutating `kubectl`.

   **Your reply IS the delivery — paste the full report into it.** The `claude_code_status`
   `result` is a tool output only you can see; nothing has been delivered until the report text
   is in YOUR response message. Copy the complete report into your reply (after link
   validation), and make it the substance of the reply. NEVER respond with only meta-commentary
   like *"Report delivered and logged. Standing by."* — that message would be the only thing the
   user ever sees, and there is no report anywhere else.

   **Before replying, validate every Lens link**: it must start with
   `https://app.k8slens.dev/lens-launcher?c=lens%3A%2F%2Fapp%2Fopen%2F` — anything else, rebuild it
   per the runbook's Deep-links template or drop the link (a wrong link is worse than none).

3. **Record the work (optional, one call).** Once the report is composed — ideally before you
   send the reply, so the report stays your final message — if
   `/data/skills/work-telemetry/` exists, follow that skill's "How to record work" section
   ([prism-work-telemetry](https://github.com/msa0311/prism-work-telemetry)) with:
   - `type: "k8s.triage"`, `trigger: "webhook"`
   - `id`: `"<alertname>/<namespace>/<workload>"` — stable fingerprint, same problem ⇒ same id
   - `severity`: the rubric result, lowercased (`critical|high|medium|low|info`)
   - `category`: the report's `Class:` root-cause keyword
   - `outcome`: `diagnosed` (root cause found, fix proposed) · `needs_human` (low confidence or
     approval needed) · `recovered` (already self-healed) · `false_positive` (Low + cosmetic/
     already resolved) · `escalated` (Critical, humans paged)
   - `detected_at`: the alert's `startsAt`; `attrs`: `{"k8s.namespace": …, "alert.name": …}`
   - omit `human_minutes_saved` to use the configured per-type default

   If the work-telemetry skill is not installed, skip this step silently — never let recording
   block, delay, or fail the triage itself.

The method, severity rubric, per-symptom playbook, safety rails, and the `lens://` launcher-link
format all live in `references/triage-runbook.md` — that's what Claude Code follows.

---

## Part B — Setup (one-time, done by you)

After installing the skill, one thing must be wired up before anything happens: **a webhook that
your in-cluster alerting POSTs to**. The skill does not create or configure this — it's your
webhook, in your Alertmanager, secured however your Prism deployment requires. Prism's **Web UI has
a Webhooks page** for exactly this.

1. **Install the skill:** `npx skills add github:msa0311/prism-k8s-event-triage -g -a claude-code --copy`,
   or drop this bundle into `<DATA>/skills/`.
2. **Create the webhook in the Prism Web UI** (**Webhooks** page): enable webhooks, then create a
   subscription named `k8s-alerts` with a **prompt template** that embeds the raw payload and points
   at this skill — e.g.
   *"A Kubernetes alert fired: {__raw__}. Follow the k8s-event-triage skill (Part A) to triage it."*
   Copy the endpoint URL shown next to the subscription.
3. **Point your Alertmanager (or `kubernetes-event-exporter`) at that URL.** How the endpoint is
   reachable from the cluster and whether it needs auth headers depends on your Prism deployment —
   that part is up to you. `references/in-cluster-setup.md` has example Alertmanager /
   event-exporter config to start from.
4. **(Optional) Make the triage work measurable:** install
   [prism-work-telemetry](https://github.com/msa0311/prism-work-telemetry) and configure its
   collector endpoint — every triage then lands on the central agent-work dashboard
   (e.g. [prism-work-dashboard](https://github.com/msa0311/prism-work-dashboard)).

## Notes & limits
- **No in-sandbox component** — nothing to keep alive; a runtime/sandbox restart doesn't break triage.
- **Dedup is upstream** (Alertmanager). `kubernetes-event-exporter` only has k8s event `count`
  aggregation, so prefer Alertmanager for anything you want deduped.
- Requires the user to run Prometheus/Alertmanager for the primary path (event-exporter is the
  lighter alternative), and to set up the webhook + in-cluster config themselves (Part B).
- **Work recording (Part A step 3) is best-effort** — it must never block, delay, or replace
  the triage report; without the work-telemetry skill it's skipped entirely.
