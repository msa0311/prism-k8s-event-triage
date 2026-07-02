# In-cluster setup — Alertmanager / event-exporter → agent webhook

Concrete config for wiring a standard in-cluster alerter to this agent's webhook. The agent's
kubectl is **read-only**, so it generates these; the **user applies** them (`kubectl apply` / GitOps).

Placeholders:
- `WEBHOOK_URL` = `https://<sandbox-slug>.<SANDBOX_INGRESS_HOST>/agents/webhooks/k8s-alerts`
- `NEXUS_API_TOKEN` = the org-scoped Nexus API key (Bearer). **Store in a Secret, never inline.**

---

## 1. Webhook subscription (agent-side, via the management API)

```
POST /agents/webhook-subscriptions
{
  "name": "k8s-alerts",
  "deliverTo": "slack",                         // or "all"
  "prompt": "A Kubernetes alert fired. Alertmanager payload:\n{__raw__}\n\nFollow the k8s-event-triage skill (Part A): triage each firing alert and report root cause + severity + suggested fix + an 'Open in Lens' link. Dedup is handled upstream. For Lens links use clusterSpecifier=<SPEC> connectionType=direct (omit the links if unset)."
}
```
`<SPEC>` (optional) enables the `lens://` launcher links: it's `sha256(<the server URL the user's
Lens uses>)[:32]` for the monitored cluster (see `references/triage-runbook.md` → Deep links). Omit
that clause and the agent simply won't add links.
Then enable inbound: `PATCH /agents/webhooks/receiver { "enabled": true }`.
(`{__raw__}` injects the full JSON body; `{dot.path}` interpolation is also available but the
Alertmanager `alerts` array is easiest handled as raw and parsed during triage.)

---

## 2. Token Secret (in the cluster)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: prism-webhook-token
  namespace: monitoring
stringData:
  token: "NEXUS_API_TOKEN"
```

---

## 3a. Alertmanager (primary) — kube-prometheus-stack

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
        http_config:
          authorization:
            type: Bearer
            credentials_file: /etc/alertmanager/secrets/prism-webhook-token/token
```
Mount the Secret into Alertmanager (kube-prometheus-stack: `alertmanager.alertmanagerSpec.secrets:
['prism-webhook-token']` → mounted at `/etc/alertmanager/secrets/prism-webhook-token/`).

`repeat_interval` + `group_by` + inhibition/silences are the **deduplication** — no agent-side dedup.

---

## 3b. kubernetes-event-exporter (optional) — raw Warning events

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
      headers:
        Authorization: "Bearer NEXUS_API_TOKEN"   # from the Secret via env/valueFrom
```
Deploy: a `Deployment` running `ghcr.io/resmoio/kubernetes-event-exporter`, a `ServiceAccount` +
`ClusterRole`/`ClusterRoleBinding` granting `get,list,watch` on `events`, and the ConfigMap above.
Note: event-exporter dedup = only k8s event `count` aggregation, so it's noisier than Alertmanager.

---

## Verify
- `kubectl -n monitoring logs deploy/…alertmanager` (or event-exporter) shows the POST succeeding (2xx).
- Break a workload → a deduped triage message appears in Slack with a working `lens://` launcher link.
- A wrong/absent Bearer → rejected at the Nexus edge (401/403), never reaches the agent.
