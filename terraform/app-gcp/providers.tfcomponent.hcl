# APP-GCP providers. GCP is keyless (HCP Dynamic Provider Credentials -> WIF);
# no SA keys anywhere. Kubernetes/Helm auth comes from the gke_auth component.

required_providers {
  google = {
    source  = "hashicorp/google"
    version = ">= 6.45.0, < 7.0.0"
  }
  google-beta = {
    source  = "hashicorp/google-beta"
    version = ">= 6.45.0, < 7.0.0"
  }
  random = {
    source  = "hashicorp/random"
    version = "~> 3.5"
  }
  helm = {
    source  = "hashicorp/helm"
    version = "~> 3.0"
  }
  # Pinned below 2.38.0: that release's managed resource identity aborts
  # updates of an existing kubernetes_secret ("Unexpected Identity Change").
  # Bump once the provider ships a fix.
  kubernetes = {
    source  = "hashicorp/kubernetes"
    version = "~> 2.37.0"
  }
}

# --- GCP: keyless WIF (impersonate the least-privilege apply SA) -------------
provider "google" "this" {
  config {
    project = var.project_id
    region  = var.region

    external_credentials {
      audience              = var.audience
      service_account_email = var.service_account_email
      identity_token        = var.identity_token
    }
  }
}

provider "google-beta" "this" {
  config {
    project = var.project_id
    region  = var.region

    external_credentials {
      audience              = var.audience
      service_account_email = var.service_account_email
      identity_token        = var.identity_token
    }
  }
}

provider "random" "this" {}

# Keyless GKE auth via gke_auth (endpoint/CA from the cluster ID, short-lived
# token for the impersonated apply SA). Relies on the cluster's IAM-guarded
# public endpoint (empty master_authorized_networks); include HCP agent egress
# if that list is ever locked down.
provider "helm" "this" {
  config {
    kubernetes = {
      host                   = component.gke_auth.host
      cluster_ca_certificate = component.gke_auth.cluster_ca_certificate
      token                  = component.gke_auth.access_token
    }
  }
}

provider "kubernetes" "this" {
  config {
    host                   = component.gke_auth.host
    cluster_ca_certificate = component.gke_auth.cluster_ca_certificate
    token                  = component.gke_auth.access_token
  }
}
