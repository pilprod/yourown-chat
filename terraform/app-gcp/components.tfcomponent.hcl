# ---------------------------------------------------------------------------
# APP-GCP stack: the fast-moving GCP delivery layer. Everything here is cheap
# to recreate and changes often: application secrets, the Cloud Deploy
# pipeline, the image-build CI and the tag-triggered release cutting.
#
# This stack is LINKED to platform-gcp (see app.tfdeploy.hcl): the stateful
# foundation (cluster ID, CMEK, registry coordinates, Workload Identity
# members) arrives as last-APPLIED upstream outputs, so the platform always
# settles first and a mistake here can never touch its state (separate state,
# separate blast radius). The Cloudflare edge and its origin-TLS secrets live
# in the sibling cloudflare stack.
#
# Graph (this stack; <upstream> = linked values passed in as plain vars):
#   clouddeploy (targets on <gke_cluster_id>) ── deploy_release
#   mattermost_image  -> pushes to <artifact_registry_*>
#   secrets (dev-postgres-password + matterbridge-tokens,
#            accessors = <workload_identity_members>)
#   gke_auth (lookup on <gke_cluster_id>) ─ helm provider ─ cluster_bootstrap
#            (mattermost-operator + ingress-nginx on <ingress_ip_address>)
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

    # Rendered into the manifests' `# from-param: ${...}` placeholders on every
    # release, so the platform-published values (bucket, WI emails) flow from
    # Terraform into Kubernetes without hand-edited markers.
    deploy_parameters = {
      filestore_bucket   = var.gcs_bucket_name
      mattermost_gsa     = var.workload_identity_emails.mattermost
      mattermost_dev_gsa = var.workload_identity_emails.dev
      matterbridge_gsa   = var.workload_identity_emails.matterbridge
    }

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

    secrets = {
      # In-cluster dev Postgres password (generated, read by the dev tenant).
      "dev-postgres-password" = {
        generate  = true
        accessors = [var.workload_identity_members.dev]
      }
      # matterbridge bridge config. Seed a DEFAULT matterbridge.toml so a secret
      # version always exists and the pod leaves ContainerCreating on init (the
      # CSI mount needs >=1 version -- an empty secret would wedge the pod). The
      # default points at the IN-CLUSTER prod Mattermost Service on 8065
      # (matterbridge bridges in-cluster; the public yourown.chat path is closed
      # to it by Cloudflare + Authenticated Origin Pulls -- see
      # helm/matterbridge/networkpolicy.yaml). The gateway ships DISABLED with
      # placeholder creds, so matterbridge starts and idles without a failing
      # login. To go live, add a NEW version out-of-band with a real bot Token,
      # Team and enable=true (versions/latest is what the pod mounts):
      #   gcloud secrets versions add matterbridge-tokens --data-file=matterbridge.toml
      "matterbridge-tokens" = {
        value     = <<-TOML
          # Default seeded by Terraform so the matterbridge pod starts on init.
          # Replace Token/Team and set enable=true (add a new Secret Manager
          # version) to bridge the prod Mattermost.
          [mattermost.prod]
          Server="mattermost.mattermost.svc.cluster.local:8065"
          NoTLS=true
          Team="REPLACE_ME_TEAM"
          Token="REPLACE_ME_TOKEN"
          PrefixMessagesWithNick=true
          RemoteNickFormat="[{PROTOCOL}] <{NICK}> "

          [[gateway]]
          name="prod"
          enable=false

          [[gateway.inout]]
          account="mattermost.prod"
          channel="off-topic"
        TOML
        accessors = [var.workload_identity_members.matterbridge]
      }
      # The Cloudflare origin-protection secrets (mattermost-origin-tls-* +
      # cloudflare-origin-pull-ca) live in the CLOUDFLARE stack: linked stacks
      # cannot publish sensitive values, so the Origin CA private key is
      # written into Secret Manager there and never crosses a stack boundary.
    }
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

# --- Cluster bootstrap (auth lookup) -----------------------------------------
# Data-only: resolves the platform cluster's endpoint/CA from the published
# cluster ID and mints a short-lived apply-SA token. Its outputs configure the
# stack-level helm provider (providers.tfcomponent.hcl) -- a separate component
# from cluster_bootstrap because a component cannot both feed a provider's
# configuration and consume that provider.
component "gke_auth" {
  source = "./modules/gke-auth"

  inputs = {
    gke_cluster_id = var.gke_cluster_id
  }

  providers = {
    google = provider.google.this
  }
}

# --- Cluster bootstrap (releases) --------------------------------------------
# The cluster-scoped prerequisites for the helm/ workloads (docs/DEPLOY.md
# "One-time setup" step 2), installed automatically right after the platform
# cluster exists instead of a manual `helm upgrade --install`:
#   - Mattermost Operator + CRDs (prod Mattermost is an operator CR)
#   - ingress-nginx, pinned to the platform-published ingress IP and admitting
#     only Cloudflare source ranges (skipped when the IP is null)
component "cluster_bootstrap" {
  source = "./modules/cluster-bootstrap"

  inputs = {
    mattermost_operator_chart_version = var.mattermost_operator_chart_version
    ingress_nginx_chart_version       = var.ingress_nginx_chart_version
    adopt_existing_releases           = var.adopt_existing_cluster_bootstrap_releases

    # Platform-published "white address"; replaces the manual loadBalancerIP
    # step in helm/ingress-nginx/values.yaml (kept as the manual fallback).
    ingress_load_balancer_ip = var.ingress_ip_address
  }

  providers = {
    helm = provider.helm.this
  }
}
