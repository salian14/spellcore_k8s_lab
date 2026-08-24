# spellcore_k8s_lab

A three-node Kubernetes lab on local VMs. `vagrant up` boots the machines and
then provisions them the rest of the way: a `kubeadm` cluster with Calico
networking, metrics-server, trust for the lab image registry, a `kubectl`
context installed on **your workstation**, and a Grafana/Tempo/Loki/Prometheus
observability backend. One command, from nothing to a cluster you can drive
from your own shell.

Everything past the boot is Ansible — twelve roles across four playbooks, all
idempotent, all listed under [Ansible roles](#ansible-roles).

## The VMs

Three libvirt (or VirtualBox) guests from the `generic/ubuntu2204` box —
Ubuntu 22.04.3, kernel 5.15, amd64:

| Name          | Cluster role  | Lab IP          | vCPU | Memory | Disk                  |
|---------------|---------------|-----------------|------|--------|-----------------------|
| `k8s-control` | control-plane | `192.168.56.10` | 4    | 8 GiB  | 128 G → 126 G root LV |
| `k8s-worker1` | worker        | `192.168.56.11` | 4    | 8 GiB  | 128 G → 126 G root LV |
| `k8s-worker2` | worker        | `192.168.56.12` | 4    | 8 GiB  | 128 G → 126 G root LV |

Defined by the `NODES` array at the top of the `Vagrantfile`. Budget 12 vCPU and
24 GiB of RAM on the host while the lab is up.

**Two NICs each.** `eth0` sits on Vagrant's own management network and gets a
DHCP lease that changes; `eth1` is the static lab address in the table above.
Kubernetes reports the **lab** address as each node's `InternalIP` — confirm with
`kubectl get nodes -o wide` — which is what makes metrics-server's kubelet
scrapes land on a stable address. See [Networking](#networking).

**Disk.** The box ships a 128 G `vda` partitioned into a 126 G LVM PV with only
a 63 G root LV carved out of it, leaving half the disk unallocated. The
`k8s_node_storage_expand` role grows that LV into the free space on first
provision (a ~124 G filesystem), because local-path persistent volumes are
directories on the node root filesystem and 42 Gi of claims on a 62 G
filesystem shared with containerd invites disk-pressure evictions. It is also
why the first `vagrant up` takes noticeably longer than a bare boot.

**`k8s-control` is tainted** `node-role.kubernetes.io/control-plane:NoSchedule`,
so the schedulable budget is two nodes — roughly 8 vCPU and 15 Gi — not three.
The one deliberate exception is the node-exporter DaemonSet, whose tolerations
let it run everywhere, which is why all three nodes report host metrics.

Each node's `/etc/hosts` carries all three node names (written by
`vagrant-hostmanager`, which also updates the host's) plus a `registry.lab`
entry written by the `containerd_registry_trust` role — hostmanager only knows
about machines defined in the `Vagrantfile`, and that name points at the
workstation.

## Networking

Four networks exist on the host and two of them look interchangeable. They are
not.

| Interface | Host address      | libvirt network      | What it is |
|-----------|-------------------|----------------------|------------|
| `virbr2`  | `192.168.56.1/24` | `spellcore_k8s_lab0` | **The lab network.** The `private_network` in the `Vagrantfile`, static addresses. Use this one. |
| `virbr1`  | `192.168.121.1/24`| `vagrant-libvirt`    | Vagrant's management network, created automatically. DHCP; leases churn across reboots. |
| `virbr0`  | `192.168.122.1/24`| `default`            | libvirt's stock network. Nothing in this lab uses it. |
| `wlo1`    | your LAN address  | —                    | The house network. Never bind a lab service to `0.0.0.0`. |

Which address for which job:

| Job                              | Use                    | Why |
|----------------------------------|------------------------|-----|
| Bind a host service for the cluster | `192.168.56.1`      | Reachable from every node, invisible to the home LAN |
| SSH / Ansible targets            | `192.168.56.10–.12`    | Static, declared in the `Vagrantfile` |
| Image tags                       | `registry.lab:5000`    | Resolves to the same address on the host and on the nodes |
| Anything at all                  | ~~`192.168.121.x`~~    | **Don't.** DHCP; it will change under you |

**The lab registry.** `registry.lab:5000` → `192.168.56.1`, plain HTTP, no auth.
This repo configures the *nodes* to pull from it; whatever serves that endpoint
on the host is run separately. Use the name rather than `localhost:5000` — the
registry binds the bridge address only, so nothing listens on `127.0.0.1`, and a
tag baked into an image stays valid on both sides.

**After a host reboot,** `spellcore_k8s_lab0` does not autostart, so `virbr2` and
`192.168.56.1` won't exist until the lab comes up. `virsh -c qemu:///system
net-autostart spellcore_k8s_lab0` makes it permanent.

## Requirements

On the workstation:

- **libvirt/KVM** (the default provider, via `VAGRANT_DEFAULT_PROVIDER`) or
  **VirtualBox** — both are configured in the `Vagrantfile`.
- **Vagrant**, plus the `vagrant-libvirt` and `vagrant-hostmanager` plugins.
- **Ansible** ≥ 2.14 — Vagrant's `ansible` provisioner runs `ansible-playbook`
  *on the host*, so it has to be installed there. No collections are needed;
  every role uses `ansible-core` modules only.
- **`kubectl`** — the `k8s_host_kubeconfig` role fails with an explicit message
  rather than leaving a half-written kubeconfig if it isn't on `PATH`.
- The `generic/ubuntu2204` box (downloaded on first `vagrant up`, ~700 MB), and
  room for three sparse 128 G disk images.

The `vagrant` role in this repo sets up most of that for you — Vagrant from
HashiCorp's apt repo, the two plugins, the libvirt packages, group membership,
the storage pool and a sudoers drop-in so hostmanager doesn't prompt on every
`up`. It is the one playbook you run by hand:

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml --ask-become-pass
```

See [`ansible/README.md`](ansible/README.md) for its variables.

## Usage

From the repo root:

```bash
vagrant up                # boot all three VMs and provision the whole lab
vagrant status            # check state
vagrant ssh k8s-control   # or k8s-worker1 / k8s-worker2
vagrant provision         # re-run every playbook (idempotent)
vagrant halt              # stop the VMs
vagrant destroy -f        # tear everything down
```

A cold `vagrant up` is not quick: it grows a logical volume on every node,
installs a cluster, and deploys six Helm releases. Re-running `vagrant provision`
against a healthy lab is a no-op — every role is idempotent, and the
observability playbook reports `changed=0` on a second pass.

**Note on single-node `up`.** The Ansible provisioners are attached only to the
last-defined node (`k8s-worker2`), so Vagrant defers them until every machine in
the run is up and then executes each playbook once against all of them, rather
than once per node as each boots. That means `vagrant up k8s-control` or
`vagrant up k8s-worker1` alone will **not** provision anything. If you bring
nodes up individually, follow with a bare `vagrant provision` (no machine name)
once they're all running.

## What `vagrant up` provisions

Four playbooks, in this order, all invoked automatically by Vagrant's `ansible`
provisioner against an inventory it generates itself:

1. **`ansible/k8s-node-prereqs.yml`** — every node. Swap off, kernel modules and
   sysctls for pod networking, containerd from Docker's apt repo with
   `SystemdCgroup` on, and `kubeadm`/`kubelet`/`kubectl` pinned to 1.35.2 and
   held.
2. **`ansible/k8s-registry-trust.yml`** — every node. Makes `registry.lab:5000`
   resolvable and pullable. Runs *before* the cluster exists so local images are
   available from the moment the nodes are `Ready`.
3. **`ansible/k8s-cluster-bootstrap.yml`** — five plays that take the nodes from
   "prerequisites installed" to a `Ready` cluster: `kubeadm init` on the control
   plane, kubectl + Calico, `kubeadm join` on the workers, metrics-server, then
   the workstation kubeconfig context. The CNI goes in **before** the workers
   join, so no worker sits joined without pod networking; metrics-server comes
   after, so its readiness check covers every node; the kubeconfig role runs
   last, so the context it hands you points at a complete cluster.
4. **`ansible/k8s-observability.yml`** — grows the node root volumes, then
   installs Helm, a default StorageClass and the telemetry stack. Runs last
   because it needs a working cluster, and the volume growth has to happen
   before any chart claims a persistent volume.

`ansible/playbook.yml` is the odd one out: it targets **your workstation**, not
the guests, and Vagrant never runs it. See [Requirements](#requirements).

## Ansible roles

Twelve roles. Full variable tables and design notes for each are in
[`ansible/README.md`](ansible/README.md).

| Role | Playbook | Hosts | What it does |
|---|---|---|---|
| `vagrant` | `playbook.yml` (manual) | workstation | Installs Vagrant, the `vagrant-libvirt` and `vagrant-hostmanager` plugins, QEMU/libvirt packages, the storage pool and the hostmanager sudoers drop-in |
| `k8s_node_prereqs` | `k8s-node-prereqs.yml` | all nodes | Swap off, `overlay`/`br_netfilter`, bridge+forwarding sysctls, containerd, `kubeadm`/`kubelet`/`kubectl` 1.35.2 held, `crictl`, `ufw` off |
| `containerd_registry_trust` | `k8s-registry-trust.yml` | all nodes | `registry.lab` → `192.168.56.1` in `/etc/hosts`, containerd's `config_path` pointed at `certs.d`, plain-HTTP `hosts.toml` for the registry |
| `k8s_control_plane_init` | `k8s-cluster-bootstrap.yml` | control | Installs `etcdctl`, runs `kubeadm init` against `192.168.56.10` with pod CIDR `10.244.0.0/16`, generates the join command |
| `k8s_kubeconfig_cni` | `k8s-cluster-bootstrap.yml` | control | Stages `admin.conf` as `~/.kube/config` for root and `vagrant` on every node, installs Calico v3.30.2 via the Tigera operator, waits for `Ready` |
| `k8s_cluster_join` | `k8s-cluster-bootstrap.yml` | workers | Runs `kubeadm join` with the token from the control-plane play |
| `k8s_metrics_server` | `k8s-cluster-bootstrap.yml` | control | metrics-server v0.9.0 plus `--kubelet-insecure-tls`, waited on until `kubectl top nodes` actually answers — this is what makes `kubectl top` and HPAs work |
| `k8s_host_kubeconfig` | `k8s-cluster-bootstrap.yml` | control → localhost | Writes a `spellcore-k8s-lab` cluster/user/context into **your** kubeconfig and makes it current |
| `k8s_node_storage_expand` | `k8s-observability.yml` | all nodes | `lvextend` + `resize2fs` of the root LV into the unallocated volume-group space (63 G → 126 G) |
| `helm_cli` | `k8s-observability.yml` | control | Installs a pinned, checksum-verified Helm 3.21.4 at `/usr/local/bin/helm` |
| `k8s_local_path_storage` | `k8s-observability.yml` | control | local-path-provisioner v0.0.37, patched to be the cluster's default StorageClass — before this the cluster has none at all |
| `k8s_observability` | `k8s-observability.yml` | control | Six Helm releases (MinIO, Prometheus, Tempo, Loki, OTel collector, Grafana) in dependency order, plus seven dashboards as labelled ConfigMaps |

## Using kubectl from your workstation

The `k8s_host_kubeconfig` role means `kubectl` on the host already talks to the
cluster — no `vagrant ssh`, no copying kubeconfigs around, no tunnel:

```bash
kubectl config current-context   # spellcore-k8s-lab
kubectl get nodes -o wide
```

This works because `kubeadm init` advertises the API server on `k8s-control`'s
lab address (`192.168.56.10:6443`, from `k8s_control_plane_init_endpoint`). The
private network makes that address routable from the host, and `kubeadm` puts it
in the API server cert's SANs, so TLS verification succeeds without extra flags:

```bash
curl -k https://192.168.56.10:6443/version
```

The role only ever writes three fixed-name entries — cluster
`spellcore-k8s-lab`, user `spellcore-k8s-lab-admin`, context `spellcore-k8s-lab`
— so contexts for unrelated clusters in the same kubeconfig are left alone, and
each `vagrant up` replaces the previous run's entries instead of piling up a new
set. That matters after `vagrant destroy`, which brings the cluster back with a
brand new CA. It writes to `$KUBECONFIG`'s first entry if that's set in the shell
you ran `vagrant up` from, and to `~/.kube/config` otherwise, keeping a one-time
`.pre-spellcore-k8s-lab.bak` copy of whatever was there first.

To install the context without making it current, set
`k8s_host_kubeconfig_set_current: false` (see `ansible/README.md` for the full
variable list).

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
disk.

Two consequences of local-path storage worth knowing: volumes are directories on
whichever node the consuming pod first landed on, so that pod can never move;
and `vagrant destroy` takes all the telemetry with it.

Dashboards and alerts are **delegated**: Grafana's sidecars watch every
namespace for ConfigMaps labelled `grafana_dashboard` or `grafana_alert`, so an
application ships its own observability alongside its own manifests. The seven
bundled cluster dashboards use exactly that mechanism — see
[`ansible/README.md`](ansible/README.md#dashboards-and-alerts).

Deploying an application into this cluster and want its telemetry in Grafana?
[`docs/observability-for-developers.md`](docs/observability-for-developers.md) is
the how-to: the `OTEL_*` block to set, what arrives for free, how to query each
signal, and how to ship your own dashboards and alert rules. Runnable manifests
are in [`examples/observability/`](examples/observability/).

## Customizing

- **Node count, names, IPs, CPU, memory** — the `NODES` array at the top of the
  `Vagrantfile`. The private network is `192.168.56.0/24`; change
  `NETWORK_PREFIX` if that conflicts with something on your host. If
  `k8s-control`'s IP moves, `k8s_control_plane_init_endpoint` has to move with
  it.
- **Observability credentials, NodePorts, retention, volume sizes** — copy
  `ansible/host_vars/k8s-control.yml.example` to
  `ansible/host_vars/k8s-control.yml` (untracked) and override there rather than
  editing role defaults.
- **Workstation-side Vagrant install** — copy
  `ansible/host_vars/localhost.yml.example` to `ansible/host_vars/localhost.yml`
  for storage-pool and `VAGRANT_HOME` paths.
- **Node storage expansion** — `k8s_node_storage_expand_*` belongs in
  `ansible/group_vars/all.yml`, **not** `host_vars/k8s-control.yml`: the role
  runs on the workers too, and a control-plane-only override would silently
  leave them unexpanded.

## Verifying the lab

```bash
kubectl get nodes -o wide                      # three Ready nodes, InternalIP 192.168.56.x
kubectl top nodes                              # metrics-server is serving
kubectl get sc                                 # local-path (default)
kubectl -n observability get pods              # the six releases' pods
vagrant ssh k8s-control -c 'sudo helm -n observability list --kubeconfig /etc/kubernetes/admin.conf'
```

Registry trust, from a node — `crictl pull` is the real test, since it uses the
same containerd path a kubelet does:

```bash
vagrant ssh k8s-control -c 'curl -s http://registry.lab:5000/v2/_catalog'
vagrant ssh k8s-control -c 'sudo containerd config dump | grep -B3 config_path'
vagrant ssh k8s-control -c 'sudo crictl pull registry.lab:5000/myapp:dev'
```
