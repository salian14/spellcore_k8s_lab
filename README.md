# spellcore_k8s_lab

Three bare Ubuntu 22.04 VMs, networked and named for building a Kubernetes
test cluster on top of — one intended control-plane node, two intended
workers. No k8s software is installed by this config; it just gives you
machines to bootstrap a cluster on (`kubeadm`, `k3s`, etc. — your choice).

## Nodes

| Name          | IP              | vCPUs | Memory |
|---------------|-----------------|-------|--------|
| `k8s-control` | 192.168.56.10   | 4     | 8 GiB  |
| `k8s-worker1` | 192.168.56.11   | 4     | 8 GiB  |
| `k8s-worker2` | 192.168.56.12   | 4     | 8 GiB  |

Each node's `/etc/hosts` is populated with all three entries so they can
resolve each other by name.

## Requirements

- Vagrant (this repo's `ansible/` role installs it plus the `vagrant-libvirt`
  provider — see `ansible/README.md`).
- A provider: `libvirt` (default here, via `VAGRANT_DEFAULT_PROVIDER`) or
  `virtualbox` — both are configured in the `Vagrantfile`.
- The `generic/ubuntu2204` box (downloaded automatically on first `vagrant
  up`, ~700 MB).

## Usage

From this directory:

```bash
vagrant up               # create and boot all three VMs
vagrant status            # check state
vagrant ssh k8s-control   # or k8s-worker1 / k8s-worker2
vagrant halt               # stop the VMs
vagrant destroy -f        # tear everything down
```

Bring up a single node with `vagrant up k8s-worker1`, and reapply the
`/etc/hosts` provisioning after editing the `Vagrantfile` with `vagrant
provision`.

**Note on single-node `up`:** the Ansible node-prerequisites provisioner
(see "Next steps" below) is only attached to the last-defined node
(`k8s-worker2`), so Vagrant runs it once against every node that's up in
that run rather than once per node as each one boots. That means `vagrant up
k8s-control` or `vagrant up k8s-worker1` alone will **not** trigger it. If
you bring nodes up individually, follow with a bare `vagrant provision`
(no machine name) once all the nodes you want configured are running —
every task in the role is idempotent, so re-running it is cheap.

## Customizing

Edit the `NODES` array at the top of the `Vagrantfile` to change node count,
names, IPs, CPU, or memory. The private network uses `192.168.56.0/24` —
change `NETWORK_PREFIX` if that conflicts with something on your host.

## Cluster bootstrap

`vagrant up` now provisions all three nodes and bootstraps a full, `Ready`
cluster automatically:

1. Swap disabled, kernel modules/sysctl set for pod networking, `containerd`
   installed and configured, and `kubeadm`/`kubelet`/`kubectl` installed at a
   pinned version and held — via the `k8s_node_prereqs` Ansible role.
2. `registry.lab:5000` (the lab registry on the host, see
   [`lab-network.md`](lab-network.md)) made resolvable and pullable from every
   node — via the `containerd_registry_trust` role. Runs before the cluster
   comes up so local images are available from the start. It configures the
   nodes only; whatever serves that endpoint on `192.168.56.1` is yours to
   run.
3. `kubeadm init` on `k8s-control` — via the `k8s_control_plane_init` role.
4. `kubectl` configured on `k8s-control` and Calico installed as the CNI —
   via the `k8s_kubeconfig_cni` role.
5. `kubeadm join` on `k8s-worker1`/`k8s-worker2`, using the token generated
   in step 3 — via the `k8s_cluster_join` role.
6. `metrics-server` in `kube-system`, so the `metrics.k8s.io` API is served
   and `kubectl top` / HorizontalPodAutoscaler work — via the
   `k8s_metrics_server` role. A `kubeadm` cluster ships nothing that does
   this.
7. A `spellcore-k8s-lab` context installed in **your workstation's**
   kubeconfig and made current — via the `k8s_host_kubeconfig` role.
8. An observability backend — Grafana, Tempo, Loki, Prometheus, MinIO and an
   OpenTelemetry collector gateway — in an `observability` namespace, via the
   `k8s_node_storage_expand`, `helm_cli`, `k8s_local_path_storage` and
   `k8s_observability` roles. See [Observability](#observability) below.

All of them live in `ansible/` (see `ansible/README.md`) and are idempotent,
so re-running `vagrant provision` after these VMs already have a running
cluster is a no-op.

Verify with:

```bash
vagrant ssh k8s-control -c "kubectl get nodes -o wide"
```

## Using kubectl from your workstation

Step 6 above means `kubectl` on the host already talks to the cluster — no
`vagrant ssh`, no copying kubeconfigs around, no tunnel:

```bash
kubectl config current-context   # spellcore-k8s-lab
kubectl get nodes -o wide
```

This works because `kubeadm init` advertises the API server on
`k8s-control`'s private-network address (`192.168.56.10:6443`, from
`k8s_control_plane_init_endpoint`). The Vagrant private network makes that
address routable from the host, and `kubeadm` puts it in the API server
cert's SANs, so TLS verification succeeds without any extra flags:

```bash
curl -k https://192.168.56.10:6443/version
```

The role only ever writes three fixed-name entries — cluster
`spellcore-k8s-lab`, user `spellcore-k8s-lab-admin`, context
`spellcore-k8s-lab` — so contexts for unrelated clusters in the same
kubeconfig are left alone, and each `vagrant up` replaces the previous run's
entries instead of piling up a new set. That matters after `vagrant destroy`,
which brings the cluster back with a brand new CA. It writes to
`$KUBECONFIG`'s first entry if that's set in the shell you ran `vagrant up`
from, and to `~/.kube/config` otherwise, keeping a one-time
`.pre-spellcore-k8s-lab.bak` copy of whatever was there first.

To install the context without making it current, set
`k8s_host_kubeconfig_set_current: false` (see `ansible/README.md` for the
full variable list).

## Observability

`vagrant up` also stands up an OTLP telemetry backend in an `observability`
namespace. Open Grafana in your host browser at:

**<http://192.168.56.10:30300>** — `admin` / `lab-observability`

It's a NodePort, so `192.168.56.11` and `.12` work too. Tempo (traces), Loki
(logs) and Prometheus (metrics) datasources are pre-provisioned, with links
wired in every direction, so you can pivot from a span to its logs, from a
metric to a trace that caused it, and back.

Prometheus has its own UI at **<http://192.168.56.10:30090>** — worth knowing
about because `/targets` is the page that answers "why is this metric
missing?", and Grafana can't show it.

Explore opens on **Tempo** by default; switch the datasource picker for
metrics.

Anything running in **any** namespace can push telemetry in by pointing an OTLP
exporter at the collector gateway:

```
otel-collector.observability.svc.cluster.local:4317   # OTLP/gRPC
otel-collector.observability.svc.cluster.local:4318   # OTLP/HTTP
```

To prove it end to end, emit some traces from a different namespace:

```bash
kubectl -n default run telemetrygen --rm -i --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.158.0 -- \
  traces --otlp-endpoint otel-collector.observability.svc.cluster.local:4317 \
         --otlp-insecure --traces 20 --service smoke-test
```

Then in Grafana: **Explore → Tempo → Search**, service `smoke-test`. The spans
carry `k8s.pod.name`, `k8s.namespace.name` and `k8s.node.name`, added by the
collector's `k8sattributes` processor.

What this stack does and doesn't collect:

- **Traces** — anything pushed over OTLP. This is the main path.
- **Logs** — OTLP logs from instrumented applications, plus Kubernetes events
  (pod scheduling failures, OOMKills, image pull errors). Pod `stdout`/`stderr`
  is **not** collected; that would need a log-scraping DaemonSet on every node.
- **Metrics** — three sources, all landing in Prometheus. It **scrapes** the
  cluster (API server, kubelets and cAdvisor, plus kube-state-metrics for object
  state and node-exporter for host CPU/memory/disk on all three nodes);
  it **receives** application metrics pushed over OTLP to the same collector
  gateway as traces and logs; and it **stores** the RED metrics and service
  graphs that Tempo derives from spans. No alerting — Alertmanager ships with
  the chart but is switched off, since there are no routes to send anything to.

  `kubectl top` and HorizontalPodAutoscaler are a *separate* mechanism and are
  unaffected: they read metrics-server in `kube-system` (installed by
  `k8s-cluster-bootstrap.yml`, not by this stack), which keeps a ~15s in-memory
  window and stores nothing. Prometheus can't serve them and metrics-server
  can't back Prometheus.

Traces and logs sit behind MinIO's S3 API on local-path persistent volumes.
Prometheus is the exception: it has no object-storage backend, so its 20Gi
volume is the only copy of the metrics and retention (15 days) is bounded by
disk. Because `vagrant up` grows each node's root logical volume from 63G to
~126G to make room, the first provision takes noticeably longer than it used
to.

Two consequences of local-path storage worth knowing: volumes are directories on
whichever node the consuming pod first landed on, so that pod can never move;
and `vagrant destroy` takes all the telemetry with it.
