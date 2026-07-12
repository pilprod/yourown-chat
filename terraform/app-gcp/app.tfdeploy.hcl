# ---------------------------------------------------------------------------
# APP-GCP deployments. ONE deployment (`eu`) provisions the GCP delivery layer
# in the single GCP project `yourown-chat`, europe-west3: application secrets,
# the Cloud Deploy pipeline, the image-build CI and the tag-triggered release
# cutting.
#
# LINKED STACK: platform-gcp -> app-gcp. The stateful foundation's values
# (cluster ID, registry coordinates, CMEK key, Workload Identity members) are
# the LAST APPLIED publish_output of the platform-gcp stack -- HCP triggers a
# plan here automatically whenever it changes one, and this stack can never
# run ahead of a platform that hasn't settled. The Cloudflare edge (and its
# origin-TLS secrets) is the sibling cloudflare stack; the two do not link.
#
# AUTH: keyless HCP Terraform Dynamic Provider Credentials -> Workload Identity
# Federation (identity_token block; no static keys, no TFC_GCP_*). No
# third-party secrets here -- the Cloudflare token lives in the cloudflare
# stack. Bootstrap: README.md.
# ---------------------------------------------------------------------------

locals {
  # --- Keyless GCP auth wiring (project `yourown-chat`) ----------------------
  # STS token-exchange audience = full WIF provider resource name (leading //).
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  # Least-privilege SA impersonated after the exchange (never Owner/Editor).
  gcp_apply_sa = "terraform-apply@yourown-chat.iam.gserviceaccount.com"

  gcp_project = "yourown-chat"
  gcp_region  = "europe-west3" # Frankfurt, Germany
}

# HCP mints this OIDC JWT once per run. Its `aud` claim must match the WIF
# provider's allowed-audiences, which is the full https://iam.googleapis.com/...
# provider URL (see README.md, gcloud ... --allowed-audiences=...).
identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

# --- Linked platform-gcp stack --------------------------------------------------
# Source format: app.terraform.io/<organization>/<hcp project>/<stack name> --
# it must match the upstream stack's name in HCP Terraform exactly.
upstream_input "platform" {
  type   = "stack"
  source = "app.terraform.io/papou-work/yourown-chat/platform-gcp"
}

# --- eu: the GCP delivery layer in one deployment -------------------------------
deployment "eu" {
  inputs = {
    # --- Keyless GCP auth: OIDC JWT exchanged via WIF to impersonate apply SA --
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id  = local.gcp_project
    environment = "prod"
    region      = local.gcp_region

    # --- platform-gcp published values (linked stack, last-applied) -----------
    gke_cluster_id                  = upstream_input.platform.gke_cluster_id
    gcs_bucket_name                 = upstream_input.platform.gcs_bucket_name
    workload_identity_emails        = upstream_input.platform.workload_identity_emails
    artifact_registry_location      = upstream_input.platform.artifact_registry_location
    artifact_registry_repository_id = upstream_input.platform.artifact_registry_repository_id
    cmek_key_id                     = upstream_input.platform.cmek_key_id
    workload_identity_members       = upstream_input.platform.workload_identity_members
    ingress_ip_address              = upstream_input.platform.ingress_ip_address

    # --- Cluster bootstrap (Terraform-managed Helm releases) ------------------
    # mattermost-operator + ingress-nginx install automatically once the
    # platform cluster exists (docs/DEPLOY.md step 2 is the manual fallback).
    # Chart pins -- bump deliberately, never track "latest" implicitly:
    #   helm search repo mattermost/mattermost-operator --versions | head
    #   helm search repo ingress-nginx/ingress-nginx --versions | head
    mattermost_operator_chart_version = "1.0.5"
    ingress_nginx_chart_version       = "4.15.1"

    # --- Image-build CI ------------------------------------------------------
    # The Cloud Build 2nd-gen GitHub connection is authorized once out-of-band in
    # the console (OAuth) and named here; both the image and deploy repos are
    # linked to it (see README.md).
    github_connection_name = "pilprod-github"
    github_remote_uri      = "https://github.com/pilprod/mattermost.git"
    image_name             = "mattermost"
    # One source repo, ONE unified registry, ONE image built on a single tag
    # pattern. The same artifact is promoted dev -> prod (Cloud Deploy):
    #   v9.11.3-patched  -> docker/mattermost:v9.11.3-patched
    builds = {
      mattermost = { tag_regex = "^v.*-patched$" }
    }

    # --- Automated release cutting ------------------------------------------
    # THIS repo (holds helm/) is linked to the SAME shared connection: a semver
    # tag (MAJOR.MINOR.PATCH) cuts a Cloud Deploy release automatically — no
    # manual `gcloud deploy releases create`. The connection must cover this repo.
    github_deploy_remote_uri = "https://github.com/pilprod/yourown-chat.git"
    release_tag_regex        = "^[0-9]+\\.[0-9]+\\.[0-9]+$"

    extra_labels = { cost-center = "platform" }
  }
}
