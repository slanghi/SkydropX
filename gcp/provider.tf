terraform {
  required_version = ">= 0.13"

  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.7.0"
    }
  }
}


provider "google" {
  version = "~> 3.42.0"
}


# Get your cluster-info
data "google_container_cluster" "my_cluster" {
  name     = "${var.cluster_name}-${var.env_name}"
  location = "us-central1-a"
  project = var.project_id
}

# Same parameters as kubernetes provider
provider "kubectl" {
  load_config_file = true
  config_path = "~/.kube/config"
}


data "kubectl_filename_list" "manifests" {
  pattern = "./*.yaml"
}

resource "kubectl_manifest" "test" {
  count     = length(data.kubectl_filename_list.manifests.matches)
  yaml_body = file(element(data.kubectl_filename_list.manifests.matches, count.index))
}