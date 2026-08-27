# Runs the four playbooks that turn the fresh VMs into the lab, in the same
# order the Vagrantfile's ansible provisioner did. Re-run everything with
#   terraform apply -replace=terraform_data.ansible
# or a single playbook by hand:
#   ansible-playbook -i terraform/inventory.ini ansible/<playbook>.yml
resource "terraform_data" "ansible" {
  depends_on = [libvirt_domain.node, local_file.inventory]

  provisioner "local-exec" {
    # Repo root, so ansible/group_vars and roles resolve the same way they do
    # for manual runs.
    working_dir = "${path.module}/.."
    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
    command = <<-EOT
      set -e
      ./terraform/scripts/wait-for-ssh.sh terraform/inventory.ini
      ansible-playbook -i terraform/inventory.ini ansible/k8s-node-prereqs.yml
      ansible-playbook -i terraform/inventory.ini ansible/k8s-registry-trust.yml
      ansible-playbook -i terraform/inventory.ini ansible/k8s-cluster-bootstrap.yml
      ansible-playbook -i terraform/inventory.ini ansible/k8s-observability.yml
    EOT
  }
}
