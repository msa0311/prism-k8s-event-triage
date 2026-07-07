# Example in-cluster config — Alertmanager / event-exporter → the agent's webhook

Starting-point config for wiring standard in-cluster alerting to the agent's webhook. These are
**examples, not prescriptions** — adapt them to your cluster and your Prism deployment. The agent's
kubectl is **read-only**, so if the agent drafts these for you, the **user applies** them
(`kubectl apply` / GitOps).

**Prerequisite:** the `k8s-alerts` webhook subscription already exists — created once in Prism's
**Web UI** (Webhooks page), see `SKILL.md` Part B — and you have its endpoint URL.

Placeholders:
- `WEBHOOK_URL` = the endpoint URL copied from the Web UI's Webhooks page.
- **Auth is deployment-specific.** If your Prism deployment requires credentials in front of the
  webhook, add them yourself — e.g. an `Authorization` header via Alertmanager's `http_config` or
  the event-exporter's `headers` — and store the credential in a Kubernetes `Secret`, never inline.

---

## Subscription prompt (set in the Web UI)

A prompt template that works well for the `k8s-alerts` subscription:

```
A Kubernetes alert fired. Alertmanager payload:
{__raw__}

Follow the k8s-event-triage skill (Part A): triage each firing alert and report root cause +
severity + suggested fix + an 'Open in Lens' link. Dedup is handled upstream. For Lens links use
clusterSpecifier=<SPEC> connectionType=direct (omit the links if unset).
```

`<SPEC>` (optional) enables the `lens://` launcher links: it's `sha256(<the server URL the user's
Lens uses>)[:32]` for the monitored cluster (see `references/triage-runbook.md` → Deep links). Omit
that clause and the agent simply won't add links.
(`{__raw__}` injects the full JSON body; `{dot.path}` interpolation is also available but the
Alertmanager `alerts` array is easiest handled as raw and parsed during triage.)

---

## 1a. Alertmanager (primary) — kube-prometheus-stack

If Prometheus/Alertmanager isn't installed:
`helm repo add prometheus-community https://prometheus-community.github.io/helm-charts`
`helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace`
(ships Prometheus + Alertmanager + kube-state-metrics + the Kube* alert rules.)

Alertmanager config (via the chart's `alertmanager.config` values, or an `AlertmanagerConfig` CR):

```yaml
route:
  receiver: prism-k8s-triage
  group_by: ['namespace', 'alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h          # a still-firing issue re-triggers triage at most this often
receivers:
  - name: prism-k8s-triage
    webhook_configs:
      - url: "WEBHOOK_URL"
        send_resolved: false
        # http_config:           # only if your deployment requires auth on the webhook —
        #   authorization:       # mount the credential from a Secret, e.g. kube-prometheus-stack:
        #     type: Bearer       # alertmanager.alertmanagerSpec.secrets: ['<secret-name>']
        #     credentials_file: /etc/alertmanager/secrets/<secret-name>/token
```

`repeat_interval` + `group_by` + inhibition/silences are the **deduplication** — no agent-side dedup.

---

## 1b. kubernetes-event-exporter (optional) — raw Warning events

For event reasons not backed by metrics. Deploy `resmoio/kubernetes-event-exporter` with RBAC to
read events and a webhook sink:

```yaml
# ConfigMap: config.yaml
route:
  routes:
    - match:
        - type: "Warning"
      drop:
        - namespace: "kube-system"   # tune noise as needed
      to: [prism]
receivers:
  - name: prism
    webhook:
      endpoint: "WEBHOOK_URL"
      # headers:                     # only if your deployment requires auth on the webhook —
      #   Authorization: "Bearer …"  # source from a Secret via env/valueFrom, never inline
```
Deploy: a `Deployment` running `ghcr.io/resmoio/kubernetes-event-exporter`, a `ServiceAccount` +
`ClusterRole`/`ClusterRoleBinding` granting `get,list,watch` on `events`, and the ConfigMap above.
Note: event-exporter dedup = only k8s event `count` aggregation, so it's noisier than Alertmanager.

---

## Verify
- `kubectl -n monitoring logs deploy/…alertmanager` (or event-exporter) shows the POST succeeding (2xx).
- Break a workload → a deduped triage message appears in Slack with a working `lens://` launcher link.
