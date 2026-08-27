output "node_ips" {
  description = "Lab-network address of each node."
  value       = { for name, node in var.nodes : name => node.ip }
}

output "ssh_command" {
  description = "How to reach the control-plane node."
  value       = "ssh -i terraform/artifacts/lab_ed25519 ${var.guest_user}@${var.nodes["k8s-control"].ip}"
}

output "inventory_path" {
  description = "Generated Ansible inventory, for manual playbook runs from the repo root."
  value       = "terraform/inventory.ini"
}
