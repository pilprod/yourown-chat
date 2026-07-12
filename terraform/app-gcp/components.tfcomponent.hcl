# ---------------------------------------------------------------------------
# APP-GCP stack: the fast-moving GCP delivery layer. Everything here is cheap
# to recreate and changes often: application secrets, the Cloud Deploy
# pipeline, the image-build CI and the tag-triggered release cutting.
#
# This stack is LINKED to two upstreams (see app.tfdeploy.hcl):
#   - platform-gcp: the stateful foundation (cluster ID, CMEK, registry
#     coordinates, Workload Identity members);
#   - cloudflare: the public edge, publishing the Origin CA cert/key this
#     stack pours into the mattermost-origin-tls-* secrets.
# Values arrive as last-APPLIED upstream outputs, so both upstreams always
# settle first and a mistake here can never touch their state (separate
# state, separate blast radius).
#
# Graph (this stack; <upstream> = linked values passed in as plain vars):
#   clouddeploy (targets on <gke_cluster_id>) ── deploy_release
#   mattermost_image  -> pushes to <artifact_registry_*>
#   secrets (origin TLS material = <cloudflare origin cert/key>,
#            accessors = <workload_identity_members>)
# ---------------------------------------------------------------------------

locals {
  common_labels = merge({
    environment = var.environment
    managed-by  = "terraform"
    stack       = "yourown-chat-app-gcp"
  }, var.extra_labels)
}

# --- Continuous delivery ----------------------------------------------------
# Cloud Deploy governs promotion of the Kubernetes workloads (helm/) as a
# managed dev -> prod pipeline: two targets on the ONE platform cluster, each
# rendering a Skaffold profile from helm/skaffold.yaml. The Mattermost image is
# built once by the mattermost_image component (below) and promoted by tag.
component "clouddeploy" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id     = var.project_id
    region         = var.region
    gke_cluster_id = var.gke_cluster_id

    stages = [
      { name = "dev", profiles = ["dev"], require_approval = false, verify = true },
      { name = "prod", profiles = ["prod"], require_approval = true, verify = false },
    ]

    labels = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

# --- Additional application secrets (all credentials live in Secret Manager) -
component "secrets" {
  source = "./modules/secrets"

  inputs = {
    project_id        = var.project_id
    replica_locations = [var.region]
    labels            = local.common_labels

    # CMEK: the platform's shared key encrypts every secret replica (null when
    # the platform runs with cmek_enabled = false).
    kms_key_name = var.cmek_key_id

    secrets = merge(
      {
        # In-cluster dev Postgres password (generated, read by the dev tenant).
        "dev-postgres-password" = {
          generate  = true
          accessors = [var.workload_identity_members.dev]
        }
        # matterbridge bot tokens / bridge config — created empty, populated
        # out-of-band (never in git), read by the matterbridge workload.
        "matterbridge-tokens" = {
          accessors = [var.workload_identity_members.matterbridge]
        }
      },
      # Cloudflare origin-protection material for the public ingress (prod only).
      # The origin TLS cert/key arrive from the LINKED cloudflare stack (Origin
      # CA cert, upstream_input.cloudflare.*), so ingress-nginx can serve Full
      # (Strict) TLS with zero manual steps. When the cloudflare stack runs with
      # manage_origin_cert = false the values are null and the module creates
      # empty containers to be filled out-of-band. The AOP CA stays an empty
      # container (Cloudflare-supplied, not issued here).
      var.public_ingress_enabled ? {
        "mattermost-origin-tls-cert" = {
          value     = var.origin_certificate_pem
          accessors = [var.workload_identity_members.mattermost]
        }
        "mattermost-origin-tls-key" = {
          value     = var.origin_private_key_pem
          accessors = [var.workload_identity_members.mattermost]
        }
        "cloudflare-origin-pull-ca" = {
          # Explicit null (empty container) so all three entries share one object
          # type -> the conditional's branches unify as map(object) against {}.
          value     = null
          accessors = [var.workload_identity_members.mattermost]
        }
      } : {}
    )
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# --- Mattermost image CI (Cloud Build 2nd-gen) ------------------------------
# Links the source repo (pilprod/mattermost) to the shared, out-of-band GitHub
# connection (console OAuth), plus one least-privilege build SA (repo-scoped
# writer on the platform registry) and a tag-triggered build that pushes ONE
# image on a single tag pattern (^v.*-patched$), promoted dev -> prod by Cloud
# Deploy.
component "mattermost_image" {
  source = "./modules/cloudbuild-image"

  inputs = {
    project_id = var.project_id
    region     = var.region

    apply_service_account_email = var.service_account_email

    # Existing, out-of-band Cloud Build connection (console OAuth) shared by the
    # image and deploy repos; Terraform only links repositories/triggers to it.
    connection_name   = var.github_connection_name
    github_remote_uri = var.github_remote_uri

    # Push every build to the ONE unified repository the platform stack owns.
    artifact_registry_location      = var.artifact_registry_location
    artifact_registry_repository_id = var.artifact_registry_repository_id

    image_name = var.image_name
    builds     = var.builds
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

# --- Automated release cutting (Cloud Build 2nd-gen on git tags) -------------
# Makes deployment hands-off: links the DEPLOY repo (this one, holds helm/) to the
# shared out-of-band GitHub connection, plus a least-privilege releaser SA and a
# tag trigger. On a semver tag (release_tag_regex, i.e. *.*.*) it runs `gcloud
# deploy releases create` against the clouddeploy pipeline, so a tag — not a human
# — cuts the release. The releaser can create releases on that pipeline only and
# actAs the execution SA; it never touches the image build.
component "deploy_release" {
  source = "./modules/deploy-release"

  inputs = {
    project_id = var.project_id
    region     = var.region

    apply_service_account_email = var.service_account_email

    # Same shared, out-of-band Cloud Build connection as the image CI (both repos
    # live under the pilprod account it authorizes).
    connection_name   = var.github_connection_name
    github_remote_uri = var.github_deploy_remote_uri

    # Cut releases against the pipeline the clouddeploy component owns.
    delivery_pipeline_name          = component.clouddeploy.delivery_pipeline_name
    execution_service_account_email = component.clouddeploy.execution_service_account_email

    release_tag_regex = var.release_tag_regex

    # CMEK the private source-staging bucket with the platform's shared key
    # (null when the platform runs cmek_enabled = false), mirroring the other
    # data buckets.
    source_bucket_kms_key_name = var.cmek_key_id

    labels = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}
