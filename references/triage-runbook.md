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
5. **Form a root-cause hypothesis** with a confidence level. Say what you're unsure about.
6. **Recommend action**: an immediate mitigation *and* a durable fix. Separate "safe to do
   now" from "needs human approval."
7. **State what to watch** and the escalation threshold.

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
- **Root cause:** hypothesis + confidence; cite the evidence (log line, describe field).
- **Suggested action:** immediate mitigation + durable fix; flag anything needing approval.
- **Watch / escalate:** what to monitor and the threshold for paging a human.
- **Open in Lens:** a `lens://` deep link to the resource (see "Deep links" below) so the
  user can jump straight to it — link the failing object and, when useful, its owning workload.

Lead with the highest severity. Collapse repeats. Don't dump raw event lines or full logs —
quote only the decisive snippet.

---

## Deep links to Lens Desktop (`lens://`)

Attach a `lens://` link to each resource you report so the user can open it directly in
Lens Desktop. Format:

```
lens://app/open/direct/<CLUSTER_SPECIFIER>/cluster/<RESOURCE_TAB>?kube-details=<URL_ENCODED_API_PATH>
```

**CLUSTER_SPECIFIER** — for a normal kubeconfig ("direct") cluster it is
`sha256(<server URL>)[:32]`. Compute it once from the active kubeconfig:

```bash
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
SPECIFIER=$(printf '%s' "$SERVER" | sha256sum | cut -c1-32)
```

Lens finds the cluster by hashing each catalog cluster's server address and matching this
value, so **the cluster must already be in the user's Lens catalog and its server URL must
match** what you hashed. If the agent reaches the cluster via a different address than the
user's Lens does, the link still opens Lens but won't resolve the cluster — degrade to a
cluster/list link (drop `kube-details`). If `LENS_CLUSTER_SPECIFIER` / `LENS_CONNECTION_TYPE`
are provided in the environment, use those instead of computing. For Lens Spaces clusters use
`.../open/teamwork/<cluster metadata.id>/...`.

**RESOURCE_TAB** — the resource's plural: `pods`, `deployments`, `replicasets`,
`statefulsets`, `daemonsets`, `jobs`, `services`, `nodes`, `persistentvolumeclaims`, …

**kube-details** — the URL-encoded API path of the specific object (`.metadata.selfLink` is
gone in modern k8s, so build it):
- **core/v1** (Pod, Service, ConfigMap, Endpoints, PVC, Event): namespaced →
  `/api/v1/namespaces/<ns>/<plural>/<name>`; cluster-scoped (e.g. Node) → `/api/v1/<plural>/<name>`.
- **grouped** (Deployment/ReplicaSet/StatefulSet/DaemonSet → `apps/v1`; Job/CronJob →
  `batch/v1`; Ingress → `networking.k8s.io/v1`): `/apis/<group>/<version>/namespaces/<ns>/<plural>/<name>`.
- URL-encode it — every `/` becomes `%2F`. (Unsure of the group/plural? `kubectl api-resources`.)

**Examples:**
- Pod: `lens://app/open/direct/<SPEC>/cluster/pods?kube-details=%2Fapi%2Fv1%2Fnamespaces%2Fdefault%2Fpods%2Fweb-1`
- Deployment: `lens://app/open/direct/<SPEC>/cluster/deployments?kube-details=%2Fapis%2Fapps%2Fv1%2Fnamespaces%2Fdefault%2Fdeployments%2Fweb`
- Fallback (open the list only, no details): `lens://app/open/direct/<SPEC>/cluster/pods`

Render as a markdown link in the report, e.g.
`Pod \`default/web-1\` — [open in Lens](lens://app/open/direct/<SPEC>/cluster/pods?kube-details=%2Fapi%2Fv1%2Fnamespaces%2Fdefault%2Fpods%2Fweb-1)`.

---

## Safety

The agent may have **write** access to the cluster. Default to **read-only** diagnosis.

- **Never** run mutating commands (`delete`, `scale`, `rollout restart`, `edit`, `apply`,
  `drain`, `cordon`, `patch`) without **explicit user confirmation** in the conversation.
- Proposing a fix is good; executing a destructive one unprompted is not.
- When you recommend a mutation, show the exact command so the user can approve it verbatim.
