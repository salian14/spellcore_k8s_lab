# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Three bare Ubuntu VMs, networked and named for building a k8s test cluster
# on top of (one intended control-plane node, two intended workers). No k8s
# software is installed here — bring your own bootstrap (kubeadm, k3s, etc.).

BOX            = "generic/ubuntu2204"
NETWORK_PREFIX = "192.168.56"

NODES = [
  { name: "k8s-control", ip: "#{NETWORK_PREFIX}.10", cpus: 4, memory: 8192 },
  { name: "k8s-worker1", ip: "#{NETWORK_PREFIX}.11", cpus: 4, memory: 8192 },
  { name: "k8s-worker2", ip: "#{NETWORK_PREFIX}.12", cpus: 4, memory: 8192 },
]

Vagrant.configure("2") do |config|
  config.vm.box = BOX
  config.vm.box_check_update = false

  # Keeps /etc/hosts on the host and every guest in sync with all nodes'
  # names/IPs, so they're resolvable by hostname from your workstation too.
  # Requires the vagrant-hostmanager plugin (installed by the ansible role).
  if Vagrant.has_plugin?("vagrant-hostmanager")
    # Deliberately false -- this does NOT disable hostmanager, it only unhooks
    # it from the per-machine `up` action. The plugin hooks UpdateAll after
    # Provision on *every* machine_action_up, and each firing loops over every
    # machine, so a parallel (libvirt) `vagrant up` had all three nodes
    # updating all three guests at once: 9 overlapping scp download/edit/upload
    # cycles against the same /etc/hosts, staged through a shared temp path
    # (.vagrant/tmp/hosts.<name> here, /tmp/hosts.<name> on the guest). That
    # raced and died with "closed stream" mid-transfer, leaving k8s-worker2
    # with no managed block and aborting the batch before Ansible ran.
    # The after-:up trigger below runs the same work single-threaded instead.
    config.hostmanager.enabled           = false
    config.hostmanager.manage_host       = true
    # Guests only learned their own name while this was false, so no node
    # could resolve any other node. hostmanager writes into a delimited block
    # in each guest's /etc/hosts and leaves the rest of the file alone --
    # including the registry.lab entry the containerd_registry_trust role
    # adds, which hostmanager can't provide (it maps names to machines
    # defined here, and that one points at the host).
    config.hostmanager.manage_guest      = true
    config.hostmanager.include_offline   = true

    # All nodes run the same Ubuntu box; skip hostmanager's guest OS
    # autodetection (which has been misfiring) by declaring it explicitly.
    config.hostmanager.guest_os_type = "linux"

    # This is what actually updates /etc/hosts now that the action hook above
    # is off. `type: :command` means it fires once, after the whole `vagrant
    # up` command finishes -- not once per machine, and not while other nodes
    # are still booting. The command walks the machines single-threaded and
    # then updates the host exactly once, so nothing writes concurrently and
    # the workstation's /etc/hosts is touched by a single `cp` (the one the
    # vagrant role's sudoers drop-in already grants passwordless).
    #
    # Vagrant 2.4.9 warns "The command 'up' was not found for this trigger."
    # on every invocation. That is a false positive in Vagrant itself --
    # vm_trigger.rb:226 tests a Symbol (:up) for membership in an Array of
    # Strings, which can never match. Trigger lookup normalizes both sides
    # (trigger.rb `nameify`), so it fires correctly. Don't "fix" the warning
    # by renaming the command; the value is symbolized either way.
    #
    # Running after provisioning is safe: nothing in the bootstrap resolves a
    # node by name. k8s_control_plane_init passes an IP to
    # --apiserver-advertise-address, the workers' join command carries that
    # same IP, and containerd_registry_trust writes the registry.lab entry
    # itself. Revisit this ordering if a playbook ever grows a dependency on
    # node-to-node name resolution.
    config.trigger.after :up, type: :command do |t|
      t.name = "hostmanager"
      t.run  = { inline: "vagrant hostmanager" }
    end
  end

  NODES.each_with_index do |node, index|
    config.vm.define node[:name] do |m|
      m.vm.hostname = node[:name]
      m.vm.network "private_network", ip: node[:ip]

      m.vm.provider "libvirt" do |lv|
        lv.cpus   = node[:cpus]
        lv.memory = node[:memory]
      end

      m.vm.provider "virtualbox" do |vb|
        vb.name   = node[:name]
        vb.cpus   = node[:cpus]
        vb.memory = node[:memory]
      end

      # Attach the Ansible provisioner only to the last-defined node. Vagrant
      # then defers invoking ansible-playbook until every machine touched by
      # this `vagrant up`/`vagrant provision` run is up, builds one combined
      # inventory (see ansible.groups below), and runs the playbook exactly
      # once with --limit=all — instead of once per node as each one boots.
      # Practical effect: `vagrant up` with no args provisions all three
      # nodes; `vagrant up k8s-control` or `vagrant up k8s-worker1` alone
      # does NOT trigger provisioning (see README.md for the supported
      # workflow around this).
      if index == NODES.length - 1
        m.vm.provision "ansible" do |ansible|
          ansible.compatibility_mode = "2.0"
          ansible.playbook = "ansible/k8s-node-prereqs.yml"
          ansible.limit = "all"

          # k8s_node_prereqs itself applies identically to every node
          # (hosts: all), but these groups set up the inventory shape the
          # k8s-cluster-bootstrap.yml provisioner below needs to target
          # control-plane vs worker nodes differently.
          ansible.groups = {
            "k8s_control" => ["k8s-control"],
            "k8s_workers" => ["k8s-worker1", "k8s-worker2"],
          }
        end

        # Teach containerd to resolve and pull from registry.lab:5000 on the
        # host (see lab-network.md). Runs before the cluster bootstrap so the
        # nodes can pull local images from the moment they're Ready. Guests
        # only -- whatever serves that endpoint on 192.168.56.1 is run
        # separately, and this warns rather than fails when it isn't up.
        m.vm.provision "ansible" do |ansible|
          ansible.compatibility_mode = "2.0"
          ansible.playbook = "ansible/k8s-registry-trust.yml"
          ansible.limit = "all"

          ansible.groups = {
            "k8s_control" => ["k8s-control"],
            "k8s_workers" => ["k8s-worker1", "k8s-worker2"],
          }
        end

        # kubeadm init on k8s-control, Calico CNI, kubeadm join on the workers,
        # metrics-server, then a workstation kubeconfig context -- see
        # ansible/README.md for the five roles involved
        # (k8s_control_plane_init, k8s_kubeconfig_cni, k8s_cluster_join,
        # k8s_metrics_server, k8s_host_kubeconfig). Runs after
        # k8s_node_prereqs above, same deferred-until-all-nodes-up and
        # --limit=all behavior.
        m.vm.provision "ansible" do |ansible|
          ansible.compatibility_mode = "2.0"
          ansible.playbook = "ansible/k8s-cluster-bootstrap.yml"
          ansible.limit = "all"

          ansible.groups = {
            "k8s_control" => ["k8s-control"],
            "k8s_workers" => ["k8s-worker1", "k8s-worker2"],
          }
        end

        # Grafana + Tempo + Loki + Prometheus + MinIO + an OTLP collector
        # gateway, in an `observability` namespace. Grafana is in the host
        # browser at http://192.168.56.10:30300 and Prometheus at
        # http://192.168.56.10:30090 -- see ansible/README.md for the four roles
        # involved (k8s_node_storage_expand, helm_cli,
        # k8s_local_path_storage, k8s_observability).
        #
        # Runs last: it needs a working cluster, and it grows each node's root
        # logical volume before any chart claims a persistent volume.
        m.vm.provision "ansible" do |ansible|
          ansible.compatibility_mode = "2.0"
          ansible.playbook = "ansible/k8s-observability.yml"
          ansible.limit = "all"

          ansible.groups = {
            "k8s_control" => ["k8s-control"],
            "k8s_workers" => ["k8s-worker1", "k8s-worker2"],
          }
        end
      end
    end
  end
end
