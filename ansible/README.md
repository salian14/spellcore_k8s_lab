# spellcore_k8s_lab — Ansible

Ansible playbook that prepares the workstation to run the lab: installs
[Terraform](https://www.terraform.io/) from HashiCorp's official apt
repository, along with the QEMU/KVM/libvirt stack and storage pool the
`dmacvicar/libvirt` provider builds the VMs on.

Also includes the `k8s_node_hosts` and `k8s_node_prereqs` roles, which prepare
the `spellcore_k8s_lab` guest VMs for `kubeadm` (node names in `/etc/hosts`,
swap off, kernel/sysctl settings, containerd, kubeadm/kubelet/kubectl), and
the `k8s_control_plane_init` / `k8s_kubeconfig_cni` / `k8s_cluster_join` /
`k8s_metrics_server` / `k8s_host_kubeconfig` roles, which bootstrap the actual
cluster on top of that (`kubeadm init`, kubectl + Calico CNI, `kubeadm join`,
metrics-server so `kubectl top` works) and then give your workstation a
`kubectl` context pointed at it — see their own sections below. Unlike the
`lab_workstation` role, none of these are run from this directory with
`ansible-playbook`; `terraform apply` invokes them automatically (see
`../terraform/provision.tf`).

Plus `containerd_registry_trust`, which lets the nodes pull from the lab
registry at `registry.lab:5000` — also invoked by Terraform, see
[its section](#containerd_registry_trust-role) below.

Finally the `helm_cli` / `k8s_local_path_storage` / `k8s_observability` roles,
which install Helm and a default StorageClass and deploy the
Grafana/Tempo/Loki/Prometheus/MinIO/OTel telemetry backend — see
[Observability roles](#observability-roles). Terraform invokes these too.

And `k8s_argocd`, which deploys Argo CD from the upstream `argo/argo-cd` chart,
exposes it on a NodePort with a fixed admin password, and optionally applies an
app-of-apps bootstrap Application — see [Argo CD role](#argo-cd-role). Also
invoked by Terraform, last.

## Layout

```
.
└── ansible/
    ├── inventory.ini            # example inventory (localhost by default), used by the lab_workstation role
    ├── playbook.yml             # entry point for the lab_workstation role
    ├── k8s-node-prereqs.yml     # entry point for k8s_node_hosts + k8s_node_prereqs, invoked by terraform apply
    ├── k8s-cluster-bootstrap.yml  # entry point for the five cluster-bootstrap roles below, invoked by terraform apply
    ├── k8s-registry-trust.yml   # entry point for containerd_registry_trust, invoked by terraform apply
    ├── k8s-observability.yml    # entry point for the three observability roles below, invoked by terraform apply
    ├── k8s-argocd.yml           # entry point for helm_cli + k8s_argocd, invoked by terraform apply
    ├── group_vars/
    │   └── all.yml              # lab network/registry addresses shared by every play
    ├── host_vars/
    │   ├── localhost.yml.example    # copy to localhost.yml to override the lab_workstation role's defaults
    │   └── k8s-control.yml.example  # copy to k8s-control.yml to override observability/Argo CD credentials, ports, bootstrap repo
    └── roles/
        ├── lab_workstation/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   └── tasks/main.yml
        ├── k8s_node_hosts/
        │   └── tasks/main.yml
        ├── k8s_node_prereqs/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   ├── tasks/main.yml
        │   └── templates/
        │       ├── k8s-modules.conf.j2
        │       ├── k8s-sysctl.conf.j2
        │       └── crictl.yaml.j2
        ├── k8s_control_plane_init/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   └── tasks/main.yml
        ├── k8s_kubeconfig_cni/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   ├── files/
        │   │   └── custom-resources.yaml  # Calico installation manifest, applied via kubectl
        │   └── tasks/main.yml
        ├── k8s_cluster_join/
        │   ├── meta/main.yml
        │   └── tasks/main.yml
        ├── k8s_metrics_server/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   └── tasks/main.yml
        ├── k8s_host_kubeconfig/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   └── tasks/main.yml
        ├── containerd_registry_trust/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   ├── handlers/main.yml
        │   ├── tasks/main.yml
        │   └── templates/
        │       └── hosts.toml.j2   # certs.d entry for the lab registry
        ├── helm_cli/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   └── tasks/main.yml
        ├── k8s_local_path_storage/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   └── tasks/main.yml
        ├── k8s_observability/
        │   ├── defaults/main.yml   # all configurable variables
        │   ├── meta/main.yml
        │   ├── files/
        │   │   └── dashboards/     # the seven bundled dashboard JSON files
        │   ├── tasks/
        │   │   ├── main.yml
        │   │   └── dashboards.yml  # renders each dashboard as a labelled ConfigMap
        │   └── templates/          # one values file per Helm release, plus the ConfigMap template
        └── k8s_argocd/
            ├── defaults/main.yml   # all configurable variables
            ├── meta/main.yml
            ├── tasks/main.yml
            └── templates/
                ├── argocd-values.yaml.j2          # values for the argo/argo-cd release
                └── bootstrap-application.yaml.j2  # the app-of-apps Application, applied only when a repo is set
```

`group_vars/all.yml` sits next to the playbooks, so every play here picks it
up — including the ones Terraform runs against the inventory it generates at
`../terraform/inventory.ini`. It
holds the lab addresses (`lab_host_ip`, `lab_registry_host`,
`lab_registry_port`, …) that `containerd_registry_trust` defaults to, so the
endpoint is stated once rather than in the role. The full network map is in
[the README's Networking section](../README.md#networking).

## Requirements

- Ansible >= 2.14 on the control node.
- Target host(s): Ubuntu/Debian with `apt` (tested against Ubuntu noble).
- SSH access with a sudo-capable user, or run locally (see below).
- Target host must be able to reach `apt.releases.hashicorp.com` and the
  distro's regular apt mirrors.

No Ansible collections are required — the role only uses modules that ship
with `ansible-core` (`apt`, `apt_repository`, `get_url`, `command`, `user`,
`file`).

## Quick start

All commands below assume you run them from the `ansible/` directory:

```bash
cd ansible
```

### Run against the local machine

`inventory.ini` already defines a `localhost` entry using
`ansible_connection=local`:

```bash
ansible-playbook -i inventory.ini playbook.yml --ask-become-pass
```

### Run against a remote host

Edit `inventory.ini` (or pass `-i` to a different inventory file) and add a
host under `[workstation]`:

```ini
[workstation]
workstation ansible_host=192.168.1.50 ansible_user=spellbound
```

Then:

```bash
ansible-playbook -i inventory.ini playbook.yml --ask-become-pass
```

### Dry run

```bash
ansible-playbook -i inventory.ini playbook.yml --check --diff
```

Note: the `--check` run will report false positives for the `command`
tasks (GPG dearmor, libvirt pool setup) since Ansible can't simulate
arbitrary commands — read the `apt`/`file` diffs and treat command-task
output as informational only.

## What the role does

1. Installs `curl` and `gpg` (needed to fetch/verify the HashiCorp key).
2. Downloads the HashiCorp GPG key and dearmors it into
   `/usr/share/keyrings/hashicorp-archive-keyring.gpg`.
3. Adds the HashiCorp apt repository (`apt.releases.hashicorp.com`), signed
   with that keyring, then refreshes the apt cache.
4. Installs the `terraform` package.
5. If `lab_workstation_install_libvirt` is true (default):
   - Installs the QEMU/libvirt packages (`qemu-system-x86`,
     `libvirt-daemon-system`, `libvirt-clients`, etc.).
   - Adds the target user to the `libvirt` and `kvm` groups — which is what
     lets both `virsh` and the `dmacvicar/libvirt` Terraform provider talk to
     `qemu:///system` without sudo.
   - Ensures the libvirt storage pool used for VM disk images exists at the
     configured path (creates/builds/starts/autostarts it if missing; if a
     pool with that name already exists at a *different* path, the task
     fails rather than risk moving/losing existing VM storage).

## Role variables

All variables live in `ansible/roles/lab_workstation/defaults/main.yml` and can
be overridden in the playbook, inventory, `-e`, or a `group_vars`/`host_vars`
file.

| Variable | Default | Purpose |
|---|---|---|
| `lab_workstation_user` | `{{ ansible_user_id }}` | User granted the group memberships and ownership of the storage-pool directory — the one who runs `terraform apply`. |
| `lab_workstation_prerequisite_packages` | `[curl, gpg]` | Packages needed to add the HashiCorp repo. |
| `lab_workstation_hashicorp_gpg_key_url` | `https://apt.releases.hashicorp.com/gpg` | Where the signing key is fetched from. |
| `lab_workstation_hashicorp_keyring` | `/usr/share/keyrings/hashicorp-archive-keyring.gpg` | Dearmored keyring path used to sign the repo. |
| `lab_workstation_hashicorp_repo` | `deb [signed-by=...] https://apt.releases.hashicorp.com {{ ansible_distribution_release }} main` | The apt repo line added to `/etc/apt/sources.list.d/hashicorp.list`. |
| `lab_workstation_terraform_package` | `terraform` | Package name/version spec passed to `apt`. |
| `lab_workstation_install_libvirt` | `true` | Set `false` to install terraform only, skipping everything libvirt-related below. |
| `lab_workstation_libvirt_packages` | see defaults | QEMU/libvirt packages the lab VMs run on. |
| `lab_workstation_manage_libvirt_group_membership` | `true` | Adds `lab_workstation_user` to `lab_workstation_libvirt_groups`. |
| `lab_workstation_libvirt_groups` | `[libvirt, kvm]` | Groups added when the above is true. **Takes effect on the user's next login session**, not the current one. |
| `lab_workstation_storage_pool_name` | `default` | Name of the libvirt storage pool used for VM disk images — Terraform's `pool` variable must match. |
| `lab_workstation_storage_pool_path` | `/var/lib/libvirt/images` | Directory backing that pool. Change this to point VM disk storage at a different disk/mount. |

### Example: custom storage location, terraform-only install

```yaml
# ansible/host_vars/workstation.yml
lab_workstation_storage_pool_path: /data/libvirt/images
```

```yaml
# to skip libvirt entirely and only install the terraform binary:
lab_workstation_install_libvirt: false
```

## After running

Log out/in (or reboot) so the new `libvirt`/`kvm` group membership takes
effect, then verify:

```bash
terraform version
virsh pool-list --all
```

## Known gotchas

- If a libvirt storage pool named `default` already exists (common on any
  host that's had libvirt installed before) pointing somewhere other than
  `lab_workstation_storage_pool_path`, the role fails intentionally instead
  of redefining it — migrate the pool by hand first if you need to relocate
  existing VM disks.

## `k8s_node_hosts` role

The first role `k8s-node-prereqs.yml` runs on every node. It writes a
delimited block into each guest's `/etc/hosts` carrying every node's name and
lab IP (from the generated inventory's `ansible_host`), so any node can
resolve any other by hostname. It only knows about nodes in the inventory —
`registry.lab` points at the *host* and is written by
[`containerd_registry_trust`](#containerd_registry_trust-role) instead. The
workstation's own `/etc/hosts` is not managed; see the root README for the
entries to add by hand.

No variables — the block is derived entirely from the inventory groups.

## `k8s_node_prereqs` role

Prepares the three `spellcore_k8s_lab` guest VMs (`k8s-control`, `k8s-worker1`,
`k8s-worker2`) for `kubeadm`. This role only gets the nodes to the point where
`kubeadm init`/`kubeadm join` will work; running those is the job of the
[cluster bootstrap roles](#cluster-bootstrap-roles) in the next playbook.

No Ansible collections are required here either — only `ansible-core`
modules: `apt`, `apt_repository`, `get_url`, `command`, `file`, `template`,
`copy`, `replace`, `stat`, `service`, `dpkg_selections`.

### How it's invoked

Unlike the `lab_workstation` role, this one is **not** run from this directory
with `ansible-playbook -i inventory.ini`. It's triggered automatically by
`terraform apply` (see `../terraform/provision.tf`), which runs
`k8s-node-prereqs.yml` against the inventory Terraform generates at
`../terraform/inventory.ini` (correct SSH key and user per VM) once every node
is up.

You can also run it manually against that inventory for testing, from the
repo root:

```bash
ansible-playbook -i terraform/inventory.ini ansible/k8s-node-prereqs.yml
```

### What the role does

1. Disables swap (`swapoff -a` + comments out swap entries in `/etc/fstab`).
2. Loads and persists the `overlay` and `br_netfilter` kernel modules.
3. Sets sysctl params required for bridged pod networking
   (`net.bridge.bridge-nf-call-iptables`, `net.bridge.bridge-nf-call-ip6tables`,
   `net.ipv4.ip_forward`, all `1`).
4. Installs `containerd.io` from Docker's official apt repository (same
   GPG-key/apt_repository pattern as the `lab_workstation` role's HashiCorp repo),
   generates its default config, and switches `SystemdCgroup` on.
5. Installs `kubelet`/`kubeadm`/`kubectl` from the Kubernetes community apt
   repository (`pkgs.k8s.io`) pinned to `k8s_node_prereqs_kubernetes_version`,
   then holds them at that version (`dpkg_selections`, the module-based
   equivalent of `apt-mark hold`).
6. Enables and starts `kubelet` (it will repeatedly restart/wait until
   `kubeadm init`/`join` gives it a config — expected, not a failure).
7. Disables `ufw` if it's active.
8. Optionally installs `cri-tools` (`crictl`) and configures
   `/etc/crictl.yaml` to point at the containerd socket, for debugging.

### Role variables

All variables live in `ansible/roles/k8s_node_prereqs/defaults/main.yml`.

| Variable | Default | Purpose |
|---|---|---|
| `k8s_node_prereqs_prerequisite_packages` | `[curl, gpg, ca-certificates]` | Packages needed to add the apt repos below. |
| `k8s_node_prereqs_apt_keyrings_dir` | `/etc/apt/keyrings` | Where dearmored GPG keyrings are stored. |
| `k8s_node_prereqs_disable_swap` | `true` | Set `false` to skip swap handling entirely. |
| `k8s_node_prereqs_configure_kernel_modules` | `true` | Set `false` to skip loading/persisting kernel modules. |
| `k8s_node_prereqs_kernel_modules` | `[overlay, br_netfilter]` | Modules loaded and written to `k8s_node_prereqs_modules_load_file`. |
| `k8s_node_prereqs_modules_load_file` | `/etc/modules-load.d/k8s.conf` | Persisted module list, loaded on every boot. |
| `k8s_node_prereqs_configure_sysctl` | `true` | Set `false` to skip sysctl configuration. |
| `k8s_node_prereqs_sysctl_params` | see defaults | Map of sysctl key/value pairs written to `k8s_node_prereqs_sysctl_file`. |
| `k8s_node_prereqs_sysctl_file` | `/etc/sysctl.d/k8s.conf` | Sysctl drop-in file, applied via `sysctl --system`. |
| `k8s_node_prereqs_install_containerd` | `true` | Set `false` to skip installing/configuring containerd entirely. |
| `k8s_node_prereqs_docker_gpg_key_url` | `https://download.docker.com/linux/ubuntu/gpg` | Docker apt repo signing key. |
| `k8s_node_prereqs_docker_keyring` | `{{ k8s_node_prereqs_apt_keyrings_dir }}/docker.gpg` | Dearmored keyring path used to sign the Docker repo. |
| `k8s_node_prereqs_docker_repo_arch` | `amd64` | Architecture used in the Docker apt repo line. |
| `k8s_node_prereqs_docker_repo` | see defaults | The apt repo line added to `/etc/apt/sources.list.d/docker.list`. |
| `k8s_node_prereqs_containerd_package` | `containerd.io` | Package installed from the Docker repo. |
| `k8s_node_prereqs_containerd_config_path` | `/etc/containerd/config.toml` | containerd config file; generated on first run if absent, `SystemdCgroup` always forced to `true`. |
| `k8s_node_prereqs_kubernetes_version` | `1.35.2` | Full version installed and held for `kubelet`/`kubeadm`/`kubectl`. |
| `k8s_node_prereqs_kubernetes_minor_version` | derived, e.g. `1.35` | Minor stream used to build the `pkgs.k8s.io` key/repo URLs; follows `k8s_node_prereqs_kubernetes_version` automatically. |
| `k8s_node_prereqs_kubernetes_packages` | `[kubelet, kubeadm, kubectl]` | Packages installed/held. |
| `k8s_node_prereqs_hold_kubernetes_packages` | `true` | Set `false` to install without holding (e.g. to allow later manual upgrades). |
| `k8s_node_prereqs_disable_ufw` | `true` | Set `false` to leave `ufw` alone even if active. |
| `k8s_node_prereqs_install_crictl` | `true` | Installs `cri-tools` and `/etc/crictl.yaml` pointed at the containerd socket. |
| `k8s_node_prereqs_crictl_package` | `cri-tools` | Package name for `crictl`. |
| `k8s_node_prereqs_crictl_config_path` | `/etc/crictl.yaml` | Where the crictl config is written. |
| `k8s_node_prereqs_crictl_runtime_endpoint` | `unix:///run/containerd/containerd.sock` | Runtime/image endpoint written into the crictl config. |

## Cluster bootstrap roles

Five roles that take the `spellcore_k8s_lab` nodes from "prerequisites installed"
(the `k8s_node_prereqs` state above) to a running, `Ready` cluster you can
drive from your own workstation: `k8s_control_plane_init`,
`k8s_kubeconfig_cni`, `k8s_cluster_join`, `k8s_metrics_server`,
`k8s_host_kubeconfig`. Like `k8s_node_prereqs`, they're invoked automatically
by `terraform apply` (`k8s-cluster-bootstrap.yml`, run right after
`k8s-node-prereqs.yml` and `k8s-registry-trust.yml`) rather than run by hand
with `ansible-playbook -i inventory.ini`.

No Ansible collections are required — only `ansible-core` modules: `apt`,
`stat`, `command`, `getent`, `file`, `copy`, `get_url`, `slurp`, `tempfile`,
`fail`, `set_fact`, `debug`.

### How it's invoked

Same mechanism as `k8s_node_prereqs`: `terraform apply` from the `terraform/`
directory runs `k8s-cluster-bootstrap.yml` against the generated inventory
once every node is up. You can also run it by hand against that inventory for
testing, from the repo root:

```bash
ansible-playbook -i terraform/inventory.ini ansible/k8s-cluster-bootstrap.yml
```

### Why five roles, run in this order

`k8s-cluster-bootstrap.yml` runs five plays, one role each, strictly in
sequence:

1. **`k8s_control_plane_init`** (`hosts: k8s_control`) — installs `etcdctl`
   (`etcd-client` package), runs `kubeadm init` on `k8s-control` (skipped if
   `/etc/kubernetes/admin.conf` already exists) and generates a `kubeadm
   token create --print-join-command` result, registered as a fact for the
   next play to read via `hostvars`.
2. **`k8s_kubeconfig_cni`** (`hosts: k8s_control`) — copies `admin.conf` into
   `~/.kube/config` for both root and the SSH login user on
   `k8s-control`, delegates the same `~/.kube/config` staging out to
   `k8s-worker1`/`k8s-worker2` (via `delegate_to`, since the workers have no
   `admin.conf` of their own to copy from), then installs Calico as the CNI
   (Tigera operator + `custom-resources.yaml`).
3. **`k8s_cluster_join`** (`hosts: k8s_workers`) — runs `kubeadm join` on
   `k8s-worker1`/`k8s-worker2` (skipped per-node if
   `/etc/kubernetes/kubelet.conf` already exists), using the join command
   `hostvars`-referenced from the control-plane play.
4. **`k8s_metrics_server`** (`hosts: k8s_control`) — applies the upstream
   `metrics-server` manifest, patches in `--kubelet-insecure-tls`, and waits
   until `kubectl top nodes` actually answers. This is what makes
   `kubectl top` and HorizontalPodAutoscaler resource metrics work.
5. **`k8s_host_kubeconfig`** (`hosts: k8s_control`) — reads `admin.conf` off
   `k8s-control` and writes a `spellcore-k8s-lab` cluster/user/context into the
   kubeconfig on **your workstation**, then makes it the current context.

The CNI is deliberately installed **before** workers join (play 2 before
play 3), not after — so no worker ever sits around joined but without pod
networking. Play 4 comes after the join so its readiness check covers every
node, not just the control plane. Play 5 runs last so the context it hands you
points at a cluster that's already complete.

### `k8s_control_plane_init` role variables

All variables live in `ansible/roles/k8s_control_plane_init/defaults/main.yml`.

| Variable | Default | Purpose |
|---|---|---|
| `k8s_control_plane_init_install_etcdctl` | `true` | Set `false` to skip installing `etcdctl`. |
| `k8s_control_plane_init_etcdctl_package` | `etcd-client` | Apt package providing the `etcdctl` binary. |
| `k8s_control_plane_init_endpoint` | `192.168.56.10` | `--apiserver-advertise-address` passed to `kubeadm init`. Must track `k8s-control`'s IP in the `nodes` map in `../terraform/variables.tf`. |
| `k8s_control_plane_init_pod_network_cidr` | `10.244.0.0/16` | `--pod-network-cidr` passed to `kubeadm init`. Must match `calicoNetwork.ipPools[0].cidr` in `k8s_kubeconfig_cni`'s `custom-resources.yaml` — chosen to not overlap with the `192.168.56.0/24` lab network. |

### `k8s_kubeconfig_cni` role variables

All variables live in `ansible/roles/k8s_kubeconfig_cni/defaults/main.yml`.

| Variable | Default | Purpose |
|---|---|---|
| `k8s_kubeconfig_cni_user` | `{{ ansible_user_id }}` | User whose `~/.kube/config` is populated from `admin.conf` (with `become: true`, this resolves to `root`). |
| `k8s_kubeconfig_cni_kube_config_users` | `{{ [k8s_kubeconfig_cni_user, ansible_user \| default('spellcore')] \| unique }}` | Users who get `admin.conf` staged as `~/.kube/config`, on `k8s-control` and on every host in `k8s_workers`. Always includes the SSH login user so interactive sessions on a node have working `kubectl` access. |
| `k8s_kubeconfig_cni_calico_version` | `v3.30.2` | Calico release used to build the Tigera operator manifest URL below. |
| `k8s_kubeconfig_cni_tigera_operator_url` | `https://raw.githubusercontent.com/projectcalico/calico/{{ k8s_kubeconfig_cni_calico_version }}/manifests/tigera-operator.yaml` | Operator manifest, installed with `kubectl create` (not `apply` — its CRDs are too large for the `apply` annotation). |
| `k8s_kubeconfig_cni_custom_resources_remote_path` | `/tmp/calico-custom-resources.yaml` | Where `files/custom-resources.yaml` is copied on the control-plane node before `kubectl apply`. |
| `k8s_kubeconfig_cni_wait_for_ready` | `true` | Set `false` to skip waiting for `k8s-control` to reach `Ready` after applying the CNI. |
| `k8s_kubeconfig_cni_wait_for_ready_timeout` | `300` | Seconds passed to `kubectl wait --timeout` when the above is enabled. |

`files/custom-resources.yaml` is the Calico `Installation`/`APIServer`/
`Goldmane`/`Whisker` manifest (moved here from `custom-resources.yaml` at the
repo root, with its pod CIDR updated to
`10.244.0.0/16` to match `k8s_control_plane_init_pod_network_cidr`).

### `k8s_cluster_join` role variables

None — it reads the join command straight out of
`hostvars[groups['k8s_control'][0]].k8s_control_plane_init_join_command_result.stdout`,
populated by `k8s_control_plane_init` in the first play.

### `k8s_metrics_server` role

A `kubeadm` cluster ships no metrics pipeline at all: nothing serves the
aggregated `metrics.k8s.io` API, so `kubectl top nodes` fails outright and every
HorizontalPodAutoscaler sits at `TARGETS: <unknown>`. This role installs
[metrics-server](https://github.com/kubernetes-sigs/metrics-server), which
scrapes each kubelet's `/metrics/resource` endpoint into a ~15s in-memory window
and serves it as that API.

It lives in the **bootstrap** playbook, not in `k8s-observability.yml`, on
purpose. `metrics.k8s.io` is core cluster API surface that `kubectl top` and
autoscaling depend on, and it must not acquire a dependency on the telemetry
stack — whose pods are pinned to single nodes by local-path volumes. That also
means the role uses the raw-manifest pattern (`get_url` + `kubectl apply`, as in
`k8s_local_path_storage`) rather than the Helm pattern in `k8s_observability`:
`helm` is only on the VM because `k8s-observability.yml` installs `helm_cli`.

metrics-server is **not** a frontend over a metrics store. It has no pluggable
backend, so it cannot be pointed at Loki/Tempo/Grafana or at a Prometheus/Mimir
TSDB — and conversely, the observability stack cannot serve `metrics.k8s.io`.
The only way to get resource metrics out of a TSDB instead is to drop this role
and run `prometheus-adapter` with `rules.resource`, which would make `kubectl
top` depend on the whole telemetry pipeline being healthy and serve data roughly
45–60s stale instead of ~15s. Not the trade this lab wants.

Two things the upstream manifest gets right for this cluster and one it does
not:

- `--kubelet-preferred-address-types` already leads with `InternalIP`, and the
  node `InternalIP`s here are the lab addresses (`192.168.56.10/.11/.12`) —
  each node's single NIC is both its lab interface and its default route, so
  kubelet can't pick anything else. Scrapes reach the right host. Confirm with
  `kubectl get nodes -o wide` before touching that ordering.
- The `v1beta1.metrics.k8s.io` APIService registration is in the same manifest,
  so there is nothing extra to apply.
- **`--kubelet-insecure-tls` has to be added.** `kubeadm init` leaves
  `serverTLSBootstrap` at its default of `false`, so every kubelet serves a
  self-signed certificate the cluster CA never issued (`kubectl get csr` returns
  nothing). Without the flag, metrics-server comes up `Ready` and then fails
  every scrape with `x509: cannot validate certificate ... doesn't contain any
  IP SANs`, while `kubectl top` reports "metrics not available yet" forever. The
  alternative — `serverTLSBootstrap: true` plus approving a kubelet-serving CSR
  per node on every rotation — adds a manual step to `terraform apply` and buys
  nothing on an isolated private network. Same lab-only posture as
  `lab_registry_scheme: "http"`; don't carry it anywhere real.

The flag is applied by rewriting the container's whole `args` array with
`kubectl patch --type=json`, guarded by a read of the current args. An `add` op
on `args/-` would be simpler and would stack a duplicate flag on every
provisioning re-run.

The role finishes by waiting on three separate things, because each can succeed
while the next still fails: the Deployment becoming Available, the APIService
reaching `condition=Available` (the aggregation layer needs a moment past pod
readiness, and `kubectl top` returns a confusing "server could not find the
requested resource" in that gap), and finally `kubectl top nodes` returning
non-zero — the only check that proves scrapes are actually succeeding rather
than silently failing TLS verification.

#### `k8s_metrics_server` role variables

All variables live in `ansible/roles/k8s_metrics_server/defaults/main.yml`.

| Variable | Default | Purpose |
|---|---|---|
| `k8s_metrics_server_enabled` | `true` | Set `false` (in `host_vars`/`group_vars`) to skip the play entirely. Wired in `k8s-cluster-bootstrap.yml`, not in the role. |
| `k8s_metrics_server_kubeconfig` | `/etc/kubernetes/admin.conf` | Kubeconfig every `kubectl` call in the role uses. |
| `k8s_metrics_server_version` | `v0.9.0` | metrics-server release. Builds against Kubernetes 1.36.2; the cluster is on 1.35.2. |
| `k8s_metrics_server_manifest_url` | `https://github.com/kubernetes-sigs/metrics-server/releases/download/{{ k8s_metrics_server_version }}/components.yaml` | Upstream manifest — RBAC, Service, Deployment and the APIService in one file. |
| `k8s_metrics_server_manifest_remote_path` | `/tmp/metrics-server-{{ k8s_metrics_server_version }}.yaml` | Where it's downloaded on the control-plane node before `kubectl apply`. |
| `k8s_metrics_server_namespace` | `kube-system` | Read, never written — the manifest hardcodes this. |
| `k8s_metrics_server_deployment` | `metrics-server` | Deployment name used by the patch and rollout guards. |
| `k8s_metrics_server_apiservice` | `v1beta1.metrics.k8s.io` | The aggregated API waited on before the `kubectl top` check. |
| `k8s_metrics_server_kubelet_insecure_tls` | `true` | Set `false` only if you've enabled `serverTLSBootstrap` and approve kubelet-serving CSRs yourself. Skips the args patch entirely. |
| `k8s_metrics_server_args` | 6 flags (see above) | The container's full argument list. The first five are the upstream v0.9.0 defaults reproduced verbatim; only `--kubelet-insecure-tls` is ours. **Re-check these against `components.yaml` on a version bump** — a flag added upstream would otherwise be silently dropped. |
| `k8s_metrics_server_rollout_timeout` | `180` | Seconds for `kubectl rollout status`. |
| `k8s_metrics_server_apiservice_timeout` | `120` | Seconds for `kubectl wait` on the APIService. |
| `k8s_metrics_server_top_retries` | `12` | Attempts at `kubectl top nodes` while the first `--metric-resolution` window elapses. |
| `k8s_metrics_server_top_delay` | `5` | Seconds between those attempts. |

### `k8s_host_kubeconfig` role

The one role here that changes something on **your workstation** rather than
inside a VM. Its play targets `k8s_control` only so it can `slurp`
`admin.conf`; every other task is `delegate_to: localhost` with `become:
false`, so it acts as the user who ran `terraform apply`.

It gives you a working `kubectl` against the cluster without SSHing into a
node:

```bash
kubectl get nodes          # already pointed at the lab cluster
```

**No tunnel or port-forward is involved.** `kubeadm init` runs with
`--apiserver-advertise-address=192.168.56.10` (see
`k8s_control_plane_init_endpoint`), so the API server listens on
`k8s-control`'s lab address, that address is routable from the
host over the lab network, and it's in the API server cert's
SANs — so TLS verification succeeds against it as-is.

#### How it avoids clobbering your other contexts

The role writes exactly three entries, under fixed names
(`spellcore-k8s-lab` / `spellcore-k8s-lab-admin` / `spellcore-k8s-lab`), using
`kubectl config set-cluster`, `set-credentials` and `set-context`. Each of
those replaces one named entry in place. Consequences worth relying on:

- Contexts for **unrelated** clusters in the same kubeconfig are never read,
  rewritten or removed.
- Re-running the provisioning — including after a `terraform destroy`, which
  mints an entirely new CA — **overwrites the previous run's entries** rather
  than accumulating a second one, because the names don't change between runs.
- `kubectl config use-context` at the end is the only thing that touches
  shared state (`current-context`); set `k8s_host_kubeconfig_set_current:
  false` to install the context without selecting it.

Which file it writes to follows `KUBECONFIG`: its first `:`-separated entry
if that variable is set in the shell you run `terraform apply` from, and
`~/.kube/config` otherwise. The first time the role modifies that file it
saves a one-time copy as `<path>.pre-spellcore-k8s-lab.bak`.

The `set-*` commands always exit 0 and always print the same line, so the
role reports `changed` off a checksum comparison of the kubeconfig taken
across the whole update instead — a re-run against an unchanged cluster
reports `ok`.

#### `k8s_host_kubeconfig` role variables

All variables live in `ansible/roles/k8s_host_kubeconfig/defaults/main.yml`.

| Variable | Default | Purpose |
|---|---|---|
| `k8s_host_kubeconfig_enabled` | `true` | Set `false` to skip the role entirely (checked as a `when:` on the role in `k8s-cluster-bootstrap.yml`). |
| `k8s_host_kubeconfig_path` | first entry of `KUBECONFIG`, else `~/.kube/config` | Kubeconfig file on the workstation that gets the three entries. Both lookups resolve on the machine running `ansible-playbook`. |
| `k8s_host_kubeconfig_cluster_name` | `spellcore-k8s-lab` | Name of the cluster entry. |
| `k8s_host_kubeconfig_user_name` | `spellcore-k8s-lab-admin` | Name of the user entry. |
| `k8s_host_kubeconfig_context_name` | `spellcore-k8s-lab` | Name of the context entry, and what `kubectl config use-context` selects. |
| `k8s_host_kubeconfig_set_current` | `true` | Make the context current. Set `false` to install it without switching to it. |
| `k8s_host_kubeconfig_server` | `""` | API server URL recorded in the cluster entry. Empty means "whatever `admin.conf` already points at", which is correct unless you front the API server with something else. |
| `k8s_host_kubeconfig_backup` | `true` | Take the one-time `<path>.pre-spellcore-k8s-lab.bak` copy before the first modification. Not refreshed on later runs. |
| `k8s_host_kubeconfig_verify` | `true` | Run `kubectl get nodes` through the new context at the end, so a broken context fails the provisioning run rather than surfacing later. |

Requires `kubectl` on the workstation — the role fails with an explicit
message if it isn't on `PATH`, rather than leaving a half-written kubeconfig.

`--embed-certs` reads PEM from files while `admin.conf` carries the CA and
client material base64-encoded inline, so the role writes them to a `0600`
temp dir on the workstation for the duration of the three `kubectl` calls and
removes it in an `always:` block. Those tasks are `no_log: true`, so the
client key never reaches Ansible's output.


## `containerd_registry_trust` role

Configures the nodes to pull from the lab registry at `registry.lab:5000`
(→ `192.168.56.1`, plain HTTP, no auth — see
[the README's Networking section](../README.md#networking)). **Node side
only:** it doesn't install or run a registry, it makes the cluster able to use
the one on the host.

Invoked from `k8s-registry-trust.yml` by `terraform apply`,
between `k8s-node-prereqs.yml` and `k8s-cluster-bootstrap.yml`, so the trust is
in place before the cluster comes up. Three things have to line up before a
kubelet can pull `registry.lab:5000/...`, and the role does one each:

1. **The name has to resolve.** The `k8s_node_hosts` role fills each node's
   `/etc/hosts` with every *node* name — but that is all it can provide: it
   maps names to nodes in the inventory, and `registry.lab` points at the
   host. The role writes `192.168.56.1 registry.lab` itself.
2. **containerd has to read `certs.d`.** `containerd.io` ships its own
   `config.toml` with every plugin setting commented out, so
   `registry.config_path` is empty — which means "ignore `certs.d` entirely".
   The role sets it to `/etc/containerd/certs.d` (appending a marked block, or
   editing the value in place if a `[plugins...registry]` table already
   exists), validated with `containerd -c <file> config dump` before it's
   written, then restarts containerd.
3. **The entry has to say "plain HTTP".** `certs.d/registry.lab:5000/hosts.toml`
   gets `server = "http://registry.lab:5000"` — the scheme is what stops
   containerd trying TLS. containerd re-reads that file on every pull, so
   changes to it alone need no restart.

It then confirms containerd's config actually points at `certs.d` (failing with
an explicit message if not), and tries `GET http://registry.lab:5000/v2/` from
the node — a warning, not a failure, so `terraform apply` still works when the
registry isn't up. Restarting containerd doesn't stop running containers, so
this is safe to re-run against a live cluster.

Re-run by hand against the running VMs from the repo root:

```bash
ansible-playbook -i terraform/inventory.ini ansible/k8s-registry-trust.yml
```

Check it:

```bash
ssh -i terraform/artifacts/lab_ed25519 spellcore@192.168.56.10 'curl -s http://registry.lab:5000/v2/_catalog'
ssh -i terraform/artifacts/lab_ed25519 spellcore@192.168.56.10 'sudo containerd config dump | grep -B3 config_path'
ssh -i terraform/artifacts/lab_ed25519 spellcore@192.168.56.10 'sudo crictl pull registry.lab:5000/myapp:dev'
```

`crictl pull` is the real test — same containerd path a kubelet uses.

| Variable | Default | Purpose |
|---|---|---|
| `containerd_registry_trust_host` | `{{ lab_registry_host }}` (`registry.lab`) | Registry hostname. |
| `containerd_registry_trust_port` | `{{ lab_registry_port }}` (`5000`) | Registry port. |
| `containerd_registry_trust_address` | `{{ lab_host_ip }}` (`192.168.56.1`) | Address the hostname resolves to on the node. |
| `containerd_registry_trust_endpoint` | `registry.lab:5000` | `host:port` — also the `certs.d` directory name, which must match how images are tagged. |
| `containerd_registry_trust_url` | `http://registry.lab:5000` | Full URL written into `hosts.toml`. Switch `lab_registry_scheme` to `https` if the registry ever grows TLS. |
| `containerd_registry_trust_capabilities` | `[pull, resolve]` | What containerd may do against this host. Add `push` to push from inside a node. |
| `containerd_registry_trust_skip_verify` | `false` | Only relevant for an HTTPS registry with an untrusted certificate. |
| `containerd_registry_trust_manage_hosts_entry` | `true` | Set `false` if you resolve `registry.lab` some other way. |
| `containerd_registry_trust_hosts_file` | `/etc/hosts` | File the entry is written to. |
| `containerd_registry_trust_config_path` | `/etc/containerd/config.toml` | containerd config edited in place. |
| `containerd_registry_trust_certs_dir` | `/etc/containerd/certs.d` | Directory `config_path` is pointed at. |
| `containerd_registry_trust_cri_images_plugin` | `io.containerd.cri.v1.images` | Plugin owning the registry config in containerd 2.x. containerd 1.x uses `io.containerd.grpc.v1.cri` instead. |
| `containerd_registry_trust_verify` | `true` | Try `/v2/` from the node at the end of the run. |
| `containerd_registry_trust_verify_timeout` | `5` | Seconds allowed for that request. |
| `containerd_registry_trust_required` | `false` | Set `true` to fail the run when the registry doesn't answer, instead of warning. |

## Observability roles

Three roles that stand up an OTLP telemetry backend on the running cluster —
Grafana for the UI, Tempo for traces, Loki for logs, MinIO as the shared S3
object store behind both, and an OpenTelemetry collector gateway that anything
in the cluster can push to: `helm_cli`, `k8s_local_path_storage`,
`k8s_observability`. Like the bootstrap roles they're invoked automatically by
`terraform apply` (`k8s-observability.yml`, run right after
`k8s-cluster-bootstrap.yml`).

Everything lands in an `observability` namespace, but the collector's ingest
endpoint is reachable from **every** namespace — the cluster has no default-deny
`NetworkPolicy`, so a plain `ClusterIP` Service resolves and connects from
anywhere. Point an OTLP exporter at:

```
otel-collector.observability.svc.cluster.local:4317   # OTLP/gRPC
otel-collector.observability.svc.cluster.local:4318   # OTLP/HTTP
```

Grafana is on a NodePort, reachable from your workstation's browser at
**<http://192.168.56.10:30300>** (`admin` / `lab-observability` by default —
see the credentials note below). NodePorts answer on every node, so `.11` and
`.12` work too. `30080` was already taken by `fathom/fathom-agent`.

This is a **traces, logs and metrics** stack. Metrics arrive by three separate
paths, which is worth keeping straight when one of them is empty:

- **Scraped** — Prometheus scrapes the cluster itself: the API server, each
  kubelet and its cAdvisor, plus kube-state-metrics (object state — pod phases,
  replica counts) and node-exporter (host CPU, memory, disk, network).
- **Pushed** — application metrics sent over OTLP to the collector gateway, the
  same endpoint traces and logs already use. The collector forwards them to
  Prometheus 3's native OTLP receiver.
- **Derived** — Tempo's metrics-generator turns spans into RED metrics
  (`traces_spanmetrics_*`) and service-graph edges (`traces_service_graph_*`)
  and remote-writes them to Prometheus. This is what powers Grafana's Service
  Graph tab.

Logs still come only from applications that emit OTLP plus Kubernetes events —
there is no per-node log-scraping DaemonSet, so pod `stdout`/`stderr` does
**not** land in Loki unless the app pushes it over OTLP. Adding that remains a
DaemonSet-shaped problem.

Prometheus stores to a local-path volume with **no object-storage backend** — it
does not use MinIO, unlike Tempo and Loki. Retention is therefore bounded by
disk, and long-term metrics would mean Thanos or Mimir in front of it.

`kubectl top` and HorizontalPodAutoscaler resource metrics are a separate
concern and *do* work — served by
[`k8s_metrics_server`](#k8s_metrics_server-role) in `kube-system`, installed by
the bootstrap playbook with no dependency on anything here. metrics-server keeps
a ~15s in-memory window and has no storage backend, so it is not a metrics store
and nothing in this stack can act as one for it; that is why the two are kept
apart.

No Ansible collections are required — only `ansible-core` modules: `stat`,
`command`, `get_url`, `unarchive`, `copy`, `file`, `template`, `set_fact`,
`debug`. Helm is driven as a CLI via `command` rather than through
`kubernetes.core`, which keeps that promise intact.

### How it's invoked

Same mechanism as the bootstrap roles: `terraform apply` runs
`k8s-observability.yml` against the generated inventory once every node is up.
To run it by hand, from the repo root:

```bash
ansible-playbook -i terraform/inventory.ini ansible/k8s-observability.yml
```

Re-running is a no-op: the playbook reports `changed=0` on a second pass, and
`helm -n observability list` still shows `REVISION 1` for all six releases.

### Why three roles, run in this order

`k8s-observability.yml` runs one cluster-scoped play from the control plane.
(Node root filesystems need no growing here: cloud-init's growpart expands
each node's root filesystem to the full 128 G disk at first boot, so
local-path volumes always have headroom.)

1. **`helm_cli`** (`hosts: k8s_control`) — installs a pinned,
   checksum-verified `helm` binary at `/usr/local/bin/helm`. Nothing else in
   this repo uses Helm; this is where it enters.
2. **`k8s_local_path_storage`** (`hosts: k8s_control`) — installs Rancher's
   local-path-provisioner and patches its StorageClass to be the cluster
   default. Before this role the cluster has **no StorageClass at all**, so
   every chart's PVC would sit `Pending` forever. The upstream manifest does
   not annotate its class as default, hence the separate patch.
3. **`k8s_observability`** (`hosts: k8s_control`) — installs the six Helm
   releases in dependency order: MinIO (so the buckets exist), then Prometheus
   (so Tempo's metrics-generator has somewhere to remote-write from its first
   second), then Tempo and Loki (which need those buckets), then the collector
   (so it isn't retrying against absent exporters), then Grafana last, because
   its provisioned datasources name the Tempo, Loki and Prometheus Services.
   kube-state-metrics and node-exporter are **subcharts of the Prometheus
   release**, not releases of their own, so `helm list` shows six, not eight.
   Finally it applies the cluster dashboards as labelled ConfigMaps for
   Grafana's sidecar to pick up — see [Dashboards and
   alerts](#dashboards-and-alerts).

### Dashboards and alerts

Dashboards and Grafana-managed alert rules are **delegated to whoever owns the
workload**, not centralised in this role's values files. The Grafana chart runs
two [`kiwigrid/k8s-sidecar`](https://github.com/kiwigrid/k8s-sidecar) containers
that watch the cluster for labelled ConfigMaps, write their contents into
Grafana's provisioning directories and POST the reload API:

| Sidecar | Watches for label | Payload |
| --- | --- | --- |
| `grafana-sc-dashboard` | `grafana_dashboard` | dashboard JSON |
| `grafana-sc-alerts` | `grafana_alert` | alerting provisioning YAML (`apiVersion: 1` plus `groups:` / `contactPoints:` / `policies:`) |

Both run with `searchNamespace: ALL`, so an application ships its own
observability alongside its own manifests, in its own namespace, with no change
to this role:

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

The seven cluster dashboards this role installs use exactly that mechanism
rather than the chart's `dashboards:` values key — one ConfigMap per dashboard
in the `observability` namespace, rendered from
`roles/k8s_observability/files/dashboards/*.json`. That is deliberate: the base
install exercises the delegation path, so it can't quietly rot while only
applications depend on it.

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
  `Kubernetes / Compute Resources / *` dashboard — the set everyone reaches for
  first — queries series like
  `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate`,
  which are *recording rules* shipped by `kube-prometheus-stack`'s operator. The
  plain Prometheus chart used here ships none of them, so those dashboards
  render entirely empty. The `dotdc/grafana-dashboards-kubernetes` set above
  queries raw metrics only, which is why it works.
- **Everything scraped by annotation shares one `job` label.**
  kube-state-metrics, node-exporter and CoreDNS all land under
  `job="kubernetes-service-endpoints"`, not under `job="node-exporter"` or
  `job="kube-state-metrics"` the way a `kube-prometheus-stack` cluster would.
  Dashboards with those job names hard-coded show nothing; the ones above
  populate their `$job` variable from a `label_values()` query instead.
- **There is no `cluster` label.** The `dotdc` dashboards filter every query by
  `cluster="$cluster"`, and the variable resolves to empty here. That is
  harmless — in PromQL `cluster=""` matches series where the label is *absent* —
  so the panels work with an empty cluster picker. Don't try to "fix" it with
  `global.external_labels`: those are applied on remote-write and federation
  only, never to locally stored series, so the picker would stay empty anyway.

Refreshing a dashboard is a re-download plus the same normalisation:

```bash
curl -sL https://grafana.com/api/dashboards/15757/revisions/latest/download \
  -o roles/k8s_observability/files/dashboards/k8s-views-global.json
```

then strip `__inputs`/`__requires`, null the numeric `id`, and set the
`datasource` template variable's `current` to the `prometheus` UID — see the
comment block in `defaults/main.yml` for why each of those matters.

### Why these charts and versions

Chart versions are pinned so a re-provision months from now deploys what was
tested. Some of these choices will look arbitrary without the reasoning:

| Component | Chart | Version | appVersion |
| --- | --- | --- | --- |
| Object store | `minio/minio` | `5.4.0` | `RELEASE.2024-12-18T13-15-44Z` |
| Traces | `grafana/tempo` | `1.24.4` | `2.9.0` |
| Logs | `grafana/loki` | `7.3.0` | `3.6.12` |
| UI | `grafana/grafana` | `10.5.15` | `12.3.1` |
| Collector | `open-telemetry/opentelemetry-collector` | `0.170.0` | `0.158.0` |
| Metrics | `prometheus-community/prometheus` | `29.25.0` | `v3.13.2` |
| Object state | `kube-state-metrics` (subchart of the above) | `8.3.0` | — |
| Host metrics | `prometheus-node-exporter` (subchart of the above) | `4.56.1` | — |
| StorageClass | *(raw manifest)* | `v0.0.37` | — |

- **`prometheus`, not `kube-prometheus-stack`.** The stack chart brings a
  CRD-installing operator, its own Grafana (a second one, next to the Grafana
  this role already deploys), and CRDs that `helm upgrade` will not update once
  installed. The plain server chart is the same monolithic-over-microservices
  call made for Tempo below. `alertmanager` and `prometheus-pushgateway` ship
  as subcharts and are **both disabled** — no alert routes are configured and
  nothing here pushes batch-job metrics, so they would be idle pods and a PVC.
  Each is one variable away if that changes.
- **`tempo`, not `tempo-distributed`.** Both ship appVersion `2.9.0`, but
  `tempo-distributed` is the microservices chart and would deploy eight
  separate components. The chart *name* is pinned in `defaults/main.yml`
  alongside the version so it can't drift.
- **Not `grafana/lgtm-distributed`.** It wraps the `-distributed` charts —
  roughly 30 pods — and was last published in November 2025.
- **local-path-provisioner via raw manifest, not a chart.** Rancher publishes
  no Helm repository index for it, only an in-tree chart directory. Applying
  the release manifest with `kubectl` also matches how `k8s_kubeconfig_cni`
  installs the Tigera operator.
- **MinIO's chart is abandoned** — published January 2025, and Grafana's own
  Loki chart now carries a comment about the unresolved CVE in the upstream
  MinIO images. It still deploys and serves S3 correctly, and it's what the
  Loki chart itself depends on. If it ever becomes a problem, the fallback is
  switching Tempo and Loki to their `filesystem` backends on local-path PVCs.
- **MinIO as its own release, not Loki's `minio` subchart.** Tempo needs the
  same object store, and burying it inside the Loki release would make Tempo's
  storage depend on a Loki value.
- **Helm 3, not 4.** Helm 4 is current upstream and is what the workstation
  runs, but its release notes call out backward-incompatible changes to CLI
  flags and output, and `k8s_observability`'s idempotence guards parse
  `helm status` and `helm repo list -o json`. Helm on the VM is a private
  detail of that role.

### Credentials

The MinIO root credentials and the Grafana admin password are **plaintext** in
`roles/k8s_observability/defaults/main.yml`. There is no vault in this repo, and
this cluster sits on an isolated private network reachable only from the host —
the same posture as `lab_registry_scheme: "http"` in `group_vars/all.yml`.

To change them, copy `host_vars/k8s-control.yml.example` to
`host_vars/k8s-control.yml` (untracked) and override there rather than editing
the defaults. They are never passed via `helm --set`, which would expose them in
`ps` output and in Ansible's task log; they reach Helm only through values files
rendered to `/root/observability/` at mode `0600`.

Note that MinIO's chart *generates* its root credentials when they are left
empty, which would rotate them on every re-provision and break Tempo and Loki
with S3 auth errors. They must always be set explicitly.

### `helm_cli` role variables

All variables live in `ansible/roles/helm_cli/defaults/main.yml`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `helm_cli_version` | `3.21.4` | Pinned Helm release. Bumping to 4.x is a one-line change plus a re-check of `k8s_observability`'s output-parsing guards. |
| `helm_cli_sha256` | `61f88ab1…` | Checksum from the published `.sha256sum`. `get_url` verifies against it, so a corrupted download fails the play. |
| `helm_cli_arch` | `linux-amd64` | Release archive flavour. |
| `helm_cli_url` | `https://get.helm.sh/helm-v…tar.gz` | Download location. |
| `helm_cli_binary_path` | `/usr/local/bin/helm` | Where the binary is installed. |
| `helm_cli_download_path` | `/tmp/helm-v….tar.gz` | Archive download location. |
| `helm_cli_extract_dir` | `/tmp/helm-extract` | Where the archive is unpacked before the binary is lifted out. |

### `k8s_local_path_storage` role variables

All variables live in `ansible/roles/k8s_local_path_storage/defaults/main.yml`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `k8s_local_path_storage_kubeconfig` | `/etc/kubernetes/admin.conf` | Same convention as the other cluster-facing roles — an explicit `--kubeconfig`, never a `KUBECONFIG` env var. |
| `k8s_local_path_storage_version` | `v0.0.37` | Pinned local-path-provisioner release. |
| `k8s_local_path_storage_manifest_url` | upstream `local-path-storage.yaml` | Release manifest applied with `kubectl`, same pattern as the Tigera operator. |
| `k8s_local_path_storage_manifest_remote_path` | `/tmp/local-path-storage.yaml` | Where the manifest is staged on the node. |
| `k8s_local_path_storage_namespace` | `local-path-storage` | Namespace the manifest creates. |
| `k8s_local_path_storage_deployment` | `local-path-provisioner` | Deployment waited on — a StorageClass has no `Ready` condition, so this is the real signal. |
| `k8s_local_path_storage_class_name` | `local-path` | StorageClass name. Volumes are directories under `/opt/local-path-provisioner` on whichever node the consuming pod lands on. |
| `k8s_local_path_storage_set_default` | `true` | Patch the class to be the cluster default. The upstream manifest does not annotate it, so without this every PVC needs an explicit `storageClassName`. |
| `k8s_local_path_storage_rollout_timeout` | `180` | Seconds allowed for the provisioner to become Available. |

### `k8s_observability` role variables

All variables live in `ansible/roles/k8s_observability/defaults/main.yml`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `k8s_observability_enabled` | `true` | Set `false` to run only the storage prerequisites. |
| `k8s_observability_kubeconfig` | `/etc/kubernetes/admin.conf` | Kubeconfig passed to both `kubectl` and `helm`. |
| `k8s_observability_helm_binary` | `/usr/local/bin/helm` | Binary installed by `helm_cli`. |
| `k8s_observability_helm_timeout` | `10m` | `--timeout` on each `helm upgrade --install --wait`. |
| `k8s_observability_namespace` | `observability` | Namespace for all six releases. |
| `k8s_observability_values_dir` | `/root/observability` | Where values files are rendered. Mode `0700`, files `0600`, because they carry credentials — a deliberate departure from the copy-to-`/tmp` convention used elsewhere. |
| `k8s_observability_helm_repos` | grafana, open-telemetry, minio, prometheus-community | Chart repositories added if absent. |
| `k8s_observability_minio_chart` / `_chart_version` | `minio/minio` / `5.4.0` | Object store. |
| `k8s_observability_tempo_chart` / `_chart_version` | `grafana/tempo` / `1.24.4` | Traces. Name is pinned too — see the `tempo-distributed` warning above. |
| `k8s_observability_loki_chart` / `_chart_version` | `grafana/loki` / `7.3.0` | Logs. |
| `k8s_observability_grafana_chart` / `_chart_version` | `grafana/grafana` / `10.5.15` | UI. |
| `k8s_observability_otel_chart` / `_chart_version` | `open-telemetry/opentelemetry-collector` / `0.170.0` | Collector gateway. |
| `k8s_observability_prometheus_chart` / `_chart_version` | `prometheus-community/prometheus` / `29.25.0` | Metrics. The plain server chart — see the `kube-prometheus-stack` note above. |
| `k8s_observability_minio_root_user` | `lab-minio` | MinIO root user. Plaintext lab credential — see Credentials above. |
| `k8s_observability_minio_root_password` | `lab-observability` | MinIO root password. Must be set explicitly or the chart generates and rotates it. |
| `k8s_observability_grafana_admin_user` | `admin` | Grafana login. |
| `k8s_observability_grafana_admin_password` | `lab-observability` | Grafana password. Set via the chart's `adminPassword` (which lands in a Secret), never via `grafana.ini`, whose plaintext path the chart refuses to render. |
| `k8s_observability_minio_service` | `minio.observability.svc.cluster.local` | S3 endpoint Tempo and Loki are pointed at. |
| `k8s_observability_tempo_service` | `tempo.observability.svc.cluster.local` | Tempo Service. |
| `k8s_observability_loki_service` | `loki.observability.svc.cluster.local` | Loki Service. |
| `k8s_observability_tempo_http_port` | `3200` | Tempo's HTTP API. **Not** 3100 — pointing Grafana's Tempo datasource at 3100 gives a datasource that saves cleanly and then returns nothing. |
| `k8s_observability_loki_http_port` | `3100` | Loki's HTTP API, and the OTLP ingest path `/otlp`. |
| `k8s_observability_prometheus_service` | `prometheus-server.observability.svc.cluster.local` | **`prometheus-server`, not `prometheus`.** The chart names the server Service `<release>-server`; there is no Service called plain `prometheus`. |
| `k8s_observability_prometheus_http_port` | `80` | The Service port. **Not 9090** — that is the container port, published on `servicePort: 80`. Same class of trap as Tempo's 3200 vs Loki's 3100. |
| `k8s_observability_minio_pvc_size` | `20Gi` | MinIO volume. |
| `k8s_observability_tempo_bucket` | `tempo` | Trace bucket. |
| `k8s_observability_loki_chunks_bucket` | `loki-chunks` | Loki chunk bucket. |
| `k8s_observability_loki_ruler_bucket` | `loki-ruler` | Loki ruler bucket. |
| `k8s_observability_tempo_retention` | `72h` | How long traces are kept. |
| `k8s_observability_loki_retention` | `168h` | How long logs are kept. |
| `k8s_observability_prometheus_retention` | `15d` | How long metrics are kept. Bounded by the local volume — there is no object-storage tier behind Prometheus. |
| `k8s_observability_prometheus_scrape_interval` | `30s` | Global scrape interval. The chart default is `1m`; nothing here needs finer than 30s. |
| `k8s_observability_tempo_pvc_size` | `10Gi` | Tempo WAL and unflushed blocks; durable blocks live in MinIO. |
| `k8s_observability_loki_pvc_size` | `10Gi` | Loki WAL and local index. |
| `k8s_observability_grafana_pvc_size` | `2Gi` | Grafana's dashboard database. |
| `k8s_observability_prometheus_pvc_size` | `20Gi` | The TSDB. Unlike Tempo's and Loki's, this is the *only* copy — nothing is flushed to MinIO. |
| `k8s_observability_storage_class` | `local-path` | StorageClass for all five volumes. |
| `k8s_observability_otel_image_repository` | `otel/opentelemetry-collector-k8s` | Mandatory: chart 0.170.0 ships an empty default and `fail`s without it. The small `k8s` distro already contains every component used here, so the much larger `contrib` image is unnecessary. |
| `k8s_observability_otel_image_tag` | `0.158.0` | Collector image tag. |
| `k8s_observability_otel_command_name` | `otelcol-k8s` | Must match the distro's binary name; also empty by default in this chart. |
| `k8s_observability_grafana_node_port` | `30300` | NodePort Grafana is exposed on. `30080` is taken by `fathom/fathom-agent`. |
| `k8s_observability_grafana_url` | `http://192.168.56.10:30300` | Reported at the end of the run. |
| `k8s_observability_prometheus_node_port` | `30090` | NodePort Prometheus is exposed on, for `/targets` — the page that answers "why is this metric missing?", which Grafana cannot show. |
| `k8s_observability_prometheus_url` | `http://192.168.56.10:30090` | Reported at the end of the run. |
| `k8s_observability_grafana_sidecar_search_namespace` | `ALL` | Namespaces the dashboard/alert sidecars watch. `ALL` is what makes delegation work, and depends on the chart's `rbac.namespaced` staying `false` — that is what creates the ClusterRole. |
| `k8s_observability_grafana_sidecar_dashboards_label` | `grafana_dashboard` | ConfigMap label the dashboard sidecar matches. Presence only; the chart leaves `labelValue` empty so the value is never compared. |
| `k8s_observability_grafana_sidecar_alerts_label` | `grafana_alert` | ConfigMap label the alert sidecar matches. |
| `k8s_observability_grafana_sidecar_folder_annotation` | `grafana_folder` | Annotation naming the Grafana folder. Only works together with `provider.foldersFromFilesStructure: true`, which the values template sets. |
| `k8s_observability_dashboards_dir` | `/root/observability/dashboards` | Where the ConfigMap manifests are rendered on the control node. `0755`, unlike the values directory — no credentials in these. |
| `k8s_observability_dashboards` | seven entries | `name` / `folder` / `source` per dashboard. `name` is both the JSON filename under `files/dashboards/` and the ConfigMap suffix. |

### Known gotchas

- **Almost all workloads land on the workers — node-exporter is the exception.**
  `k8s-control` carries `node-role.kubernetes.io/control-plane:NoSchedule`, so
  the schedulable budget is two nodes, about 8 vCPU and 15Gi, not three. Don't
  add control-plane tolerations to spread the load; that puts Loki next to etcd.
  The one deliberate exception is the **node-exporter DaemonSet**, whose chart
  default tolerations are `effect: NoSchedule, operator: Exists` — so it *does*
  run on `k8s-control`, which is exactly why all three nodes report host
  metrics. It collects; it does not schedule work there.
- **`WaitForFirstConsumer` pins each volume to one node.** Once MinIO's volume
  materialises on a worker, its pod can never be scheduled elsewhere. If that
  worker is destroyed the data is gone and the PVC has to be deleted by hand.
  This is also why MinIO's Deployment uses the `Recreate` strategy: the default
  `RollingUpdate` with `maxSurge: 100%` would deadlock trying to bind a
  `ReadWriteOnce` volume from a surge pod on the other node.
- **`helm upgrade --install` can't report idempotence by itself.** It always
  exits 0, always prints the same output, and Helm 3 mints a new revision on
  every invocation. Each release is therefore gated on "release absent **or**
  rendered values changed"; without that, every provisioning re-run would report
  `changed` and push a pointless revision.
- **The pinned collector distro has no `prometheusremotewrite` exporter.**
  `otel/opentelemetry-collector-k8s:0.158.0` ships exactly `debug`, `nop`,
  `otlp`, `otlphttp`, `file`, `loadbalancing` and `otelarrow`. The obvious way
  to write metrics to Prometheus is therefore *not available*, and the collector
  uses `otlphttp` into Prometheus 3's native OTLP receiver instead. Do **not**
  "fix" this by switching to the `contrib` image — the small distro still
  contains everything this stack uses.
- **Three Prometheus feature flags are load-bearing, and all fail silently.**
  `web.enable-remote-write-receiver` (Tempo's generator writes here),
  `web.enable-otlp-receiver` (the collector writes here) and
  `enable-feature=exemplar-storage` (without it exemplars are dropped at ingest,
  so Grafana's `exemplarTraceIdDestinations` and the metrics→trace jump quietly
  do nothing). They go in `server.extraFlags` **without** a leading `--`; the
  chart prepends the dashes, so `--web.enable-lifecycle` renders as
  `----web.enable-lifecycle` and the pod won't start.
- **OTLP metrics need `deltatocumulative` in the pipeline.** OTel SDKs commonly
  export delta temporality while Prometheus stores cumulative counters. Without
  the processor the data ingests with no error and then reads as sawtooths —
  `rate()` over it is meaningless.
- **Prometheus does not use MinIO.** It has no S3 backend, so its 20Gi
  local-path volume is the only copy of the metrics, and the
  `WaitForFirstConsumer` node-pinning caveat above applies to it too. Tempo and
  Loki keep only WAL locally; Prometheus keeps everything.
- **The Loki chart's defaults do not fit this cluster.** Out of the box it's
  `SimpleScalable` with nine read/write/backend pods, an nginx gateway, a canary
  DaemonSet and two memcached tiers — `chunksCache` alone requests 8Gi. The
  disable list in `loki-values.yaml.j2` is required, not tidying. Note that
  `test.enabled` must also be `false`: the chart fails the render if the canary
  is disabled while the test pod isn't.
- **Don't trim `tempo.receivers` to OTLP only.** The chart's `_ports.tpl`
  dereferences `receivers.jaeger.protocols.thrift_compact` unconditionally, so
  `jaeger: null` is a nil-pointer render error. The idle Jaeger and OpenCensus
  listeners are harmless.
- **MinIO's S3 API is reachable from every namespace**, for the same reason the
  collector is — no default-deny `NetworkPolicy`. Fine for a lab, worth knowing.
- **Dashboard ConfigMaps must be applied server-side.** A plain `kubectl apply`
  stores a verbatim copy of the manifest in the `last-applied-configuration`
  annotation, doubling the object. `node-exporter-full.json` is ~460KB, so the
  round trip lands at ~920KB against a 1MiB `ConfigMap` limit — it applies once
  and then fails on the next revision of the dashboard. `dashboards.yml` uses
  `apply --server-side --force-conflicts`, which writes no such annotation. Same
  reason each dashboard gets its own ConfigMap rather than one holding all seven.
- **Provisioned dashboards are read-only in the UI.** `allowUiUpdates` is
  `false`, so *Save* is unavailable — edit the JSON under
  `files/dashboards/` and re-run instead. Turning it on doesn't really help
  either: the sidecar overwrites the file whenever its ConfigMap changes, so a
  UI edit survives only until then. Use *Save as* for throwaway variants.
- **The default datasource is Tempo, so a dashboard that doesn't pin one lands
  on it.** Grafana honours exactly one default and this stack gives it to Tempo
  (see the note in `grafana-values.yaml.j2`). Every bundled dashboard has its
  `datasource` template variable pinned to the `prometheus` UID during
  normalisation; a dashboard dropped in without that step opens against Tempo
  and every panel errors. Pin `"datasource": {"type": "prometheus", "uid":
  "prometheus"}` in anything you add.
- **Deleting a dashboard ConfigMap deletes the dashboard.** `disableDeletion`
  is `false`, so the sidecar removes the file and Grafana drops the dashboard on
  the next provisioning pass. That is the intended behaviour for delegation —
  an application's dashboards leave with it — but it does mean a `kubectl delete
  configmap` is not recoverable from Grafana's side.
- **The PVC panels on the Nodes and Namespaces dashboards are empty here.** They
  query `kubelet_volume_stats_*`, which the kubelet's summary API does not report
  for the hostPath-backed volumes local-path-provisioner creates. Nothing is
  misconfigured; the metric does not exist in this cluster. Node Exporter Full's
  hwmon, systemd and power-supply rows are empty for the same class of reason —
  those collectors have nothing to read inside a libvirt guest.
- **`grafana/grafana` chart 10.5.15 is marked `deprecated: true` upstream**, and
  it is still the newest published version — `helm search repo --versions` shows
  nothing above it. `helm template` prints `this chart is deprecated` on every
  render. It installs and works; it just isn't receiving updates, so the
  eventual migration is to the Grafana operator's `Grafana` CRD. Not a
  today problem, but don't spend time looking for a newer chart version.

## Argo CD role

Deploys [Argo CD](https://argo-cd.readthedocs.io/) — the GitOps controller
that continuously reconciles the cluster against manifests in a git
repository — into its own `argocd` namespace, from the upstream
[`argo/argo-cd`](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
chart. Same Helm pattern as `k8s_observability`: a pinned chart version, a
values file rendered to `/root/argocd/`, a `helm status` guard and an
`upgrade --install` gated on "release absent or values changed".

### How it's invoked

`terraform apply` runs `k8s-argocd.yml` last, after `k8s-observability.yml`
(see `../terraform/provision.tf`). The playbook lists `helm_cli` again before
`k8s_argocd` even though the observability playbook already installs it: the
role is idempotent, and it makes this playbook runnable on its own. Nothing here
depends on the telemetry stack, and Argo CD needs no StorageClass — its state
lives in Kubernetes objects and a non-persistent Redis cache.

Re-run by hand against the running VMs from the repo root:

```bash
ansible-playbook -i terraform/inventory.ini ansible/k8s-argocd.yml
```

A second run against a healthy lab is a no-op (`changed=0`).

### What the role does

1. Waits for the API server, creates the `argocd` namespace, adds the `argo`
   chart repository if it's missing.
2. Renders `argocd-values.yaml` to `/root/argocd/` (`0700`/`0600` — it carries
   the admin password hash).
3. `helm upgrade --install argocd argo/argo-cd --version 10.9.1 --wait`,
   gated as above. Five pods — application controller, repo server, API
   server, Redis, ApplicationSet controller — plus a one-shot Redis
   secret-init Job.
4. Waits for `deployment/argocd-server` to roll out even on a no-op run, so a
   green `helm status` over a broken server still fails the play.
5. If `k8s_argocd_bootstrap_repo_url` is set, renders and `kubectl apply`s one
   `Application` — see [Bootstrapping from a repository](#bootstrapping-from-a-repository).
6. Reports the UI URL, the login, the CLI login command and the workloads.

### Exposure

The API server is a `NodePort` Service on `30800` (HTTP) — the cluster has no
ingress controller and no MetalLB, so a `LoadBalancer` would sit `<pending>`
forever. Answers on every node IP over the lab network:
<http://192.168.56.10:30800>.

It runs with `server.insecure: true`, meaning plain HTTP for the UI, the REST
API and gRPC on that one port instead of a self-signed certificate. Same
posture as Grafana and the lab registry. The consequence for the `argocd` CLI
is `--plaintext` rather than `--insecure`:

```bash
argocd login 192.168.56.10:30800 --username admin --password lab-argocd --plaintext
```

The chart also publishes an HTTPS Service port and wants a NodePort for it
(`30443`); under `server.insecure` it targets the same plain-HTTP container
port, so it's a duplicate of `30800`, not a TLS listener.

### Credentials

Argo CD has a single built-in `admin` account; its password is `lab-argocd`,
**plaintext** in `roles/k8s_argocd/defaults/main.yml`, for the same reason the
observability credentials are — see [Credentials](#credentials) above.
Override it in `host_vars/k8s-control.yml` rather than editing the defaults.

Argo CD stores the password as a **bcrypt hash** in `argocd-secret`, so the
values template hashes it at render time with
`password_hash('bcrypt', <salt>, rounds=10)`. Two things to know about that:

- **The filter runs on the workstation**, not the node — templates render
  wherever `ansible-playbook` runs — and it needs `passlib` and `bcrypt`
  importable by the Python Ansible uses. On Ubuntu that's `sudo apt install
  python3-passlib python3-bcrypt` (`ansible-core` only *recommends* passlib
  and doesn't pull in bcrypt at all); elsewhere `pip install passlib bcrypt`.
  Without them the render fails on the values template. This is the only role
  in the repo with a workstation-side Python dependency beyond Ansible itself.
- **The salt is fixed** (`k8s_argocd_admin_password_salt`). bcrypt normally
  salts randomly, which would change the hash — and therefore the rendered
  values file — on every run, and trip the "values changed → `helm upgrade`"
  gate every time. A fixed salt on a password that's already committed in
  plaintext costs nothing. `admin.passwordMtime` is pinned for the same reason;
  the chart otherwise stamps it with `now` on every render.

Left empty, the chart would instead have Argo CD generate a random initial
password into `argocd-initial-admin-secret`. That works, but it's a second
credential to go and fetch on every rebuild, which is what the fixed one avoids.

### Bootstrapping from a repository

The role installs Argo CD with **no applications**. The GitOps hand-off is an
[app-of-apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/):
set `k8s_argocd_bootstrap_repo_url` (in `host_vars/k8s-control.yml`) and the
role applies one `Application` named `bootstrap`, pointed at that repository's
`bootstrap/` directory, in the `argocd` namespace, with automated sync, prune
and self-heal. Every further `Application`, `ApplicationSet` and `AppProject`
is expected to come from that directory, not from this role.

```yaml
# ansible/host_vars/k8s-control.yml
k8s_argocd_bootstrap_repo_url: https://github.com/you/lab-gitops.git
```

The manifest is applied with `kubectl` rather than through the chart's
`extraObjects`, so adding or changing the bootstrap repository doesn't bump the
Helm release. It carries the `resources-finalizer.argocd.argoproj.io`
finalizer, so deleting `bootstrap` cascades to everything it created rather
than orphaning it.

The repository has to be reachable **from the cluster**. The lab network is
NAT'd, so public HTTPS repositories (GitHub, GitLab, …) work out of the box; a
private one needs a repository credential Secret in the `argocd` namespace
first — [declaratively](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories)
or via `argocd repo add` — and this role doesn't manage those.

### `k8s_argocd` role variables

All variables live in `ansible/roles/k8s_argocd/defaults/main.yml`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `k8s_argocd_enabled` | `true` | Set `false` to skip the role (checked as a `when:` on the role in `k8s-argocd.yml`). |
| `k8s_argocd_kubeconfig` | `/etc/kubernetes/admin.conf` | Kubeconfig passed to both `kubectl` and `helm`. |
| `k8s_argocd_helm_binary` | `/usr/local/bin/helm` | Binary installed by `helm_cli`. |
| `k8s_argocd_helm_timeout` | `10m` | `--timeout` on `helm upgrade --install --wait`. |
| `k8s_argocd_namespace` | `argocd` | Argo CD's namespace. The docs, the CLI and every example assume this name. |
| `k8s_argocd_release_name` | `argocd` | Helm release name; also the prefix of every object the chart creates (`argocd-server`, …). |
| `k8s_argocd_values_dir` | `/root/argocd` | Where the values file and bootstrap manifest are rendered. `0700`, because the values file carries the password hash. |
| `k8s_argocd_helm_repo_name` / `_url` | `argo` / `https://argoproj.github.io/argo-helm` | Chart repository, added if absent. |
| `k8s_argocd_chart` / `_chart_version` | `argo/argo-cd` / `10.9.1` | Pinned chart; appVersion v3.5.3. |
| `k8s_argocd_admin_password` | `lab-argocd` | The `admin` login. Plaintext lab credential — see Credentials above. |
| `k8s_argocd_admin_password_salt` | 22-char fixed string | bcrypt salt, fixed so the hash is stable across runs. Must be exactly 22 characters from `[./A-Za-z0-9]`; the role asserts this. |
| `k8s_argocd_admin_password_rounds` | `10` | bcrypt cost. |
| `k8s_argocd_admin_password_mtime` | `2026-09-15T00:00:00Z` | `admin.passwordMtime` in `argocd-secret`, pinned so the Secret is byte-identical across upgrades. Bump it when you change the password to invalidate old sessions. |
| `k8s_argocd_server_insecure` | `true` | Plain HTTP on the server port. Set `false` for the chart's self-signed TLS; the CLI then needs `--insecure` instead of `--plaintext`. |
| `k8s_argocd_server_node_port` | `30800` | HTTP NodePort. `30080` is fathom's, `30300`/`30090` Grafana's and Prometheus's. |
| `k8s_argocd_server_node_port_https` | `30443` | The chart's mandatory HTTPS NodePort. Under `server.insecure` it's a duplicate of the HTTP one. |
| `k8s_argocd_server_url` | `http://192.168.56.10:30800` | Written into `argocd-cm` as `url` (so UI-generated links are real) and reported at the end of the run. |
| `k8s_argocd_dex_enabled` | `false` | Dex SSO. Nothing to federate in the lab. |
| `k8s_argocd_notifications_enabled` | `false` | Notifications controller. Nowhere to send anything from an isolated network. |
| `k8s_argocd_applicationset_enabled` | `true` | ApplicationSet controller. One small pod; needed by any bootstrap repo that uses `ApplicationSet`. |
| `k8s_argocd_reconciliation_timeout` | `60s` | `timeout.reconciliation` in `argocd-cm`: how often every repo is re-polled. Upstream is `180s`; polling is the only way a push lands here, since no webhook can reach the lab. |
| `k8s_argocd_controller_resources` | 250m/512Mi, limit 1Gi | Application controller requests/limits. The chart ships none. |
| `k8s_argocd_repo_server_resources` | 100m/256Mi, limit 1Gi | Repo server. Grows with the size of the repositories it renders. |
| `k8s_argocd_server_resources` | 100m/128Mi, limit 512Mi | API server. |
| `k8s_argocd_small_component_resources` | 50m/64Mi, limit 256Mi | Redis, ApplicationSet, Dex and notifications. |
| `k8s_argocd_bootstrap_repo_url` | `""` | **Empty means no bootstrap Application.** Set to a git URL reachable from the cluster to apply the app-of-apps. |
| `k8s_argocd_bootstrap_repo_path` | `bootstrap` | Directory in that repository holding the child manifests. |
| `k8s_argocd_bootstrap_repo_revision` | `HEAD` | Branch, tag or commit to track. |
| `k8s_argocd_bootstrap_app_name` | `bootstrap` | Name of the app-of-apps `Application`. |
| `k8s_argocd_bootstrap_project` | `default` | `AppProject` it belongs to. The chart creates `default` with no restrictions. |
| `k8s_argocd_bootstrap_dest_namespace` | `argocd` | Where the bootstrap app's *own* manifests land. An app-of-apps produces `Application`s, which must live in the Argo CD namespace; children pick their own destinations. |
| `k8s_argocd_bootstrap_sync_automated` | `true` | Automated sync with `prune` and `selfHeal`, plus `CreateNamespace=true`. Set `false` to review the first sync by hand in the UI. |
| `k8s_argocd_bootstrap_manifest_path` | `/root/argocd/bootstrap-application.yaml` | Where the rendered `Application` is staged before `kubectl apply`. |
| `k8s_argocd_rollout_timeout` | `300` | Seconds allowed for `argocd-server` to roll out. |
| `k8s_argocd_cli_login_command` | derived | The `argocd login …` line printed at the end of the run. |

### Known gotchas

- **`helm upgrade --install` can't report idempotence by itself**, same as
  in `k8s_observability` — the release is gated on "absent or values changed".
  That gate is also why the bcrypt salt and `passwordMtime` are pinned: either
  one floating would make the values file differ on every render and defeat
  the gate.
- **CRDs are kept on uninstall** (`crds.keep: true`, the chart default).
  `helm uninstall argocd` leaves `applications.argoproj.io` and friends in
  place, which is what you want — deleting the `Application` CRD deletes every
  `Application` with it, and with the finalizer on `bootstrap` that would
  cascade into deleting every workload it manages.
- **Deleting `bootstrap` deletes everything it created.** That's the
  `resources-finalizer.argocd.argoproj.io` finalizer doing its job. To detach
  Argo CD from the workloads instead, remove the finalizer first, then delete.
- **A push doesn't deploy instantly.** With no webhook path into the lab, Argo
  CD notices a commit on its next poll — up to `k8s_argocd_reconciliation_timeout`
  (60s) later. `argocd app get bootstrap --refresh` or the UI's *Refresh*
  button forces it.
- **The repo server clones over the lab NAT.** `git` access to anything on
  the workstation itself has to go via `192.168.56.1`, the host's lab address —
  `localhost` from inside a pod is the pod. The same rule as `registry.lab`.
- **`resource.compareoptions: ignoreAggregatedRoles: true`** is set so that
  ClusterRoles with aggregation rules — whose `rules:` the API server fills in
  — don't show as permanently out of sync. Without it any app that ships one
  is `OutOfSync` forever and self-heal loops on it.
