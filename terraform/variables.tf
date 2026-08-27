variable "libvirt_uri" {
  description = "Connection URI for libvirtd. The lab needs the system daemon, not qemu:///session."
  type        = string
  default     = "qemu:///system"
}

variable "pool" {
  description = "Existing, running libvirt storage pool that receives the base image, node disks, and cloud-init ISOs. The lab_workstation ansible role defines and starts it."
  type        = string
  default     = "default"
}

variable "guest_user" {
  description = "Login user cloud-init creates on every node. The generated inventory sets ansible_user to this, and k8s_kubeconfig_cni stages a kubeconfig for it."
  type        = string
  default     = "spellcore"
}

variable "extra_ssh_public_keys" {
  description = "Additional public keys appended to the guest user's authorized_keys, e.g. your personal key so plain `ssh` works without -i."
  type        = list(string)
  default     = []
}

variable "network_name" {
  description = "Name of the Terraform-owned NAT network (the lab net on virbrN)."
  type        = string
  default     = "spellcore_lab"
}

# The host side of the NAT bridge gets .1 -- that address is what
# ansible/group_vars/all.yml calls lab_host_ip and what registry.lab points at,
# so changing this subnet means changing those too.
variable "network_cidr" {
  description = "Lab network subnet. The host bridge takes the first address."
  type        = string
  default     = "192.168.56.0/24"
}

variable "host_ip" {
  description = "The host's address on the lab bridge; the guests' default gateway. Must be the first address of network_cidr and match lab_host_ip in ansible/group_vars/all.yml."
  type        = string
  default     = "192.168.56.1"
}

variable "ubuntu_image_source" {
  description = "Ubuntu 24.04 (noble) cloud image the node disks are cloned from. First apply downloads ~600 MB; point this at a file:// path of a pre-fetched copy to make destroy/apply cycles fast."
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "disk_size" {
  description = "Virtual disk size per node in bytes (default 128 GiB, matching the old Vagrant box). cloud-init grows the root filesystem to fill it on first boot."
  type        = number
  default     = 137438953472
}

# One entry per node. The IPs are load-bearing well beyond this directory:
#   - k8s-control's IP is the kubeadm advertise address
#     (ansible/roles/k8s_control_plane_init/defaults/main.yml) and the host in
#     the Grafana/Prometheus URLs (ansible/roles/k8s_observability/defaults)
#   - all three appear in the generated inventory and the nodes' /etc/hosts
# Change an IP here and those defaults must move with it.
variable "nodes" {
  description = "The lab VMs: static lab-network IP, fixed MAC (keeps netplan matching and any DHCP-less ARP sane across rebuilds), and sizing."
  type = map(object({
    ip     = string
    mac    = string
    cpus   = number
    memory = number
  }))
  default = {
    "k8s-control" = { ip = "192.168.56.10", mac = "52:54:00:38:56:0a", cpus = 4, memory = 8192 }
    "k8s-worker1" = { ip = "192.168.56.11", mac = "52:54:00:38:56:0b", cpus = 4, memory = 8192 }
    "k8s-worker2" = { ip = "192.168.56.12", mac = "52:54:00:38:56:0c", cpus = 4, memory = 8192 }
  }
}
