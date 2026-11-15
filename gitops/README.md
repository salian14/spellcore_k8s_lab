# spellcore_k8s_lab — GitOps

Everything the cluster *runs* is declared here and deployed by
[Argo CD](https://argo-cd.readthedocs.io/). Ansible builds the cluster and
installs Argo CD (see [`ansible/README.md`](../ansible/README.md)); Argo CD
then reads this directory and makes the cluster match it. Today that is two
stacks: **platform** (shared services — the S3 object store) and
**observability** (Grafana, Tempo, Loki, Prometheus and the collector, which
consume it). Anything added later goes in beside them; see
[What goes where](#what-goes-where).

A commit to this directory on `bifrost` **is** a deployment. There is no
playbook to run and no `helm upgrade` to type: Argo CD polls the repository
every 60 seconds (`k8s_argocd_reconciliation_timeout`) and applies whatever
changed. A `kubectl edit` behind its back is reverted on the next poll.

## Layout

```
gitops/
├── bootstrap/                    # Helm chart: the app-of-apps root. The k8s_argocd role points Argo CD here.
│   ├── Chart.yaml
│   ├── values.yaml               # repoURL / targetRevision (overridden by Ansible), one entry per stack
│   └── templates/
│       ├── platform.yaml         # Application -> gitops/platform/apps        (wave 0)
│       └── observability.yaml    # Application -> gitops/observability/apps   (wave 1)
├── platform/                     # shared services, synced before every application stack
│   ├── apps/                     # Helm chart: one Application per service, ordered by sync wave
│   ├── credentials/              # object-store-identities: every S3 identity the store knows (plaintext -- see below)
│   └── object-store/             # SeaweedFS: Deployment, PVC, Service, NetworkPolicy
└── observability/                # an application stack: consumes the platform, owns nothing shared
    ├── apps/                     # Helm chart: one Application per component, ordered by sync wave
    │   ├── values.yaml           # chart repositories and pinned versions, retry policy
    │   └── templates/            # credentials, prometheus, tempo, loki, otel-collector, grafana, dashboards
    ├── values/                   # one values file per upstream Helm chart -- edit these to change the stack
    │   ├── prometheus.yaml
    │   ├── tempo.yaml
    │   ├── loki.yaml
    │   ├── otel-collector.yaml
    │   └── grafana.yaml
    ├── credentials/              # this stack's S3 identity (client side) and Grafana's admin login
    └── dashboards/               # kustomization + the seven dashboard JSON files, as labelled ConfigMaps
```

## How the hand-off works

1. `ansible/k8s-argocd.yml` installs Argo CD and applies **one** `Application`
   named `bootstrap`, pointed at `gitops/bootstrap` on the branch named by
   `k8s_argocd_bootstrap_repo_revision` (`bifrost` by default). That is the
   last thing Ansible does to the cluster.
2. `gitops/bootstrap` is a Helm chart whose templates are Applications, one per
   stack, ordered by sync wave: `platform` (wave 0), then `observability`
   (wave 1). Each points at `gitops/<stack>/apps`.
3. `gitops/<stack>/apps` is another Helm chart of Applications, one per
   component, each stamped with a sync wave of its own. Argo CD syncs wave 0,
   waits for it to report Healthy, then wave 1, and so on — the same ordering
   the old Ansible role got from `helm upgrade --wait`, without a controller
   in the loop.

The platform stack:

| Wave | Application | Source | Why here |
| --- | --- | --- | --- |
| 0 | `object-store-identities` | `platform/credentials/` | Every S3 identity the store knows about. Also creates the `platform` namespace. |
| 1 | `object-store` | `platform/object-store/` | Creates every consumer's buckets on startup; its readiness is what ends the wave — and, one level up, the platform stack. |

Then the observability stack:

| Wave | Application | Source | Why here |
| --- | --- | --- | --- |
| 0 | `credentials` | `observability/credentials/` | This stack's S3 identity and Grafana's login. Also creates the namespace. |
| 1 | `prometheus` | chart + `values/prometheus.yaml` | Tempo's metrics-generator remote-writes here from its first second. |
| 2 | `tempo` | chart + `values/tempo.yaml` | Needs the Secret; its bucket already exists, courtesy of the platform stack. |
| 2 | `loki` | chart + `values/loki.yaml` | Same. |
| 3 | `otel-collector` | chart + `values/otel-collector.yaml` | After the backends, so it isn't retrying against absent exporters. |
| 4 | `grafana` | chart + `values/grafana.yaml` | Its provisioned datasources name the Tempo, Loki and Prometheus Services. |
| 5 | `dashboards` | `observability/dashboards/` (kustomize) | After Grafana, so the sidecar is already watching. Synced with server-side apply. |

Every Application has automated sync with `prune` and `selfHeal`, a
`CreateNamespace=true` sync option, and a retry policy (five attempts, 15s
doubling to 3m) because the first sync of a fresh cluster races PVC binding
and image pulls.

**Why the app-of-apps layers are Helm charts.** The five chart-backed
Applications are [multi-source](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/):
the chart comes from its upstream repository, the values file from this one.
That second source has to name a repository URL and a revision, and with plain
YAML those would be hard-coded in every Application. Rendering the Applications
from a chart instead lets `repoURL` and `targetRevision` be passed in once, as
Helm parameters, from the `bootstrap` Application Ansible applies — so pointing
Ansible at a different branch moves the whole tree with it.

**Why the wave ordering works at all.** Argo CD removed health assessment of
`Application` resources from its defaults in 1.8, so out of the box every
Application is Healthy the instant it exists and the waves would all start at
once — across stacks as well as within one. The `k8s_argocd` role puts the
upstream-documented Lua health check back into `argocd-cm`
(`resource.customizations.health.argoproj.io_Application`). If the components
ever start syncing simultaneously, check that first.

## What goes where

Three layers, and the test for each is what it would mean to get it wrong:

| Layer | Lives in | Contains | Belongs here because |
| --- | --- | --- | --- |
| **Cluster** | Ansible (`ansible/`) | node prep, `kubeadm`, Calico, metrics-server, the `local-path` StorageClass, Argo CD itself | It has to exist before Argo CD can run, or Argo CD must never depend on it. Argo CD cannot install its own prerequisites, and `metrics.k8s.io` must not go down with a bad sync. Changing it means re-running a playbook. |
| **Platform** | `gitops/platform/` | shared services with a pod: the S3 object store today; a registry mirror, cert-manager, an ingress controller, MetalLB tomorrow | More than one stack consumes it, and it has no opinion about who. It runs on the cluster, so it is a workload and belongs under Argo CD — but it is synced before every application stack, has its own namespace, and issues each consumer its own credentials. |
| **Application** | `gitops/<stack>/` | the consumers: observability today | Owns nothing another stack needs. Reaches platform services by their `*.platform.svc.cluster.local` name and holds its own copy of the credentials it was issued. Can be deleted without taking a neighbour down. |

The storage question falls on both sides of the first line, which is why it
looked like one thing and is two. The **StorageClass provisioner**
(`local-path`) is cluster: every volume in every stack is claimed from it, and
Argo CD's own sync of the object store would sit `Pending` without it, so it
is Ansible. The **object store** (SeaweedFS's S3) is platform: it is a pod on a
volume, it has consumers rather than dependents, and the observability stack
is merely its first tenant.

If something new is hard to place, the tie-breakers: does Argo CD need it to
exist before it can sync anything at all? Ansible. Will a second stack want
it? Platform. Otherwise it goes in the stack that uses it.

## Making a change

Edit the file, commit, open a PR against `bifrost`. Once merged, Argo CD
notices within 60 seconds. Some examples:

| To change | Edit |
| --- | --- |
| Retention, volume sizes, NodePorts, scrape interval, resources | the matching file under `observability/values/` |
| A chart version | `observability/apps/values.yaml` (`charts.<name>.version`) |
| Grafana's login, or this stack's S3 keys | `observability/credentials/` (see [Credentials](#credentials)) |
| The object store's image or volume cap | `platform/object-store/deployment.yaml` |
| A new consumer of the object store (buckets + identity) | the three `TENANTS` markers under `platform/` (see [Adding a consumer](#adding-a-consumer)) |
| A bundled dashboard | the JSON under `observability/dashboards/` (see [Dashboards and alerts](#dashboards-and-alerts)) |

To force a sync instead of waiting for the poll, use the *Refresh* button in
the UI (<http://192.168.56.10:30800>, `admin` / `lab-argocd`) or:

```bash
argocd login 192.168.56.10:30800 --username admin --password lab-argocd --plaintext
argocd app get observability --refresh
argocd app list
```

Render before you push. Every chart here can be templated locally with the
same Helm the workstation already has, which catches most values mistakes
without a cluster:

```bash
# the app-of-apps layers
helm template bootstrap gitops/bootstrap
helm template platform gitops/platform/apps --set targetRevision=my-branch
helm template observability gitops/observability/apps --set targetRevision=my-branch
# an upstream chart with its values file (add the repo once: helm repo add grafana https://grafana.github.io/helm-charts)
helm template tempo grafana/tempo --version 1.24.4 -n observability -f gitops/observability/values/tempo.yaml
# the dashboards
kubectl kustomize gitops/observability/dashboards | grep -E '^  name:'
```

## Running a branch on the lab

The cluster tracks `bifrost`. To run a feature branch on it instead, push the
branch (Argo CD pulls from GitHub, not from your checkout — the lab network
can't see the workstation's git tree), then in `ansible/host_vars/k8s-control.yml`:

```yaml
k8s_argocd_bootstrap_repo_revision: agent/feat/my-change
```

and re-run the playbook:

```bash
ansible-playbook -i terraform/inventory.ini ansible/k8s-argocd.yml
```

That re-applies the `bootstrap` Application with the new revision, and every
Application under it follows on the next poll. Put the variable back (or delete
the override) and re-run to return to `bifrost`.

## The platform stack

Shared services with a pod. One today.

### The object store: SeaweedFS, and why not MinIO

The Ansible role deployed MinIO from `minio/minio` `5.4.0`. That is no longer
tenable: MinIO stripped the admin console from the community edition in May
2025, stopped publishing binaries and images in October 2025, and archived the
repository in April 2026. The source is still AGPL-3.0, but there are no
releases, no security fixes and no images — the chart pins an image from
December 2024 that will never be updated. The Loki chart already carries a
comment about the unresolved CVE in it.

Replacements considered, against what this lab needs — one pod, one
`local-path` volume, S3 with path-style addressing, buckets that exist before
Tempo and Loki start, and nothing that has to be typed into a shell after
`terraform apply`:

| | Licence | Verdict |
| --- | --- | --- |
| **SeaweedFS** (`weed mini`) | Apache-2.0 | **Chosen.** Actively released, single-process mode on one directory, S3 identities from a file, `-bucket` creates buckets at startup. Kubeflow's default object store. |
| Garage | AGPL-3.0 | Lightweight and well regarded, but the cluster layout has to be assigned by hand after the first start (`garage layout assign` / `apply`), and buckets and keys are created through its CLI. Automatable with a Job, but that is glue this lab would then own. |
| RustFS | Apache-2.0 | The closest MinIO drop-in (same API surface, works with `mc`), but still a release candidate (`1.0.0-rc.6`) at the time of writing. Worth revisiting once it is stable. |
| SeaweedFS Helm chart | Apache-2.0 | Deploys master, volume server and filer as separate StatefulSets with a PVC each — the distributed shape, for a lab that wants the standalone one. |
| Rook/Ceph | Apache-2.0 | Far too heavy for two schedulable nodes. |

How it's wired (all in `platform/object-store/`):

- **`weed mini`** runs master, volume server, filer and S3 gateway in one
  process with everything under `/data` on the PVC. `-ip=127.0.0.1` is the
  address the components use to reach each other (stable across pod
  restarts); `-ip.bind=0.0.0.0` is what the listeners actually bind.
- **Buckets** come from `-bucket=tempo,loki-chunks,loki-ruler`, created on
  startup if absent — every consumer's, declared here. `-s3.autoCreateBucket`
  is off, so a consumer writing to an undeclared bucket gets `NoSuchBucket`
  rather than a silently new one.
- **Identities** are rendered by an init container into SeaweedFS's S3
  identity JSON from the `object-store-identities` Secret: an unscoped
  `admin` for humans, and one identity per consumer whose actions are scoped
  to its buckets (`Read:tempo`, `Write:tempo`, …). SeaweedFS has no flag or
  environment variable for keys; a file is the only route. The observability
  identity can read, write and list only its own buckets and cannot create
  any — other buckets' *names* still show up in `ListBuckets`, their contents
  do not.
- **The volume cap is set by hand**: `-master.volumeSizeLimitMB=1024` and
  `-volume.max=20`, matching the 20Gi PVC. Left at the default (auto-size to
  free disk) SeaweedFS would size itself to the node's root filesystem, since
  `local-path` enforces no quota.
- **A NetworkPolicy closes every port but S3 (8333) and metrics (9327).**
  `weed mini` also listens on its master, volume, filer, admin and gRPC ports,
  none of which authenticate — the filer's HTTP API is unauthenticated
  read/write to every object. Calico enforces the policy; a CNI that ignores
  NetworkPolicy would leave those open cluster-wide.
- **It persists its own options** to `/data/mini.options` on each start.
  Command-line flags win over that file and are written back into it, so a
  change to `deployment.yaml` takes effect on the next rollout; the file is
  just a record.
- The Service is named `object-store`, not `seaweedfs`, so the endpoint
  consumers point at — `object-store.platform.svc.cluster.local:8333` —
  survives another swap.
- **Verified** before this landed, outside Kubernetes: SeaweedFS `4.47`, Tempo
  `2.9.0` and Loki `3.6.12` started together in Docker with the exact configs
  the charts render from the observability values files, using the
  bucket-scoped `observability` identity; a trace and a log line pushed to
  each were flushed to the buckets (Tempo's parquet block, Loki's chunk) and
  queried back, with no S3 errors, and the same identity was refused on a
  bucket outside its scope. What that did *not* cover is the Kubernetes side
  — PVC binding, the NetworkPolicy, Argo CD's sync order — which needs a
  `terraform apply`.

### Adding a consumer

A new stack that wants object storage is issued its own identity, scoped to
its own buckets. Three edits under `platform/`, each marked `TENANTS`, then
one file in the consumer:

1. `platform/object-store/deployment.yaml` — add the buckets to `-bucket=…`.
2. Same file — add an identity to the init container's JSON, with
   `Read:`/`Write:`/`List:`/`Tagging:` actions on those buckets.
3. `platform/credentials/object-store-identities.yaml` — add the pair the
   identity reads.
4. In the consumer's `credentials/`, a Secret holding a copy of that pair,
   plus whatever wiring gets it into the consumer's config (Tempo and Loki use
   `-config.expand-env`; see the observability values files).

The object store pod restarts on the Deployment change (its strategy is
`Recreate`), creates the new buckets on the way up, and the new identity is
live. Existing consumers are unaffected: their identities and buckets are
untouched, and the restart costs them a few seconds of S3 retries.

## The observability stack

What it is and how to reach it is in the [README](../README.md#observability);
how to get an application's telemetry into it is
[`docs/observability-for-developers.md`](../docs/observability-for-developers.md).
This section is the reasoning behind how it's built.

### Why these charts and versions

| Component | Source | Version | appVersion |
| --- | --- | --- | --- |
| Object store | `chrislusf/seaweedfs` image, plain manifests | `4.47` | — |
| Traces | `grafana/tempo` | `1.24.4` | `2.9.0` |
| Logs | `grafana/loki` | `7.3.0` | `3.6.12` |
| UI | `grafana/grafana` | `10.5.15` | `12.3.1` |
| Collector | `open-telemetry/opentelemetry-collector` | `0.170.0` | `0.158.0` |
| Metrics | `prometheus-community/prometheus` | `29.25.0` | `v3.13.2` |
| Object state | `kube-state-metrics` (subchart of the above) | `8.3.0` | — |
| Host metrics | `prometheus-node-exporter` (subchart of the above) | `4.56.1` | — |

Versions are pinned so a re-provision months from now deploys what was tested.

- **`prometheus`, not `kube-prometheus-stack`.** The stack chart brings a
  CRD-installing operator, its own Grafana (a second one), and CRDs that
  `helm upgrade` will not update once installed. The plain server chart is the
  same monolithic-over-microservices call made for Tempo below. `alertmanager`
  and `prometheus-pushgateway` ship as subcharts and are **both disabled** —
  no alert routes are configured and nothing here pushes batch-job metrics.
- **`tempo`, not `tempo-distributed`.** Both ship appVersion `2.9.0`, but
  `tempo-distributed` is the microservices chart and would deploy eight
  separate components. The chart *name* is pinned in `apps/values.yaml`
  alongside the version so it can't drift.
- **Not `grafana/lgtm-distributed`.** It wraps the `-distributed` charts —
  roughly 30 pods — and was last published in November 2025.
- **`grafana/grafana` 10.5.15 is marked `deprecated: true` upstream**, and it
  is still the newest published version. It installs and works; it just isn't
  receiving updates, so the eventual migration is to the Grafana operator's
  `Grafana` CRD. Argo CD shows the deprecation warning in the sync log; ignore
  it.
- **kube-state-metrics and node-exporter are subcharts of the Prometheus
  release**, not Applications of their own, so `argocd app list` shows eight
  Applications for what `kubectl -n observability get pods` shows as ten-odd
  pods.

### Credentials

Every credential in this tree is **plaintext**: the S3 identities in
`platform/credentials/`, this stack's copy of its own in
`observability/credentials/`, and the Grafana admin password beside it. There
is no vault, no sealed-secrets and no SOPS in this repo, and the cluster sits
on an isolated lab network reachable only from the workstation — the same
posture as `lab_registry_scheme: "http"` in `ansible/group_vars/all.yml`, and
the same values the Ansible role used to carry in its defaults. Do not carry
this pattern into anything that isn't a lab. When it changes, the files under
`credentials/` are the ones to replace with `SealedSecret`s or SOPS-encrypted
manifests; nothing else references the values directly.

The S3 keys exist twice on purpose, the way they would with any real provider:
the **server side** is `object-store-identities` in the `platform` namespace,
where the pair is issued and scoped to buckets; the **client side** is
`object-store-credentials` in the consumer's namespace, holding a copy. The
two have to agree. Rotate on the platform side first, then the consumer.

- **Tempo and Loki** get the pair as environment variables
  (`S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY`, from the client Secret) and
  their config files carry `${...}` placeholders, expanded at startup by
  `-config.expand-env=true`. The values files therefore contain no secret.
  The names are deliberately not `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`:
  nothing here uses the SDK credential chain, and a name the SDK picks up
  implicitly is a name that can surprise.
- **The object store** renders the server-side Secret into its identity file
  (see [The platform stack](#the-platform-stack)).
- **Grafana** reads `grafana-admin` through the chart's `admin.existingSecret`.
  Do **not** instead set `security.admin_password` under `grafana.ini`: the
  chart's `assertNoLeakedSecrets` helper aborts the render when a sensitive
  key appears there in plaintext.

Argo CD does not restart pods for a Secret change on its own, so a rotation
is the two edits followed by
`kubectl -n platform rollout restart deploy/object-store` and
`kubectl -n observability rollout restart sts/tempo sts/loki`.

### Dashboards and alerts

Dashboards and Grafana-managed alert rules are **delegated to whoever owns the
workload**, not centralised in Grafana's values. The Grafana chart runs two
[`kiwigrid/k8s-sidecar`](https://github.com/kiwigrid/k8s-sidecar) containers
that watch the cluster for labelled ConfigMaps, write their contents into
Grafana's provisioning directories and POST the reload API:

| Sidecar | Watches for label | Payload |
| --- | --- | --- |
| `grafana-sc-dashboard` | `grafana_dashboard` | dashboard JSON |
| `grafana-sc-alerts` | `grafana_alert` | alerting provisioning YAML (`apiVersion: 1` plus `groups:` / `contactPoints:` / `policies:`) |

Both run with `searchNamespace: ALL`, so an application ships its own
observability alongside its own manifests, in its own namespace, with no
change here:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fathom-dashboards
  namespace: fathom
  labels:
    grafana_dashboard: "1"      # presence is what matches; the value is ignored
  annotations:
    grafana_folder: "Applications"
data:
  fathom-overview.json: |
    { ... dashboard JSON ... }
```

The seven cluster dashboards under `observability/dashboards/` use exactly
that mechanism rather than the chart's `dashboards:` values key — a
`configMapGenerator` turns each JSON file into one labelled ConfigMap. That is
deliberate: the base install exercises the delegation path, so it can't
quietly rot while only applications depend on it.

| Dashboard | Folder | Source |
| --- | --- | --- |
| Kubernetes / Views / Global | `Kubernetes` | [15757](https://grafana.com/grafana/dashboards/15757) |
| Kubernetes / Views / Namespaces | `Kubernetes` | [15758](https://grafana.com/grafana/dashboards/15758) |
| Kubernetes / Views / Nodes | `Kubernetes` | [15759](https://grafana.com/grafana/dashboards/15759) |
| Kubernetes / Views / Pods | `Kubernetes` | [15760](https://grafana.com/grafana/dashboards/15760) |
| Kubernetes / System / API Server | `Kubernetes` | [15761](https://grafana.com/grafana/dashboards/15761) |
| Kubernetes / System / CoreDNS | `Kubernetes` | [15762](https://grafana.com/grafana/dashboards/15762) |
| Node Exporter Full | `Nodes` | [1860](https://grafana.com/grafana/dashboards/1860) |

They were picked against what this cluster *actually* exposes, which rules out
most of the popular alternatives:

- **No `kubernetes-mixin` recording rules exist here.** Every
  `Kubernetes / Compute Resources / *` dashboard queries series like
  `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate`,
  which are *recording rules* shipped by `kube-prometheus-stack`'s operator.
  The plain Prometheus chart ships none of them, so those dashboards render
  empty. The `dotdc/grafana-dashboards-kubernetes` set above queries raw
  metrics only, which is why it works.
- **Everything scraped by annotation shares one `job` label.**
  kube-state-metrics, node-exporter and CoreDNS all land under
  `job="kubernetes-service-endpoints"`. Dashboards with `job="node-exporter"`
  hard-coded show nothing; the ones above populate `$job` from a
  `label_values()` query instead.
- **There is no `cluster` label.** The `dotdc` dashboards filter by
  `cluster="$cluster"`, which resolves to empty here. Harmless — in PromQL
  `cluster=""` matches series where the label is *absent*. Don't try to "fix"
  it with `global.external_labels`: those apply to remote-write and federation
  only, never to locally stored series.

Refreshing a dashboard is a re-download plus the same normalisation:

```bash
curl -sL https://grafana.com/api/dashboards/15757/revisions/latest/download \
  -o gitops/observability/dashboards/k8s-views-global.json
```

then strip `__inputs`/`__requires`, null the numeric `id`, and set the
`datasource` template variable's `current` to the `prometheus` UID — and bump
the `k8s-observability/source` annotation in `kustomization.yaml`. The comment
block at the top of that file says why each step matters.

### Known gotchas

- **Almost all workloads land on the workers — node-exporter is the exception.**
  `k8s-control` carries `node-role.kubernetes.io/control-plane:NoSchedule`, so
  the schedulable budget is two nodes, about 8 vCPU and 15Gi, not three. Don't
  add control-plane tolerations to spread the load; that puts Loki next to etcd.
  The node-exporter DaemonSet's chart-default tolerations let it run
  everywhere, which is exactly why all three nodes report host metrics.
- **`WaitForFirstConsumer` pins each volume to one node.** Once the object
  store's volume materialises on a worker, its pod can never be scheduled
  elsewhere. If that worker is destroyed the data is gone and the PVC has to
  be deleted by hand. This is also why the object store's Deployment uses the
  `Recreate` strategy: `RollingUpdate` would deadlock trying to bind a
  `ReadWriteOnce` volume from a surge pod on the other node. The same applies
  to Tempo, Loki, Prometheus and Grafana.
- **Prometheus does not use the object store.** It has no S3 backend, so its
  20Gi local-path volume is the only copy of the metrics, and retention is
  bounded by that volume and nothing else. Tempo and Loki keep only WAL
  locally; Prometheus keeps everything. Long-term metrics would mean Thanos or
  Mimir.
- **The pinned collector distro has no `prometheusremotewrite` exporter.**
  `otel/opentelemetry-collector-k8s:0.158.0` ships exactly `debug`, `nop`,
  `otlp`, `otlphttp`, `file`, `loadbalancing` and `otelarrow`, so the
  collector uses `otlphttp` into Prometheus 3's native OTLP receiver. Do
  **not** "fix" this by switching to the `contrib` image.
- **Three Prometheus feature flags are load-bearing, and all fail silently.**
  `web.enable-remote-write-receiver` (Tempo's generator writes here),
  `web.enable-otlp-receiver` (the collector writes here) and
  `enable-feature=exemplar-storage` (without it exemplars are dropped at
  ingest, so the metrics→trace jump quietly does nothing). They go in
  `server.extraFlags` **without** a leading `--`; the chart prepends the
  dashes.
- **OTLP metrics need `deltatocumulative` in the pipeline.** OTel SDKs commonly
  export delta temporality while Prometheus stores cumulative counters.
  Without the processor the data ingests with no error and reads as sawtooths.
- **The Loki chart's defaults do not fit this cluster.** Out of the box it's
  `SimpleScalable` with nine read/write/backend pods, an nginx gateway, a
  canary DaemonSet and two memcached tiers. The disable list in
  `values/loki.yaml` is required, not tidying. `test.enabled` must also be
  `false`: the chart fails the render if the canary is disabled while the
  test pod isn't.
- **Don't trim `tempo.receivers` to OTLP only.** The chart's `_ports.tpl`
  dereferences `receivers.jaeger.protocols.thrift_compact` unconditionally,
  so `jaeger: null` is a nil-pointer render error.
- **Argo CD renders charts with `helm template`, not `helm install`.** Any
  chart logic that depends on `lookup` sees an empty cluster: the Loki
  chart's StatefulSet-recreate hook Job and Grafana's PVC `volumeName` reuse
  are the two here, and both degrade to "do nothing", which is fine. Helm
  hooks become Argo CD sync hooks. `--wait` has no equivalent; the sync waves
  do that job.
- **The dashboards Application syncs with server-side apply.** A client-side
  apply stores a verbatim copy of the manifest in the
  `last-applied-configuration` annotation, doubling the object.
  `node-exporter-full.json` is ~460KB, so the round trip would land at ~920KB
  against a 1MiB `ConfigMap` limit. Keep `ServerSideApply=true` on that
  Application, and keep one ConfigMap per dashboard.
- **Provisioned dashboards are read-only in the UI.** `allowUiUpdates` is
  `false`, so *Save* is unavailable — edit the JSON and commit instead.
  Turning it on doesn't really help: the sidecar overwrites the file whenever
  its ConfigMap changes. Use *Save as* for throwaway variants.
- **The default datasource is Tempo, so a dashboard that doesn't pin one lands
  on it.** Every bundled dashboard has its `datasource` variable pinned to
  the `prometheus` UID during normalisation. Pin
  `"datasource": {"type": "prometheus", "uid": "prometheus"}` in anything you
  add.
- **Deleting a dashboard ConfigMap deletes the dashboard.** The sidecar removes
  the file and Grafana drops it on the next provisioning pass. Removing a
  JSON file and its generator entry from git therefore removes the dashboard,
  via Argo CD's prune — which is the intended behaviour for delegation.
- **The PVC panels on the Nodes and Namespaces dashboards are empty here.**
  They query `kubelet_volume_stats_*`, which the kubelet does not report for
  the hostPath-backed volumes local-path-provisioner creates. Node Exporter
  Full's hwmon, systemd and power-supply rows are empty for the same class of
  reason.
- **The S3 endpoint and the OTLP endpoint are reachable from every
  namespace** — no default-deny `NetworkPolicy` exists. S3 does check
  credentials; OTLP ingest does not. Fine for a lab, worth knowing.

## Verifying

```bash
kubectl -n argocd get applications            # bootstrap, platform, observability, and their components -- all Synced / Healthy
argocd app get platform                        # the platform tree, with each wave's status
argocd app get observability                   # the observability tree
kubectl -n platform get pods,pvc,svc           # the object store
kubectl -n platform logs deploy/object-store --tail=20   # "All enabled components are running"
kubectl -n observability get pods,pvc,svc      # the stack
```

An Application stuck `Progressing` is normal for the first few minutes of a
fresh cluster (image pulls, PVC binding). `OutOfSync` on a healthy cluster
means something was changed by hand and self-heal is about to put it back;
`Degraded` means a sync failed and the retries ran out — the Application's
sync log in the UI names the resource.
