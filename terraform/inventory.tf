# The Ansible inventory Vagrant used to generate. Written next to the
# configuration (gitignored) so manual runs are just
# `ansible-playbook -i terraform/inventory.ini ...` from the repo root.
resource "local_file" "inventory" {
  filename = "${path.module}/inventory.ini"
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    nodes    = var.nodes
    user     = var.guest_user
    key_path = abspath("${path.module}/artifacts/lab_ed25519")
  })
}
