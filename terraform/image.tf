# Base volume every node disk is a copy-on-write clone of. The provider
# downloads the image into the pool on first apply.
resource "libvirt_volume" "base" {
  name   = "ubuntu-24.04-server-cloudimg-amd64.qcow2"
  pool   = var.pool
  source = var.ubuntu_image_source
  format = "qcow2"
}
