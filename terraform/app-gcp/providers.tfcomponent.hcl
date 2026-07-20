# ---------------------------------------------------------------------------
# APP-GCP stack: provider requirements + configuration.
#
# GCP (google/google-beta) is fully KEYLESS: HCP Terraform Dynamic Provider
# Credentials mint a short-lived OIDC JWT per run (identity_token block in
# app.tfdeploy.hcl) which the provider exchanges through Workload Identity
# Federation to impersonate a least-privilege SA. No SA keys or JSON exist
# anywhere in this repo. This stack touches NO third-party edge: the
# Cloudflare provider (and its API token) lives only in the cloudflare stack.
# ---------------------------------------------------------------------------

required_providers {
  google = {
    source = "hashicorp/google"
    # external_credentials (WIF for Stacks) landed in google 6.30; pinned to a
    # recent 6.x in .terraform.lock.hcl. Kept on 6.x to avoid a 7.x migration.
    version = ">= 6.45.0, < 7.0.0"
  }
  # Cloud Deploy custom-target/beta surfaces used by the clouddeploy component
  # need google-beta.
  google-beta = {
    source  = "hashicorp/google-beta"
    version = ">= 6.45.0, < 7.0.0"
  }
  random = {
    source  = "hashicorp/random"
    version = "~> 3.5"
  }
  # Cluster bootstrap (mattermost-operator + ingress-nginx) as Terraform-managed
  # Helm releases; configured below from the gke_auth component's outputs.
  helm = {
    source  = "hashicorp/helm"
    version = "~> 3.0"
  }
  # Namespaces + credential Secrets created directly in the cluster, so the DB /
  # filestore secrets never pass through Cloud Deploy; configured from gke_auth.
  # Pinned below 2.38.0: that release introduced Terraform managed resource
  # identity, and updating an already-created kubernetes_secret triggers a
  # provider "Unexpected Identity Change" abort (the stored identity is null,
  # the provider returns a populated one). 2.37.x predates the identity feature
  # entirely, so the DB-connection-string rotation on mattermost-db applies
  # cleanly. Bump deliberately once the provider ships a fix (>= 2.38.x).
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

# --- Kubernetes API: keyless too, via the gke_auth component ------------------
# Endpoint + CA come from a data lookup of the platform-published cluster ID;
# the bearer token is the short-lived access token google_client_config mints
# for the impersonated apply SA (roles/container.admin => cluster-admin). No
# kubeconfig, no gke-gcloud-auth-plugin, no static credentials. NOTE: this
# relies on the cluster's public-but-IAM-guarded endpoint (empty
# master_authorized_networks, see the platform stack); if that list is ever
# locked down, HCP agent egress must be included.
provider "helm" "this" {
  config {
    kubernetes = {
      host                   = component.gke_auth.host
      cluster_ca_certificate = component.gke_auth.cluster_ca_certificate
      token                  = component.gke_auth.access_token
    }
  }
}

# Same keyless GKE auth as the helm provider. Used by the cluster_secrets
# component to create the tenant namespaces and the credential Secrets
# (dev-postgres, mattermost-db, mattermost-filestore) straight in etcd -- the
# values come from Secret Manager / a generated password via Terraform state,
# never through a Cloud Deploy deploy parameter.
provider "kubernetes" "this" {
  config {
    host                   = component.gke_auth.host
    cluster_ca_certificate = component.gke_auth.cluster_ca_certificate
    token                  = component.gke_auth.access_token
  }
}
