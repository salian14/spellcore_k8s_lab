# The lab NAT network. Replaces the vagrant-libvirt-created spellcore_k8s_lab0
# (same subnet, so lab_host_ip and registry.lab semantics carry over) -- the old
# network must be undefined before the first apply, see README.md "Migrating
# from Vagrant". autostart means it survives host reboots, which the old
# network didn't.
#
# DHCP is off because every node gets its static IP from cloud-init's netplan
# config; DNS is off because node names live in /etc/hosts (the k8s_node_hosts
# role on guests, a documented manual entry on the host).
resource "libvirt_network" "lab" {
  name      = var.network_name
  mode      = "nat"
  addresses = [var.network_cidr]
  autostart = true

  dhcp {
    enabled = false
  }

  dns {
    enabled = false
  }
}
