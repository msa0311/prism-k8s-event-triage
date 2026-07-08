# Kubernetes triage runbook

Reference for triaging Kubernetes `Warning` events and related failures. Load this
when triaging events surfaced by the k8s-event-triage skill. All diagnostic commands
are **read-only**; see [Safety](#safety) before doing anything mutating.

---

## Triage method (apply to every batch)

1. **Identify the object and its owner chain.** A Warning on a Pod usually traces up to a
   ReplicaSet → Deployment (or Job / StatefulSet / DaemonSet). Triage the *workload*, not
   the individual pod, unless the pod is a one-off.
2. **Group** events by `(involvedObject, reason)`. One crashlooping Deployment can emit
   hundreds of events — report it once.
3. **Scope the blast radius.** Is it one pod, a whole workload, every pod on a node, or
   cluster-wide? Scope drives severity far more than the raw event count.
4. **Gather evidence** (commands below): `describe`, current + previous logs, recent events
   for the object, resource usage, node conditions.
5. **Check what changed recently.** Correlate the incident with a recent rollout / deploy /
   image / config change (commands below), comparing to the alert's onset time (`startsAt` in
   the webhook payload). A brand-new revision or image right before onset is the prime suspect;
   *"nothing changed"* is itself a finding (points at load/infra, not a deploy). If a GitHub
   tool/MCP is available, map the changed image tag or GitOps commit to the correlating commit/PR.
6. **Form a root-cause hypothesis** with a confidence level. Say what you're unsure about.
7. **Recommend action**: an immediate mitigation *and* a durable fix. Separate "safe to do
   now" from "needs human approval."
8. **State what to watch** and the escalation threshold.

**Show your work.** The report must expose *how* you reached the conclusion — the specific commands
you ran and the decisive finding from each (see [Output format](#output-format-for-the-triage-report)).
A human has to be able to verify the reasoning before acting on it.

### Evidence-gathering commands

```bash
kubectl describe <kind> <name> -n <ns>                       # events + state + conditions
kubectl get <kind> <name> -n <ns> -o yaml                    # full spec/status
kubectl logs <pod> -n <ns> --tail=100                        # current container logs
kubectl logs <pod> -n <ns> --tail=100 --previous             # logs from the crashed instance
kubectl get events -n <ns> --field-selector involvedObject.name=<name> --sort-by=.lastTimestamp
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].state}'
kubectl describe node <node>                                 # node conditions, pressure, capacity
kubectl top pod <pod> -n <ns>                                # live usage (needs metrics-server)
```

Corroborate with metrics when a backend is reachable — `kubectl top` (metrics-server) or,
if a Prometheus query tool is available, series like `container_memory_working_set_bytes`,
`kube_pod_container_status_restarts_total`, `kube_pod_status_phase` to confirm
OOM/restart/pending patterns. If no metrics backend is reachable, rely on `kubectl
describe` and logs.

### Change-detection commands ("what changed recently")

All read-only. Compare the timings to the alert's onset (`startsAt`) — a change right before onset
is the likely trigger.

```bash
kubectl rollout history <deploy|statefulset|daemonset>/<name> -n <ns>           # revisions + when
kubectl get <workload> <name> -n <ns> -o jsonpath='{.spec.template.spec.containers[*].image}'  # current image(s)
kubectl get <workload> <name> -n <ns> -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}{.status.observedGeneration}'
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -30                  # what happened around onset
kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.creationTimestamp}'       # failing pod age vs onset
```

If a **GitHub tool/MCP** is available, map the changed image tag / GitOps commit to the correlating
commit or PR (best-effort). If none is available, stick to the in-cluster signals above — don't guess.

---

## Severity rubric

| Severity | Signal |
|----------|--------|
| **Critical** | Cluster/control-plane, node-wide, many workloads affected, or data-loss/eviction risk. |
| **High** | A whole workload is down or not progressing; customer-facing path broken. |
| **Medium** | Single pod degraded but the workload still serves; self-retrying. |
| **Low** | Transient, cosmetic, or already resolved (report briefly, often suppressed). |

---

## Symptom playbook

### CrashLoopBackOff / `BackOff` — "Back-off restarting failed container"
- **Means:** the container starts then exits repeatedly; kubelet backs off restarts.
- **Confirm:** `kubectl logs <pod> -n <ns> --previous`; check exit code and
  `.status.containerStatuses[].lastState.terminated` (reason + exitCode).
- **Likely causes:** application error/panic on startup; bad config/env/secret; missing
  dependency or unreachable service; failing **liveness** probe killing a healthy-but-slow
  app; exit code 137 = OOM (see OOMKilled); exit code 1/2 = app error.
- **Remediation:** fix the app/config; if a liveness probe is too aggressive, relax
  `initialDelaySeconds`/`failureThreshold`; verify required secrets/configmaps exist.

### ImagePullBackOff / ErrImagePull / InvalidImageName / ErrImageNeverPull
- **Means:** the image can't be pulled.
- **Confirm:** `kubectl describe pod` → the event message names the exact failure; check
  `.spec.containers[].image`.
- **Likely causes:** wrong image name/tag (typo, tag doesn't exist); private registry with
  no/expired `imagePullSecrets`; registry rate limit (Docker Hub) or outage; node can't
  reach the registry; `imagePullPolicy: Never` with the image absent on the node.
- **Remediation:** correct the tag; add/refresh the pull secret; mirror/cache the image;
  check node→registry connectivity/egress policy.

### OOMKilled (container `lastState`), `OOMKilling` event
- **Means:** container exceeded its memory limit and was killed (exit 137).
- **Confirm:** `kubectl describe pod` → `Last State: Terminated, Reason: OOMKilled`; compare
  `resources.limits.memory` vs actual usage (`kubectl top` / Prometheus working-set).
- **Likely causes:** limit too low for real workload; memory leak; load spike; JVM/heap not
  sized to the cgroup limit.
- **Remediation:** raise the memory limit/request, or fix the leak; for the JVM set
  `-XX:MaxRAMPercentage`; consider a VPA recommendation.

### Unhealthy — "Liveness/Readiness/Startup probe failed"
- **Means:** a probe returned failure. Readiness → pod removed from Service endpoints;
  Liveness → container restarted; Startup → blocks the others until it passes.
- **Confirm:** probe definition in the spec; hit the path/port from inside
  (`kubectl exec`); correlate with app logs.
- **Likely causes:** wrong port/path/scheme; thresholds too tight for a slow-starting app;
  app genuinely unhealthy or overloaded; dependency the probe checks is down.
- **Remediation:** fix the endpoint; tune `initialDelaySeconds`/`periodSeconds`/
  `failureThreshold`; add a `startupProbe` for slow starts.

### FailedScheduling — "0/N nodes are available"
- **Means:** the scheduler can't place the pod. The message lists the *reasons per node*.
- **Confirm:** read the describe message verbatim — it's specific (e.g. "Insufficient cpu",
  "node(s) had taint {…}", "didn't match node selector/affinity", "had volume node
  affinity conflict", "pod has unbound immediate PersistentVolumeClaims").
- **Likely causes:** insufficient CPU/memory; taints without matching tolerations;
  nodeSelector/affinity/anti-affinity unsatisfiable; topology/zone PVC mismatch;
  PVC unbound; too many pods per node.
- **Remediation:** scale/add nodes (or enable autoscaler); lower requests; add tolerations;
  fix selectors/affinity; ensure a default StorageClass / bound PVC.

### FailedMount / FailedAttachVolume / `Multi-Attach error`
- **Means:** a volume couldn't be attached or mounted.
- **Confirm:** `kubectl describe pod`; `kubectl get pvc -n <ns>` (Bound?);
  `kubectl get pv`; check the CSI driver pods.
- **Likely causes:** PVC unbound / no provisioner / no default StorageClass; RWO volume
  still attached to another node (Multi-Attach); CSI driver down; secret/configmap volume
  references a missing object; zone mismatch between pod and volume.
- **Remediation:** fix the PVC/StorageClass; ensure the old pod released the RWO volume;
  restart/repair the CSI driver; create the missing secret/configmap.

### FailedCreate (controllers) / quota / admission
- **Means:** a ReplicaSet/Job/StatefulSet couldn't create pods.
- **Confirm:** describe the controller; read the message.
- **Likely causes:** `exceeded quota` (ResourceQuota); blocked by an admission webhook or
  Pod Security admission; PodDisruptionBudget; service account / RBAC; webhook backend down.
- **Remediation:** raise/adjust the quota; fix the manifest to satisfy the policy; check the
  validating/mutating webhook's backend health.

### FailedCreatePodSandBox / network plugin errors
- **Means:** the runtime/CNI couldn't set up the pod sandbox.
- **Likely causes:** CNI plugin (Calico/Cilium/etc.) unhealthy on the node; IP exhaustion in
  the subnet; container runtime issues.
- **Remediation:** check CNI daemonset pods on the node; node IP/IPAM capacity; runtime logs.

### Node-level: NodeNotReady, NodeHasDiskPressure / MemoryPressure, Evicted, Rebooted
- **Means:** node health problem; pods may be evicted or unschedulable.
- **Confirm:** `kubectl describe node <node>` → Conditions; `kubectl get pods -A -o wide |
  grep <node>`.
- **Likely causes:** disk full (image/log/ephemeral); memory pressure; kubelet/network down;
  underlying VM issue.
- **Remediation:** free disk (prune images/logs), add capacity, cordon+drain for repair;
  this is usually **High/Critical** because it affects every pod on the node.

### HPA: FailedGetResourceMetric / FailedComputeMetricsReplicas
- **Means:** the HorizontalPodAutoscaler can't read metrics, so it won't scale.
- **Likely causes:** metrics-server not installed/healthy; custom metrics adapter down;
  missing resource requests (HPA on CPU% needs requests set).
- **Remediation:** install/repair metrics-server; set CPU/memory requests; verify the
  custom/external metrics API.

### Preempted / Killing
- `Killing` is often part of normal termination (frequently `Normal`, not `Warning`).
- `Preempted` means a higher-priority pod took the resources — check PriorityClasses and
  whether capacity is chronically short.

---

## Output format for the triage report

Per distinct issue, keep it tight:

- **What & where:** `<kind>/<name>` in `<ns>` — `<reason>` (×count, since `<ts>`).
- **Severity:** Critical / High / Medium / Low (per the rubric).
- **Investigation:** the trail — 2–5 lines of `command → decisive finding`, e.g.
  `describe pod → Last State: OOMKilled (137)` · `logs --previous → java.lang.OutOfMemoryError`
  · `rollout history → rev 7, 11m ago`. Decisive snippets only — never full logs/dumps.
- **Recent change:** what changed and when, and whether it lines up with the alert's onset —
  e.g. *"deploy rev 7 rolled out 11m ago, ~2m before onset"* — or *"no recent change (not
  deploy-related)."* Include the correlating commit/PR only if a GitHub tool surfaced it.
- **Class:** exactly one root-cause class keyword —
  `oom | crashloop | image-pull | scheduling | node-pressure | config | quota | network | app-error | unknown`
  (machine-readable: it becomes `work.category` in the triage's work-telemetry record).
- **Root cause:** hypothesis + confidence, **citing the Investigation lines above**.
- **Suggested action:** immediate mitigation + durable fix; flag anything needing approval.
- **Watch / escalate:** what to monitor and the threshold for paging a human.
- **Open in Lens:** *(only when a cluster specifier was provided — see "Deep links" below)* an
  https web-launcher link (Markdown link, not code) to the resource; link the failing object
  and, when useful, its owning workload. Omit this line entirely if no specifier is available.

Lead with the highest severity. Collapse repeats. Don't dump raw event lines or full logs —
quote only the decisive snippet.

---

## Deep links to Lens Desktop (via the web launcher)

Add an **Open in Lens** link to each resource **only when your task instruction gives you a
cluster specifier**. If it does not, **omit the link** — a wrong link is worse than none (the
agent's kubeconfig server URL often differs from the user's Lens behind a tunnel).

**Emit the `https://` web-launcher URL, NOT a raw `lens://` URL.** A raw `lens://` link is not
clickable in Slack (custom schemes aren't linkified) and is stripped by the web UI's markdown
sanitizer. The launcher is `https://`, so it's clickable everywhere and hands off to Lens
Desktop (with a "download Lens" fallback if it isn't installed).

**Build it in two steps:**

1. Build the inner `lens://` URL — it MUST start with `lens://app/open/`:
   ```
   lens://app/open/<CONNECTION_TYPE>/<CLUSTER_SPECIFIER>/cluster<LIST_APIBASE>?kube-details=<URL_ENCODED_SELFLINK>
   ```
   (`<LIST_APIBASE>` starts with `/api…`, so there's no extra slash after `cluster`.)

   **Any other host/shape fails INSIDE Lens Desktop with `Error: invalid host`** — the launcher
   page passes the URL through, so the failure only surfaces after the hand-off. In particular,
   do NOT invent frontend-route-style URLs like
   `lens://cluster/<hash>/workloads/deployment/<ns>/<name>` — that is Lens's internal SPA route,
   not a protocol URL, and it does not route.
2. Wrap it in the launcher, URL-encoding the **whole** inner URL once:
   ```
   https://app.k8slens.dev/lens-launcher?c=<encodeURIComponent(inner lens:// URL)>
   ```

**Render it as a Markdown link — never in backticks or a code block** (code spans aren't
clickable): `- **Pod `demo/web-1`** — [Open in Lens](https://app.k8slens.dev/lens-launcher?c=…)`

**CLUSTER_SPECIFIER / CONNECTION_TYPE** — use exactly what your instruction provides
(`clusterSpecifier=…`, `connectionType=…`); never recompute or guess.

> Operator note (not the agent's job): `LENS_CLUSTER_SPECIFIER` = `sha256(<the server URL the
> user's Lens uses>)[:32]` for a `direct` cluster, or the cluster's `metadata.id` with
> `LENS_CONNECTION_TYPE=teamwork`. The cluster must already exist in the user's Lens catalog.

**⚠️ Two DIFFERENT path forms in one URL — this is the #1 mistake:**

**`<LIST_APIBASE>`** selects the list tab and is the kind's **version-LESS `apiBase`** (NOT the
bare plural, NOT the versioned selfLink). Lens matches this string exactly against its
built-in resource names, so it must be:
- **core** (Pod, Service, ConfigMap, Secret, PVC, Node, Event…): `/api/<plural>` — e.g.
  `/api/pods`, `/api/services`, `/api/nodes`, `/api/persistentvolumeclaims`.
- **grouped** (drop the version): `/apis/<group>/<plural>` — e.g. `/apis/apps/deployments`,
  `/apis/apps/replicasets`, `/apis/apps/statefulsets`, `/apis/apps/daemonsets`,
  `/apis/batch/jobs`, `/apis/batch/cronjobs`.

  A bare plural like `/deployments` is WRONG — it resolves to `/api/deployments`, which matches
  nothing → the list renders empty (even though the details panel still opens).

**`kube-details`** is the object's **FULL versioned selfLink** (`.metadata.selfLink` is gone in
modern k8s, so build it), URL-encoded:
- **core/v1**: namespaced → `/api/v1/namespaces/<ns>/<plural>/<name>`; cluster-scoped (Node) →
  `/api/v1/<plural>/<name>`.
- **grouped**: `/apis/<group>/<version>/namespaces/<ns>/<plural>/<name>` (e.g.
  `/apis/apps/v1/namespaces/<ns>/deployments/<name>`).
- (Unsure of group/plural/version? `kubectl api-resources`.)

So for a Deployment: `LIST_APIBASE=/apis/apps/deployments` (no version) but
`kube-details=/apis/apps/v1/namespaces/<ns>/deployments/<name>` (with version).

**Example** — Deployment `demo/broken-config`, specifier `36e0cf76…`:
- inner: `lens://app/open/direct/36e0cf76e1856f448c7378f7fd27f711/cluster/apis/apps/deployments?kube-details=%2Fapis%2Fapps%2Fv1%2Fnamespaces%2Fdemo%2Fdeployments%2Fbroken-config`
- link: `[Open in Lens](https://app.k8slens.dev/lens-launcher?c=lens%3A%2F%2Fapp%2Fopen%2Fdirect%2F36e0cf76e1856f448c7378f7fd27f711%2Fcluster%2Fapis%2Fapps%2Fdeployments%3Fkube-details%3D%252Fapis%252Fapps%252Fv1%252Fnamespaces%252Fdemo%252Fdeployments%252Fbroken-config)`

---

## Safety

The agent may have **write** access to the cluster. Default to **read-only** diagnosis.

- **Never** run mutating commands (`delete`, `scale`, `rollout restart`, `edit`, `apply`,
  `drain`, `cordon`, `patch`) without **explicit user confirmation** in the conversation.
- Proposing a fix is good; executing a destructive one unprompted is not.
- When you recommend a mutation, show the exact command so the user can approve it verbatim.
