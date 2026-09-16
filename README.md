# spellcore_k8s_lab

A three-node Kubernetes lab on local VMs. `terraform apply` builds the machines
and then provisions them the rest of the way: a `kubeadm` cluster with Calico
networking, metrics-server, trust for the lab image registry, a `kubectl`
context installed on **your workstation**, and Argo CD — which then deploys
a Grafana/Tempo/Loki/Prometheus observability backend from this repository's
[`gitops/`](gitops/) directory. One command, from nothing to a cluster you can
drive from your own shell.

Terraform (the [`dmacvicar/libvirt`](https://registry.terraform.io/providers/dmacvicar/libvirt)
provider) owns the VMs, network, disks and cloud-init; the cluster itself is
Ansible — twelve roles across four playbooks, all idempotent, all listed under
[Ansible roles](#ansible-roles); and everything that *runs on* the cluster is
Argo CD reconciling [`gitops/`](gitops/README.md). Ansible's last act is to
hand over.

## The VMs

Three libvirt/KVM guests cloned from the official Ubuntu 24.04 (noble) cloud
image:

| Name          | Cluster role  | Lab IP          | vCPU | Memory | Disk  |
|---------------|---------------|-----------------|------|--------|-------|
| `k8s-control` | control-plane | `192.168.56.10` | 4    | 8 GiB  | 128 G |
| `k8s-worker1` | worker        | `192.168.56.11` | 4    | 8 GiB  | 128 G |
| `k8s-worker2` | worker        | `192.168.56.12` | 4    | 8 GiB  | 128 G |

Defined by the `nodes` map in [`terraform/variables.tf`](terraform/variables.tf).
Budget 12 vCPU and 24 GiB of RAM on the host while the lab is up.

**One NIC each**, with a static lab address configured by cloud-init. That
single interface is also each node's default route, so kubelet's auto-detected
`InternalIP` is the lab address by construction — confirm with `kubectl get
nodes -o wide` — which is what makes metrics-server's kubelet scrapes land on a
stable address. See [Networking](#networking).

**Disk.** Each node gets a 128 G copy-on-write clone of the cloud image
(sparse — it only occupies what the node actually writes). cloud-init grows the
root filesystem to fill it on first boot, so the full ~125 G is available
immediately. That headroom matters because local-path persistent volumes are
directories on the node root filesystem, and 42 Gi of claims on a small
filesystem shared with containerd invites disk-pressure evictions.

**Login.** cloud-init creates a `spellcore` user (passwordless sudo) on every
node, keyed with an ED25519 keypair Terraform generates into
`terraform/artifacts/lab_ed25519` (gitignored). Add your own public key via the
`extra_ssh_public_keys` variable if you want plain `ssh` to work without `-i`.

**`k8s-control` is tainted** `node-role.kubernetes.io/control-plane:NoSchedule`,
so the schedulable budget is two nodes — roughly 8 vCPU and 15 Gi — not three.
The one deliberate exception is the node-exporter DaemonSet, whose tolerations
let it run everywhere, which is why all three nodes report host metrics.

Each node's `/etc/hosts` carries all three node names (written by the
`k8s_node_hosts` role) plus a `registry.lab` entry written by the
`containerd_registry_trust` role — `k8s_node_hosts` only knows about nodes in
the inventory, and that name points at the workstation. The workstation's own
`/etc/hosts` is not managed; add the entries yourself if you want to reach
nodes by name:

```
192.168.56.10 k8s-control
192.168.56.11 k8s-worker1
192.168.56.12 k8s-worker2
```

## Networking

Three networks exist on the host. Only one belongs to the lab.

| Interface | Host address      | libvirt network | What it is |
|-----------|-------------------|-----------------|------------|
| `virbrN`  | `192.168.56.1/24` | `spellcore_lab` | **The lab network.** Terraform-owned NAT network, static addresses, autostarts with libvirtd. Use this one. |
| `virbr0`  | `192.168.122.1/24`| `default`       | libvirt's stock network. Nothing in this lab uses it. |
| `wlo1`    | your LAN address  | —               | The house network. Never bind a lab service to `0.0.0.0`. |

Which address for which job:

| Job                                 | Use                 | Why |
|-------------------------------------|---------------------|-----|
| Bind a host service for the cluster | `192.168.56.1`      | Reachable from every node, invisible to the home LAN |
| SSH / Ansible targets               | `192.168.56.10–.12` | Static, declared in `terraform/variables.tf` |
| Image tags                          | `registry.lab:5000` | Resolves to the same address on the host and on the nodes |

The network is NAT'd, so the nodes reach the internet (apt, pkgs.k8s.io, Helm
charts) through the host; nothing on your LAN can reach them.

**The lab registry.** `registry.lab:5000` → `192.168.56.1`, plain HTTP, no auth.
This repo configures the *nodes* to pull from it; whatever serves that endpoint
on the host is run separately. Use the name rather than `localhost:5000` — the
registry binds the bridge address only, so nothing listens on `127.0.0.1`, and a
tag baked into an image stays valid on both sides.

## Requirements

On the workstation:

- **libvirt/KVM** — `libvirtd` running, your user in the `libvirt` and `kvm`
  groups, and a running storage pool (`default` by default) for the images.
- **Terraform** ≥ 1.5. `terraform init` fetches the `dmacvicar/libvirt`
  provider (pinned to the 0.8 series).
- **Ansible** ≥ 2.14 — Terraform invokes `ansible-playbook` *on the host*, so
  it has to be installed there. No collections are needed; every role uses
  `ansible-core` modules only.
- **`passlib` and `bcrypt`** for the Python that Ansible runs under
  (`sudo apt install python3-passlib python3-bcrypt` on Ubuntu). The
  `k8s_argocd` role hashes the Argo CD admin password with them at render
  time, on the workstation.
- **`kubectl`** — the `k8s_host_kubeconfig` role fails with an explicit message
  rather than leaving a half-written kubeconfig if it isn't on `PATH`.
- The Ubuntu 24.04 cloud image (downloaded into the pool on first apply,
  ~600 MB), and room for three sparse 128 G disk images. Point
  `ubuntu_image_source` at a local `file://` copy to skip the download on
  rebuilds.

The `lab_workstation` role in this repo sets up most of that for you —
Terraform from HashiCorp's apt repo, the libvirt/QEMU packages, group
membership and the storage pool. It is the one playbook you run by hand:

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml --ask-become-pass
```

See [`ansible/README.md`](ansible/README.md) for its variables.

## Usage

From the repo root:

```bash
terraform -chdir=terraform init      # once: fetch the providers
terraform -chdir=terraform apply     # build all three VMs and provision the whole lab
terraform -chdir=terraform destroy   # tear everything down

virsh -c qemu:///system list --all   # check VM state
ssh -i terraform/artifacts/lab_ed25519 spellcore@192.168.56.10   # log into a node

# re-run every playbook against the running lab (idempotent):
terraform -chdir=terraform apply -replace=terraform_data.ansible
# or just one:
ansible-playbook -i terraform/inventory.ini ansible/k8s-argocd.yml
```

A cold `terraform apply` is not quick: it downloads the cloud image on the
first run and installs a cluster, and Argo CD then spends a few more minutes
pulling the observability stack's images. Re-running the playbooks against a
healthy lab is a no-op — every role is idempotent and reports `changed=0` on a
second pass.

**Power state.** Terraform doesn't manage it. `virsh -c qemu:///system
shutdown <node>` halts a VM and `virsh -c qemu:///system start <node>` brings
it back; `terraform apply` won't restart a stopped domain.

## Migrating from Vagrant

This lab was previously built with Vagrant. The Terraform build is a clean
replacement — nothing carries over. One-time cleanup, before the first apply:

```bash
vagrant destroy -f                                        # from a checkout that still has the Vagrantfile,
                                                          # or: virsh -c qemu:///system destroy/undefine each VM
virsh -c qemu:///system net-undefine spellcore_k8s_lab0   # Terraform owns a fresh network on the same subnet
virsh -c qemu:///system net-undefine vagrant-libvirt      # optional: Vagrant's management network
sudo rm -f /etc/sudoers.d/vagrant_hostmanager             # optional: hostmanager leftovers
rm -rf .vagrant                                           # optional: per-project Vagrant state
```

Also remove the vagrant-hostmanager block from your `/etc/hosts` if one is
there (it's delimited by `## vagrant-hostmanager-section` markers).

## What `terraform apply` provisions

Terraform writes an inventory to `terraform/inventory.ini` and runs four
playbooks, in this order (see [`terraform/provision.tf`](terraform/provision.tf)):

1. **`ansible/k8s-node-prereqs.yml`** — every node. Node names into
   `/etc/hosts`, swap off, kernel modules and sysctls for pod networking,
   containerd from Docker's apt repo with `SystemdCgroup` on, and
   `kubeadm`/`kubelet`/`kubectl` pinned to 1.35.2 and held.
2. **`ansible/k8s-registry-trust.yml`** — every node. Makes `registry.lab:5000`
   resolvable and pullable. Runs *before* the cluster exists so local images are
   available from the moment the nodes are `Ready`.
3. **`ansible/k8s-cluster-bootstrap.yml`** — six plays that take the nodes from
   "prerequisites installed" to a `Ready` cluster: `kubeadm init` on the control
   plane, kubectl + Calico, `kubeadm join` on the workers, metrics-server, a
   default StorageClass, then the workstation kubeconfig context. The CNI goes
   in **before** the workers join, so no worker sits joined without pod
   networking; metrics-server comes after, so its readiness check covers every
   node; the StorageClass is cluster substrate that everything Argo CD later
   deploys will claim volumes from; the kubeconfig role runs last, so the
   context it hands you points at a complete cluster.
4. **`ansible/k8s-argocd.yml`** — installs Helm and Argo CD from the upstream
   chart, exposed on a NodePort with a known admin password, and applies one
   app-of-apps `Application` pointed at this repository's `gitops/bootstrap`.
   From there Argo CD deploys the observability stack on its own — see
   [GitOps with Argo CD](#gitops-with-argo-cd).

`ansible/playbook.yml` is the odd one out: it targets **your workstation**, not
the guests, and Terraform never runs it. See [Requirements](#requirements).

## Ansible roles

Twelve roles. Full variable tables and design notes for each are in
[`ansible/README.md`](ansible/README.md).

| Role | Playbook | Hosts | What it does |
|---|---|---|---|
| `lab_workstation` | `playbook.yml` (manual) | workstation | Installs Terraform from HashiCorp's apt repo, the QEMU/libvirt packages, group membership and the storage pool |
| `k8s_node_hosts` | `k8s-node-prereqs.yml` | all nodes | Every node's name/IP into every node's `/etc/hosts` (a delimited block) |
| `k8s_node_prereqs` | `k8s-node-prereqs.yml` | all nodes | Swap off, `overlay`/`br_netfilter`, bridge+forwarding sysctls, containerd, `kubeadm`/`kubelet`/`kubectl` 1.35.2 held, `crictl`, `ufw` off |
| `containerd_registry_trust` | `k8s-registry-trust.yml` | all nodes | `registry.lab` → `192.168.56.1` in `/etc/hosts`, containerd's `config_path` pointed at `certs.d`, plain-HTTP `hosts.toml` for the registry |
| `k8s_control_plane_init` | `k8s-cluster-bootstrap.yml` | control | Installs `etcdctl`, runs `kubeadm init` against `192.168.56.10` with pod CIDR `10.244.0.0/16`, generates the join command |
| `k8s_kubeconfig_cni` | `k8s-cluster-bootstrap.yml` | control | Stages `admin.conf` as `~/.kube/config` for root and the login user on every node, installs Calico v3.30.2 via the Tigera operator, waits for `Ready` |
| `k8s_cluster_join` | `k8s-cluster-bootstrap.yml` | workers | Runs `kubeadm join` with the token from the control-plane play |
| `k8s_metrics_server` | `k8s-cluster-bootstrap.yml` | control | metrics-server v0.9.0 plus `--kubelet-insecure-tls`, waited on until `kubectl top nodes` actually answers — this is what makes `kubectl top` and HPAs work |
| `k8s_local_path_storage` | `k8s-cluster-bootstrap.yml` | control | local-path-provisioner v0.0.37, patched to be the cluster's default StorageClass — before this the cluster has none at all |
| `k8s_host_kubeconfig` | `k8s-cluster-bootstrap.yml` | control → localhost | Writes a `spellcore-k8s-lab` cluster/user/context into **your** kubeconfig and makes it current |
| `helm_cli` | `k8s-argocd.yml` | control | Installs a pinned, checksum-verified Helm 3.21.4 at `/usr/local/bin/helm` |
| `k8s_argocd` | `k8s-argocd.yml` | control | Argo CD v3.5.3 from the `argo/argo-cd` chart, plain-HTTP NodePort, fixed admin password, and the app-of-apps `bootstrap` Application pointed at `gitops/bootstrap` |

## Using kubectl from your workstation

The `k8s_host_kubeconfig` role means `kubectl` on the host already talks to the
cluster — no SSH into a node, no copying kubeconfigs around, no tunnel:

```bash
kubectl config current-context   # spellcore-k8s-lab
kubectl get nodes -o wide
```

This works because `kubeadm init` advertises the API server on `k8s-control`'s
lab address (`192.168.56.10:6443`, from `k8s_control_plane_init_endpoint`). The
lab network makes that address routable from the host, and `kubeadm` puts it
in the API server cert's SANs, so TLS verification succeeds without extra flags:

```bash
curl -k https://192.168.56.10:6443/version
```

The role only ever writes three fixed-name entries — cluster
`spellcore-k8s-lab`, user `spellcore-k8s-lab-admin`, context `spellcore-k8s-lab`
— so contexts for unrelated clusters in the same kubeconfig are left alone, and
each `terraform apply` replaces the previous run's entries instead of piling up
a new set. That matters after `terraform destroy`, which brings the cluster
back with a brand new CA. It writes to `$KUBECONFIG`'s first entry if that's
set in the shell you ran the provisioning from, and to `~/.kube/config`
otherwise, keeping a one-time `.pre-spellcore-k8s-lab.bak` copy of whatever was
there first.

To install the context without making it current, set
`k8s_host_kubeconfig_set_current: false` (see `ansible/README.md` for the full
variable list).

## Observability

Argo CD stands up an OTLP telemetry backend in an `observability` namespace,
from [`gitops/observability/`](gitops/observability/) — it follows the
platform stack in the `bootstrap` Application's sync order, so it arrives a
few minutes after `terraform apply` finishes. Open Grafana in your host
browser at:

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

Traces and logs sit behind an S3 object store — [SeaweedFS](https://github.com/seaweedfs/seaweedfs),
which replaced MinIO when MinIO's community edition was archived — on
local-path persistent volumes. The store is not part of the observability
stack: it is a **platform** service in its own `platform` namespace
([`gitops/platform/`](gitops/platform/)), synced before any application
stack, and the observability stack is its first tenant with its own
bucket-scoped S3 identity. Prometheus is the exception: it has no
object-storage backend, so its 20Gi volume is the only copy of the metrics
and retention (15 days) is bounded by disk.

Two consequences of local-path storage worth knowing: volumes are directories on
whichever node the consuming pod first landed on, so that pod can never move;
and `terraform destroy` takes all the telemetry with it.

Dashboards and alerts are **delegated**: Grafana's sidecars watch every
namespace for ConfigMaps labelled `grafana_dashboard` or `grafana_alert`, so an
application ships its own observability alongside its own manifests. The seven
bundled cluster dashboards use exactly that mechanism — see
[`gitops/README.md`](gitops/README.md#dashboards-and-alerts).

To change anything about the stack — retention, volume sizes, a chart version,
the credentials — edit the matching file under `gitops/observability/`, commit,
and open a PR against `bifrost`. Argo CD applies it within a minute of the
merge. [`gitops/README.md`](gitops/README.md) is the map, and carries the
reasoning behind every chart and value.

Deploying an application into this cluster and want its telemetry in Grafana?
[`docs/observability-for-developers.md`](docs/observability-for-developers.md) is
the how-to: the `OTEL_*` block to set, what arrives for free, how to query each
signal, and how to ship your own dashboards and alert rules. Runnable manifests
are in [`examples/observability/`](examples/observability/).

## GitOps with Argo CD

`terraform apply` also installs [Argo CD](https://argo-cd.readthedocs.io/) in
an `argocd` namespace. Open the UI in your host browser at:

**<http://192.168.56.10:30800>** — `admin` / `lab-argocd`

It's a NodePort, so `192.168.56.11` and `.12` work too. The server runs in
`--insecure` mode (plain HTTP, same posture as Grafana and the lab registry),
so the `argocd` CLI logs in with `--plaintext` rather than `--insecure`:

```bash
argocd login 192.168.56.10:30800 --username admin --password lab-argocd --plaintext
argocd app list
```

The `k8s_argocd` role applies one `Application`, named `bootstrap`, pointed
at this repository's [`gitops/bootstrap`](gitops/bootstrap/) on the `bifrost`
branch, with automated sync, prune and self-heal. That is an app-of-apps: it
creates a `platform` Application (shared services — the object store) and
then an `observability` Application, each of which creates one Application
per component, in dependency order. From then on a commit to `gitops/` on
`bifrost` *is* the deployment, and a `kubectl edit` behind Argo CD's back is
reverted. [`gitops/README.md`](gitops/README.md) explains the layout, the
rule for what is Ansible versus platform versus application, how to make a
change, and how to point the lab at a feature branch instead:

```yaml
# ansible/host_vars/k8s-control.yml
k8s_argocd_bootstrap_repo_revision: agent/feat/my-change
```

```bash
ansible-playbook -i terraform/inventory.ini ansible/k8s-argocd.yml
```

Argo CD pulls from GitHub, not from your checkout — the lab network is NAT'd,
so public GitHub works and the branch has to be pushed first. Pointing the
role at another repository entirely is `k8s_argocd_bootstrap_repo_url` (a
private one needs a repo credential Secret in the `argocd` namespace first,
which the role doesn't manage), and setting that to `""` installs Argo CD with
no applications at all.

Anything Argo CD deploys can ship its telemetry the same way everything else
does — see [Observability](#observability) and
[`docs/observability-for-developers.md`](docs/observability-for-developers.md).

What's deliberately switched off: Dex (there's no SSO provider to federate,
so the local `admin` account is the only login) and the notifications
controller (nowhere to send anything on an isolated network). Both are one
variable away; see `ansible/README.md`.

## Customizing

- **Node count, names, IPs, CPU, memory** — the `nodes` map in
  [`terraform/variables.tf`](terraform/variables.tf). The lab network is
  `192.168.56.0/24`; change `network_cidr` and `host_ip` if that conflicts with
  something on your host (and `lab_host_ip` in `ansible/group_vars/all.yml`
  with them). If `k8s-control`'s IP moves,
  `k8s_control_plane_init_endpoint` has to move with it.
- **Guest user, image source, disk size** — `guest_user`,
  `ubuntu_image_source` and `disk_size` in the same file, or a
  `terraform.tfvars` next to it.
- **Argo CD password, NodePort, which branch the cluster runs** — copy
  `ansible/host_vars/k8s-control.yml.example` to
  `ansible/host_vars/k8s-control.yml` (untracked) and override there rather than
  editing role defaults; the `k8s_argocd_*` variables are listed in
  [`ansible/README.md`](ansible/README.md#argo-cd-role).
- **Observability credentials, NodePorts, retention, volume sizes, chart
  versions** — the files under `gitops/observability/`, committed and merged
  to `bifrost`. Not Ansible variables any more; see
  [`gitops/README.md`](gitops/README.md#making-a-change).
- **Workstation-side install** — `ansible/host_vars/localhost.yml` overrides
  the `lab_workstation` role's defaults (storage-pool path, whether to install
  the libvirt stack at all).

## Troubleshooting

- **Domain fails to start with a qcow2 `Permission denied`** — AppArmor on
  Debian/Ubuntu hosts can block QEMU from volumes in pools outside
  `/var/lib/libvirt/images`. The blunt lab fix: set `security_driver = "none"`
  in `/etc/libvirt/qemu.conf` and `sudo systemctl restart libvirtd`.
- **`terraform apply` can't reach libvirt** — it talks to `qemu:///system`;
  your user must be in the `libvirt` group (log out/in after the
  `lab_workstation` role adds you).
- **Stuck waiting for SSH** — watch a node boot with
  `virsh -c qemu:///system console k8s-control` (serial console is configured).

## Verifying the lab

```bash
kubectl get nodes -o wide                      # three Ready nodes, InternalIP 192.168.56.x
kubectl top nodes                              # metrics-server is serving
kubectl get sc                                 # local-path (default)
kubectl -n argocd get applications             # bootstrap, platform, observability and their components -- Synced / Healthy
kubectl -n platform get pods                   # the object store
kubectl -n observability get pods              # the stack's pods, once Argo CD has synced them
```

Registry trust, from a node — `crictl pull` is the real test, since it uses the
same containerd path a kubelet does:

```bash
ssh -i terraform/artifacts/lab_ed25519 spellcore@192.168.56.10 'curl -s http://registry.lab:5000/v2/_catalog'
ssh -i terraform/artifacts/lab_ed25519 spellcore@192.168.56.10 'sudo containerd config dump | grep -B3 config_path'
ssh -i terraform/artifacts/lab_ed25519 spellcore@192.168.56.10 'sudo crictl pull registry.lab:5000/myapp:dev'
```
