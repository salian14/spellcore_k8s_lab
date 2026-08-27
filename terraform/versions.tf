terraform {
  required_version = ">= 1.5"

  required_providers {
    libvirt = {
      # Pinned to the 0.8 series: 0.9.x is a ground-up schema rewrite
      # (libvirt-XML-shaped attributes) this configuration does not target.
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
