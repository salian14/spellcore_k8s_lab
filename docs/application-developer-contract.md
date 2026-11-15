# spellcore_k8s_lab — application developer contract

**Version 1.0 · 2026-11-14 · canonical copy:**
<https://github.com/salian14/spellcore_k8s_lab/blob/bifrost/docs/application-developer-contract.md>

This is the agreement between the **lab** (the cluster and its platform
services, run by the lab owner) and a **tenant** (an application developer —
human or agent — deploying a workload onto it). It is self-contained: hand it
to an agent as-is, or reference it from that agent's `CLAUDE.md` / `AGENTS.md`.

MUST, MUST NOT, SHOULD and MAY are used in the RFC 2119 sense. Clauses are
numbered so they can be cited. If a copy of this file disagrees with the
canonical one above, the canonical one wins; if the live cluster disagrees
with either, stop and tell the lab owner (§12).

## 1. The one thing to understand first

**1.1** There is exactly one credential for this cluster: the
`spellcore-k8s-lab` kubectl context on the lab workstation, and it is
**cluster-admin**. There is no per-tenant RBAC, no `ResourceQuota`, no
`LimitRange`, no Pod Security admission and no default-deny `NetworkPolicy`.

**1.2** Nothing in the cluster will stop you from breaking it or another
tenant. Every limit in this document is therefore a rule you keep, not one
that is enforced for you. "It let me" is never evidence that something was
allowed.

## 2. What the lab is

| Fact | Value |
| --- | --- |
| Kubernetes | 1.35.2 (`kubeadm`), Calico CNI (enforces `NetworkPolicy`) |
| Nodes | `k8s-control` `192.168.56.10` (tainted, not schedulable), `k8s-worker1` `.11`, `k8s-worker2` `.12` |
| Schedulable capacity | 2 nodes, about 8 vCPU / 15 Gi **in total, shared with the platform and every other tenant** |
| Network | `192.168.56.0/24`, NAT'd. Reachable **only from the lab workstation**. Outbound internet works; nothing inbound |
| kubectl context | `spellcore-k8s-lab` (API server `https://192.168.56.10:6443`) |
| Default StorageClass | `local-path` (see §7) |
| Service mesh | Istio 1.30.4, sidecar mode, mTLS `PERMISSIVE` |
| Autoscaling | metrics-server is installed: `kubectl top` and `HorizontalPodAutoscaler` work |

**2.1 No durability, no SLA.** The lab is rebuilt from nothing with
`terraform destroy` / `apply` at the lab owner's discretion and without
notice. That deletes every workload, volume, bucket, metric, trace and log.
Your deployment MUST be reproducible from your own repository, and nothing
you cannot afford to lose may exist only in the lab.

**2.2 It is a lab.** Every platform credential is a published default, most
endpoints are plain HTTP, and all tenants share one admin credential. You
MUST NOT put real secrets, production credentials or personal data in it.

## 3. What the lab provides

| Service | Address | Notes |
| --- | --- | --- |
| Ingress gateway (HTTP) | `http://192.168.56.10:30880` | Shared Istio gateway; `404` means up with nothing routed. §6 |
| OTLP ingest | `otel-collector.observability.svc.cluster.local:4317` (gRPC), `:4318` (HTTP) | In-cluster, no TLS, no auth. §8 |
| Grafana | `http://192.168.56.10:30300` | `admin` / `lab-observability` |
| Prometheus | `http://192.168.56.10:30090` | `/targets` and raw PromQL |
| Argo CD | `http://192.168.56.10:30800` | `admin` / `lab-argocd`. How you deploy. §5.1 |
| S3 object store | `object-store.platform.svc.cluster.local:8333` | By request only. §7.4 |

Every NodePort also answers on `192.168.56.11` and `.12`.

**3.1 Not provided.** Do not design for any of these: DNS names or TLS
certificates for your app; a `LoadBalancer` implementation (such Services
stay `<pending>` forever); an Ingress controller; an image registry for
tenants (§5.3); cert-manager; a secrets
manager; the Prometheus Operator CRDs (`ServiceMonitor`, `PodMonitor`,
`PrometheusRule` do not exist); Alertmanager; collection of pod
`stdout`/`stderr` into Loki; backups; `ReadWriteMany` volumes.

## 4. Your namespace, and everything that is not yours

**4.1** You get **one namespace per application**, named after the
application (lowercase DNS label, e.g. `fathom`). Your Argo CD Application
creates it (§5.1); you own everything in it; you delete it when you are done
(§11). Before creating it,
check `kubectl get ns` — if the name exists and is not yours, pick another.

**4.2** Every namespaced resource you create MUST live in your namespace.
The following are **reserved** and you MUST NOT create, modify or delete
anything in them:

```
kube-system  kube-public  kube-node-lease  default
argocd  istio-system  istio-ingress  observability  platform
local-path-storage  tigera-operator  calico-system  calico-apiserver
```

`default` is for the lab's own examples and smoke tests, not for
applications. Another tenant's namespace is reserved to that tenant. The one
exception in `argocd` is your own `Application` (§4.4).

**4.3** You MUST NOT create, modify or delete **cluster-scoped** resources
without the lab owner's explicit approval: `CustomResourceDefinition`,
`ClusterRole`/`ClusterRoleBinding`, admission webhooks, `StorageClass`,
`PriorityClass`, `GatewayClass`, `Node` objects (labels, taints, cordon,
drain), `PersistentVolume`. The single exception is your own `Namespace`, created for you by Argo CD's
`CreateNamespace=true`.
If your application needs an operator or a CRD, that is a request (§12),
not something to install.

**4.4 Argo CD is a platform service, and you are expected to use it** — it
is how tenants deploy (§5.1). In the `argocd` namespace you own the
`Application` objects you register for your application, and nothing else.
You MUST NOT create, modify, sync, or delete any other `Application`
(`bootstrap`, `platform`, `observability` and their children are the lab's;
the rest are other tenants'), any `AppProject` or `ApplicationSet`, or Argo
CD's own configuration, repositories, accounts and settings — through
`kubectl`, the UI or the `argocd` CLI alike. The login is a shared admin, so
this too is a rule you keep (§1.2).

**4.5** You MUST NOT run `terraform`, `ansible-playbook`, `virsh` or `ssh`
against the lab's nodes or host, MUST NOT use the lab repository as your
Application's source, and MUST NOT change the lab repository
except by pull request (§12).

## 5. Deploying

**5.1 Deploy through Argo CD.** Your manifests — plain YAML, kustomize or a
Helm chart — live in your own git repository. You register one `Application`
pointing at them, and from then on **a commit is the deployment**: Argo CD
polls every 60 seconds (no webhook can reach the lab) and makes your
namespace match the repository.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app                      # your namespace name
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # deleting the Application removes what it deployed
spec:
  project: default
  source:
    repoURL: https://github.com/<owner>/<repo>.git
    targetRevision: main
    path: deploy
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    managedNamespaceMetadata:
      labels:
        istio-injection: enabled    # only if you want sidecars (§9.1)
```

Keep that manifest in your repository and register it once:

```bash
kubectl --context spellcore-k8s-lab -n argocd apply -f application.yaml
kubectl --context spellcore-k8s-lab -n argocd get application my-app   # Synced / Healthy
```

- **Name.** The `Application` MUST be named after your namespace, or
  `<namespace>-<component>` if you need more than one. Check
  `kubectl -n argocd get applications` first; never reuse an existing name —
  applying over someone else's `Application` redeploys their workload from
  your repository.
- **Destination.** MUST be the in-cluster server and your own namespace, and
  every resource your source renders MUST land in that namespace. The
  `default` AppProject is the only project and restricts nothing, so Argo CD
  will happily sync a `ClusterRole` or a manifest hard-coded to another
  namespace — §4.2 and §4.3 still apply to what your repository contains.
- **Source.** MUST be your own repository, reachable from the cluster over
  public HTTPS. A private repository needs a credential stored in `argocd`,
  which is a real secret in a lab that should hold none (§2.2): request it
  (§12) with a read-only, single-repository deploy key. Pin Helm chart
  versions; `targetRevision` SHOULD be a branch you control or a tag, not
  someone else's moving branch.
- **Sync policy.** SHOULD be automated with `prune` and `selfHeal`, as above.
  You MAY refresh or sync **your own** Application from the UI or the CLI
  (`argocd login 192.168.56.10:30800 --username admin --password lab-argocd --plaintext`).
- **`kubectl` is for looking, not for deploying.** Read, `logs`, `exec`,
  `port-forward` and throwaway debug pods (`kubectl run --rm`) in your
  namespace are fine. Anything meant to persist goes through git — with
  `selfHeal` a hand edit is reverted within a minute, and without it you have
  drift nobody can reproduce after a rebuild (§2.1). Whenever you do use
  `kubectl` or `helm`, name `--context spellcore-k8s-lab` (`--kube-context`
  for Helm) and the namespace explicitly; never rely on the current context,
  which may point at a different cluster.
- **Argo CD renders, it does not install.** Helm charts go through
  `helm template`: `lookup` sees an empty cluster and Helm hooks become sync
  hooks. Large objects (dashboard ConfigMaps near the 1 MiB limit) need the
  `ServerSideApply=true` sync option. Use `argocd.argoproj.io/sync-wave`
  annotations if your resources need ordering.

**5.2 Preflight.** Before your first deploy in a session, confirm the lab is
the lab and is healthy. If any of these fails, stop (§12) — do not repair it:

```bash
kubectl --context spellcore-k8s-lab get nodes        # three nodes, all Ready
kubectl --context spellcore-k8s-lab get sc           # local-path (default)
kubectl --context spellcore-k8s-lab -n argocd get applications   # the lab's own: Synced / Healthy
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.10:30880/   # 404, or a route
```

**5.3 Images come from a public registry, not from the lab.** Publish your
application's images to a registry outside the lab — GHCR (`ghcr.io`), Quay,
a cloud provider's registry, Docker Hub — from your own repository's build,
and reference them from there. The nodes pull through NAT, so any public
registry works, and an image that lives outside the lab survives a rebuild
(§2.1) and matches what the commit says was deployed.

- You MUST pin a specific tag or, better, a digest. No `latest`, and no tag
  you later overwrite: Argo CD sees no change in git and deploys nothing.
- Images SHOULD be publicly pullable. A private image needs an
  `imagePullSecret`, which is a real credential in a lab that should hold
  none (§2.2): request it (§12), scope it read-only to that one repository,
  and never commit it to git.
- All nodes share one outbound address, so anonymous Docker Hub pulls hit its
  rate limit quickly; prefer a registry that does not throttle anonymous
  pulls for anything you pull often.
- The lab's own registry (`registry.lab:5000`) is **not a tenant service**.
  It is plain HTTP with no auth, runs on the workstation separately from the
  cluster, may not be up, and is not rebuilt with the lab. You SHOULD NOT
  reference it from application manifests; using it at all (an image that
  genuinely cannot be published, say) needs approval, and you MUST NOT
  overwrite or delete anything in it that is not yours.

**5.4 Every container MUST declare CPU and memory `requests` and a memory
`limit`.** Nothing enforces a quota, so an unbounded pod starves the platform
and evicts neighbours. Size for a lab: tens of millicores and tens to low
hundreds of Mi per container, one replica unless you are testing replication.
If your application needs more than about 1 vCPU / 2 Gi in total requests,
ask first.

**5.5** Pods MUST NOT tolerate the control-plane taint, use `hostNetwork`,
`hostPID`, `hostPort`, `hostPath` volumes, or `privileged`/added
capabilities. `DaemonSet`s need approval.

**5.6** Workloads SHOULD carry `app.kubernetes.io/name` (and
`app.kubernetes.io/version`), name their Service ports by protocol (`http`,
`grpc`), and define readiness probes. The port name is what makes the mesh
treat traffic as HTTP rather than opaque TCP.

## 6. Exposing an application

**6.1 Use the shared ingress gateway.** It is the supported way to reach an
application from the workstation. In your namespace, create an Istio `Gateway`
with `selector: {istio: ingressgateway}` and a `VirtualService` bound to it:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: my-app}
spec:
  selector: {istio: ingressgateway}
  servers:
    - port: {number: 80, name: http, protocol: HTTP}
      hosts: ["*"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: my-app}
spec:
  hosts: ["*"]
  gateways: [my-app]
  http:
    - match: [{uri: {prefix: /my-app/}}]
      rewrite: {uri: /}
      route: [{destination: {host: my-app, port: {number: 8080}}}]
```

**6.2** There is no DNS, so every tenant shares host `*` and is told apart by
**path prefix**. Your prefix MUST be `/<your-namespace>/`. You MUST NOT match
`/`, an empty prefix, or any prefix outside your own — overlapping matches
across tenants resolve in no defined order. Your application therefore has to
work when served under a sub-path.

**6.3 NodePorts.** You SHOULD NOT create `NodePort` Services; use the gateway.
If you genuinely need one (a non-HTTP protocol, say), get approval, set the
port explicitly, and never use one already taken. Reserved today:

| Port | Owner |
| --- | --- |
| `30080` | fathom |
| `30090` | Prometheus |
| `30300` | Grafana |
| `30800`, `30443` | Argo CD |
| `30880`, `30843` | Istio ingress gateway (HTTP, HTTPS) |

Check `kubectl get svc -A | grep NodePort` for the live picture.

**6.4** HTTPS on `30843` has no certificate; bring your own via a `Gateway`
with `tls` if you need it. A Kubernetes Gateway API `Gateway`
(`gatewayClassName: istio`) is allowed in your namespace, but it deploys an
additional gateway pod on a randomly allocated NodePort — prefer §6.1.

## 7. State

**7.1** `PersistentVolumeClaim`s bind to `local-path`: a directory on the
root disk of whichever node your pod first lands on. The pod can never move
to the other node, access mode is `ReadWriteOnce`, and the data dies with the
node or the next rebuild (§2.1).

**7.2** The requested size is **not enforced** — a volume can fill the node's
disk and cause evictions for everyone. You MUST bound what you write
(retention, max size) inside the application, and SHOULD request no more than
a few Gi without asking.

**7.3** A Deployment that mounts a PVC MUST use `strategy: Recreate` (or be a
StatefulSet); `RollingUpdate` deadlocks on a `ReadWriteOnce` volume.

**7.4 Object storage is opt-in.** The S3 store issues each consumer its own
bucket-scoped identity, and buckets are not auto-created. To get one, request
it (§12) — it is a change to the lab repository under `gitops/platform/`. You
MUST NOT use another consumer's credentials or the store's `admin` identity.

## 8. Telemetry

Full how-to:
<https://github.com/salian14/spellcore_k8s_lab/blob/bifrost/docs/observability-for-developers.md>.
The obligations:

**8.1** Applications SHOULD export traces, metrics and logs over OTLP, and if
they do they MUST set `OTEL_SERVICE_NAME` — unique to the service and stable.
It is the join key for everything in Grafana.

```yaml
env:
  - {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://otel-collector.observability.svc.cluster.local:4317"}
  - {name: OTEL_EXPORTER_OTLP_PROTOCOL, value: grpc}
  - {name: OTEL_SERVICE_NAME, value: my-app}
  - {name: OTEL_PROPAGATORS, value: "tracecontext,baggage"}
  - {name: OTEL_RESOURCE_ATTRIBUTES, value: "service.version=0.1.0,deployment.environment.name=lab"}
```

Do not set `k8s.*` attributes; the collector adds them.

**8.2** `kubectl logs` output does **not** reach Loki. Logs you want in
Grafana MUST be exported over OTLP.

**8.3** The backends are shared and small (traces 72 h, logs 7 d, metrics
15 d on one 20 Gi volume). You MUST NOT push metrics more often than every
60 s, emit unbounded-cardinality labels (user IDs, request IDs, raw URLs), or
run load generators against the collector without approval.

**8.4** For a Prometheus-format endpoint, annotate the pod
(`prometheus.io/scrape: "true"`, `prometheus.io/port`). There is no
`ServiceMonitor`.

**8.5 Dashboards and alerts ship from your namespace** — in the same
repository, through the same Application — as ConfigMaps labelled `grafana_dashboard: "1"` / `grafana_alert: "1"`. One dashboard per
ConfigMap; every panel and alert query MUST pin its datasource UID
(`prometheus`, `loki` or `tempo` — an unpinned panel silently lands on
Tempo); alert rule `uid`s MUST be stable and prefixed with your application
name. You MUST NOT change Grafana through its UI or API (datasources, other
tenants' dashboards, notification policies), nor edit anything in the
`observability` namespace.

## 9. Service mesh

**9.1** To join the mesh, label **your own** namespace
`istio-injection=enabled` — through `managedNamespaceMetadata` on your
Application (§5.1); pods created afterwards get a sidecar (`READY 2/2`). Each sidecar adds 50m CPU / 64 Mi of requests to the
pod — count it in §5.4.

**9.2** Meshed pods get request metrics (`istio_requests_total`), access logs
(`kubectl logs <pod> -c istio-proxy`) and gateway/sidecar trace spans with no
work. Joining those spans into one trace through your service is your job:
propagate the `traceparent` header (§8.1 does this for instrumented code).

**9.3** Istio resources (`VirtualService`, `DestinationRule`,
`PeerAuthentication`, `AuthorizationPolicy`, `Telemetry`, `Sidecar`,
`EnvoyFilter`…) MUST be in your namespace and MUST only select your own
workloads and hosts. Nothing in `istio-system` — a resource there is
mesh-wide. Do not assume mTLS `STRICT`.

**9.4** `NetworkPolicy` in your own namespace is welcome. Keep ingress from
`istio-ingress` open if you use the gateway, and from `observability` if
Prometheus scrapes you.

## 10. Being a good neighbour

**10.1** Calls to other tenants' Services and to platform Services other than
those listed in §3 need the owner's agreement, even though the network allows
them.

**10.2** Clean up what you no longer use — failed Jobs, test namespaces,
Applications for experiments that are over. Leave nothing running that you would
not be able to explain.

**10.3** If you find something broken, misconfigured or insecure in the
platform or in another tenant's namespace, report it (§12). Do not fix it.

## 11. Teardown

In this order:

1. Remove alert rules explicitly. Deleting an alert ConfigMap does **not**
   delete the rule; commit a `grafana_alert` ConfigMap containing
   `deleteRules: [{orgId: 1, uid: <your-rule-uid>}]`, let it sync, confirm the
   rule is gone in Grafana, then continue.
2. Delete **your** Application —
   `kubectl --context spellcore-k8s-lab -n argocd delete application <your-app>`.
   With the finalizer from §5.1 that removes everything it deployed. Deleting
   the namespace first instead just makes Argo CD recreate it.
3. `kubectl --context spellcore-k8s-lab delete namespace <your-namespace>` —
   Argo CD does not remove a namespace it created, and this takes any
   leftover PVCs with it.
4. Anything you were granted outside your namespace (a NodePort, buckets and
   an S3 identity, a repository or image-pull
   credential, a CRD): tell the lab owner it can be reclaimed.

## 12. Asking for something, reporting something, and when to stop

**12.1** Anything this contract says needs approval, or does not cover, goes
to the lab owner **before** you act — as an issue or a pull request on
<https://github.com/salian14/spellcore_k8s_lab>. Pull requests target the
`bifrost` branch from a branch named `agent/<feat|bug|chore|refactor|docs>/<short-description>`;
you never push to `bifrost` or `asgard`, and never merge.

**12.2 Stop and report, rather than work around, when:** a preflight check
fails (§5.2); a platform service in §3 is down or behaves differently from
this document; you would have to touch a reserved namespace or a
cluster-scoped resource to proceed; your pods are `Pending` or evicted for
lack of capacity; or two clauses here seem to conflict. An unavailable
platform is a reason to wait, never a licence to repair it.

**12.3** What the lab owner undertakes in return: the facts in §2 and §3 are
kept true on `bifrost` or this document is updated in the same change; ports,
namespaces and endpoints listed here are not repurposed without a version
bump; and requests under §12.1 get an answer.

## 13. Checklist

Before you call a deployment done:

- [ ] Everything is in my one namespace; nothing reserved or cluster-scoped was touched (§4)
- [ ] It is deployed by my own Argo CD Application from my repository, which reports `Synced` / `Healthy`; nothing persistent was applied by hand (§5.1)
- [ ] The only thing I touched in `argocd` is that Application (§4.4)
- [ ] Every `kubectl` command named `--context spellcore-k8s-lab` (§5.1)
- [ ] Images are pulled from a public registry (not `registry.lab`), pinned by tag or digest (§5.3)
- [ ] Every container has CPU/memory requests and a memory limit, sidecar included in the total (§5.4, §9.1)
- [ ] Exposure is via the shared gateway under `/<my-namespace>/` only (§6)
- [ ] Volumes are bounded by the application and nothing irreplaceable lives in them (§2.1, §7)
- [ ] `OTEL_SERVICE_NAME` is set; dashboards and alerts pin datasource UIDs (§8)
- [ ] No real secrets anywhere (§2.2)
- [ ] The whole thing can be recreated from my repository after a lab rebuild (§2.1)
