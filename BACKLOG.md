# Backlog

Tracked improvements not yet scheduled. Promote entries to GitHub Issues when picked up.

---

## Recovery / "resolved" notifications

**Status:** open · not urgent
**Labels:** enhancement
**Related:** `references/in-cluster-setup.md` (Alertmanager `webhook_configs.send_resolved`)

The setup uses `send_resolved: false`, so the agent triages firing alerts but never posts closure
when an issue clears. Alertmanager already tracks resolution and can POST `status: "resolved"` when
an alert stops firing. Enable `send_resolved: true` and have the `k8s-alerts` subscription/triage
emit a brief "✅ recovered: <workload>" on resolved payloads (skip full triage for those). Gives
closure with zero polling — the dedup/resolution is entirely Alertmanager's job.

## Agent/project-scoped Nexus API tokens (security hardening)

**Status:** open · security
**Related:** the Bearer key used by the in-cluster sender

Today the sender authenticates with an **org-scoped** Nexus API token, which can reach every agent
in the org and the whole agent API — over-broad for a webhook poster. Nexus gap to close: add an
optional `projectId`/`sandboxId` scope to `api_tokens` and enforce it in the authz check, then issue
a token scoped to just this agent. (Alternative: a public `/agents/webhooks/*` path + a
per-subscription secret, if unauthenticated senders are ever needed.)
