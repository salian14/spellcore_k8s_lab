# Per-project SSH keypair, standing in for Vagrant's per-machine keys. The
# private key lands in artifacts/ (gitignored) and in local state -- acceptable
# for a local lab where state never leaves this machine.
resource "tls_private_key" "lab" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.lab.private_key_openssh
  filename        = "${path.module}/artifacts/lab_ed25519"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content         = tls_private_key.lab.public_key_openssh
  filename        = "${path.module}/artifacts/lab_ed25519.pub"
  file_permission = "0644"
}

resource "libvirt_volume" "root" {
  for_each       = var.nodes
  name           = "${each.key}.qcow2"
  pool           = var.pool
  base_volume_id = libvirt_volume.base.id
  size           = var.disk_size
  format         = "qcow2"
}

resource "libvirt_cloudinit_disk" "seed" {
  for_each = var.nodes
  name     = "${each.key}-cloudinit.iso"
  pool     = var.pool

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    hostname = each.key
    user     = var.guest_user
    ssh_keys = concat([trimspace(tls_private_key.lab.public_key_openssh)], var.extra_ssh_public_keys)
  })

  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    mac = each.value.mac
    ip  = each.value.ip
    gw  = var.host_ip
  })
}

resource "libvirt_domain" "node" {
  for_each  = var.nodes
  name      = each.key
  vcpu      = each.value.cpus
  memory    = each.value.memory
  autostart = false

  cloudinit = libvirt_cloudinit_disk.seed[each.key].id

  cpu {
    mode = "host-passthrough"
  }

  # Single NIC, static IP from cloud-init. Because this is also the default
  # route, kubelet auto-detects the lab address as the node's InternalIP --
  # which metrics-server and the kubeadm advertise address depend on.
  network_interface {
    network_id = libvirt_network.lab.id
    mac        = each.value.mac
  }

  disk {
    volume_id = libvirt_volume.root[each.key].id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }
}
