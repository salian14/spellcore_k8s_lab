# Spellcore Lab Network

Every address, hostname and subnet in the lab — and which one to use for each
job. Two of these networks look interchangeable and are not.

Verified against the live host and cluster, 16 Aug 2026 · k8s v1.35.2 ·
containerd 2.3.3 · Calico VXLAN.

## Use these

| | |
|---|---|
| Registry endpoint | `registry.lab:5000` → `192.168.56.1`, plain HTTP, no auth |
| Host, on the lab net | `192.168.56.1` (virbr2) — bind lab services here |
| Control plane | `192.168.56.10` (`k8s-control`) |
| Workers | `192.168.56.11`, `192.168.56.12` |

## Topology

```
                        spellcore  (Ubuntu 24.04)
   ┌──────────────────────────────────────────────────────────────────┐
   │   wlo1        192.168.1.201/24   ── home LAN, other devices      │
   │   virbr0      192.168.122.1/24   ── libvirt "default"  (DOWN)    │
   │   virbr1      192.168.121.1/24   ── "vagrant-libvirt"  (mgmt)    │
   │   virbr2      192.168.56.1/24    ── "spellcore_k8s_lab0" (lab)   │
   │                      │              └── zot :5000 binds here     │
   └──────────────────────┼───────────────────────────────────────────┘
        ┌─────────────────┼─────────────────┐
   ┌────┴──────┐    ┌─────┴─────┐    ┌──────┴────┐
   │k8s-control│    │k8s-worker1│    │k8s-worker2│
   │eth1 .56.10│    │eth1 .56.11│    │eth1 .56.12│  ← static, use these
   │eth0 .121.x│    │eth0 .121.x│    │eth0 .121.x│  ← DHCP, changes
   └───────────┘    └───────────┘    └───────────┘
        default route via 192.168.121.1 (eth0)
        pod traffic + registry pulls via eth1
```

## Networks

| Interface | Host address | libvirt network | State | What it is |
|---|---|---|---|---|
| `virbr2` | `192.168.56.1/24` | `spellcore_k8s_lab0` | up | The lab network. `private_network` in the Vagrantfile, static. **Use this one.** |
| `virbr1` | `192.168.121.1/24` | `vagrant-libvirt` | up | Vagrant's management network, created automatically. DHCP, churns. |
| `virbr0` | `192.168.122.1/24` | `default` | down | libvirt's stock network. Activates when you start a non-Vagrant VM. |
| `wlo1` | `192.168.1.201/24` | — | up | The house WiFi. Never bind a lab service to `0.0.0.0`. |
| `enp5s0` | — | — | down | Wired ethernet, unplugged. |

> **Watch:** `spellcore_k8s_lab0` has autostart **disabled**, so `virbr2` and
> `192.168.56.1` don't exist after a reboot until you bring the lab up.
> Fix with `virsh -c qemu:///system net-autostart spellcore_k8s_lab0` — the
> `zot_registry` role does this for you.

## Nodes

All amd64 / Ubuntu 22.04 / containerd 2.3.3.

| Hostname | eth1 — lab | eth0 — mgmt | k8s InternalIP | Role |
|---|---|---|---|---|
| `k8s-control` | `192.168.56.10` (static) | `192.168.121.46` (dhcp) | `192.168.121.46` | control-plane |
| `k8s-worker1` | `192.168.56.11` (static) | `192.168.121.96` (dhcp) | `192.168.121.96` | worker |
| `k8s-worker2` | `192.168.56.12` (static) | `192.168.121.72` (dhcp) | `192.168.121.72` | worker |

The `eth0` column is a snapshot, not a fact — those leases had under an hour
left when this was written.

> **Surprising but true:** Kubernetes reports each node's `InternalIP` as its
> **DHCP management address**, not its static lab address. `kubeadm-flags.env`
> sets no `--node-ip`, so kubelet picks the interface holding the default route
> — `eth0`. Anything reading `InternalIP` gets an address that can change on
> lease renewal. Meanwhile Calico independently chose `eth1` for pod routing,
> so pod traffic and registry pulls cross the lab network while the control
> plane addresses itself over the management one.

## Which address for which job

| Job | Use | Why |
|---|---|---|
| Bind a service for the cluster | `192.168.56.1` | Reachable from all nodes, invisible to the home LAN |
| Ansible inventory / SSH targets | `192.168.56.10–.12` | Static, declared in the Vagrantfile |
| Image tags | `registry.lab:5000` | Resolves to the same address on host and nodes |
| Registry from the host | `registry.lab:5000` | `localhost:5000` will **not** work — see below |
| Anything at all | ~~`192.168.121.x`~~ | **Don't.** DHCP; it will change under you |
| Deliberate LAN exposure | `192.168.1.201` | Only when you mean every device in the house |

**Why `localhost:5000` fails.** The registry binds `192.168.56.1` only, so
nothing listens on `127.0.0.1`. The host still reaches it —
`ip route get 192.168.56.1` returns `local … dev lo`, so traffic to the host's
own bridge address goes over loopback. Use the name, not localhost: one address
works from host and nodes, and the tag baked into an image stays valid in both.

## Two things to fix

Both found while verifying this document. Neither is caused by the registry
work; both will bite you independently.

### Stale hosts entry, host side

`k8s-control` resolves to a dead address first:

```
$ getent hosts k8s-control
192.168.121.147 k8s-control   ← stale DHCP lease, unreachable (verified refused)
192.168.56.10   k8s-control   ← correct, but second in line
```

The current management address is `192.168.121.46`; `.147` is a lease from a
previous boot that `vagrant-hostmanager` left behind. Delete the
`192.168.121.147` line from `/etc/hosts`.

### Nodes cannot resolve anything

A node's `/etc/hosts` contains only itself — `127.0.2.1 k8s-control k8s-control`,
duplicated, pointing at loopback. No entries for the other nodes, none for the
host.

This is by configuration: `spellcore_k8s_lab` runs hostmanager with
`manage_host = true` but **`manage_guest = false`**, so the host learns the
guests' names and the guests learn nothing. Any guest-side name you need —
including `registry.lab` — you must write yourself. The
`containerd_registry_trust` role does that for the registry.

### Cosmetic

`hostnamectl` and `hostname -f` both say `spellcore`, but `/etc/hosts` still
maps `127.0.1.1` to `mimir` from before the rename. Harmless, but it can make
`sudo` pause on name lookups.

## Name resolution, in full

| From | Name | Resolves? | Via |
|---|---|---|---|
| host | node names | yes (stale dupe) | hostmanager, `manage_host = true` |
| host | `registry.lab` | yes | `zot_registry` role writes `/etc/hosts` |
| node | `registry.lab` | yes | `containerd_registry_trust` role |
| node | other node names | **no** | nothing — `manage_guest = false` |
| node | `spellcore` | **no** | use `192.168.56.1` or `registry.lab` |

libvirt runs a dnsmasq per network, bound per-interface on `192.168.56.1:53`
and `192.168.121.1:53`. It resolves DHCP-registered guest names on the
management network — don't rely on it for the static lab network.

## Cluster ranges

| Range | CIDR | Notes |
|---|---|---|
| Pod network | `10.244.0.0/16` | `--cluster-cidr` |
| Services | `10.96.0.0/12` | `--service-cluster-ip-range` |
| Per-node podCIDR | `10.244.0.0/24`, `.1.0/24`, `.2.0/24` | assigned by kubeadm |
| Calico IPAM blocks | `/26` blocks | e.g. `10.244.175.0/26`, `10.244.126.0/26` |

> Calico ignores the per-node `podCIDR` kubeadm assigns and carves its own
> `/26` blocks out of `10.244.0.0/16`. The `/24` in `kubectl get node -o yaml`
> does **not** describe where pods on that node live. Read `ip route` on the
> node instead — its next hops point at `192.168.56.x`.

## Ports on the lab bridge

| Port | Service | Reachable from |
|---|---|---|
| 5000 | zot registry (HTTP) | `lo` + `virbr2` only — nftables drops it elsewhere |
| 53 | libvirt dnsmasq | lab network |
| 67 | libvirt DHCP | lab network |

For contrast, two services on this host *are* open to the house WiFi: `sshd` on
`0.0.0.0:22` and ollama on `*:11434`. Both predate this work.

## Access

```bash
cd ~/Documents/repos/spellcore_k8s_lab
vagrant ssh k8s-control
vagrant global-status
```

Per-machine keys live at stable paths — regenerated by
`vagrant destroy && vagrant up`, but the paths never change:

```
~/Documents/repos/spellcore_k8s_lab/.vagrant/machines/<node>/libvirt/private_key
```

## Verify it yourself

```bash
ip -brief addr show virbr2
ip route get 192.168.56.1          # expect: local ... dev lo

curl -s http://registry.lab:5000/v2/_catalog

# From a node. "Connection refused" is a PASS when nothing is listening yet —
# it proves routing and firewall are clear. A timeout is a fail.
vagrant ssh k8s-control -c 'timeout 5 bash -c "echo > /dev/tcp/192.168.56.1/5000"'

vagrant ssh k8s-control -c 'sudo containerd config dump | grep config_path'
virsh -c qemu:///system net-list --all
```

---

Companion: [Pushing to registry.lab](build-and-push.md).

Source of truth for addresses is `ansible/group_vars/all.yml` here, and the
`NODES` array in the `spellcore_k8s_lab` Vagrantfile. If they disagree, the
Vagrantfile wins for node addresses.
