variable "project_id" {
  type        = string
  description = "Project the chart-publish build identity, IAM bindings and Cloud Build trigger live in."
}

variable "region" {
  type        = string
  description = "Region of the Cloud Build trigger (must match the region of the 2nd-gen repository link)."
}

variable "apply_service_account_email" {
  type        = string
  description = "Terraform apply SA (the impersonated identity). Granted actAs on the chart-publish SA so it can create a trigger that runs as that least-privilege identity."
}

# --- Source: the public platform repository (holds helm/platform) -----------
variable "repository_id" {
  type        = string
  description = "Fully-qualified Cloud Build 2nd-gen repository ID of the public platform repository (the one holding helm/platform). Reuses the link owned by the deploy-release module; this module creates no repository link."

  validation {
    condition     = can(regex("^projects/[^/]+/locations/[^/]+/connections/[^/]+/repositories/[^/]+$", var.repository_id))
    error_message = "repository_id must be a fully-qualified Cloud Build v2 repository ID (projects/<p>/locations/<l>/connections/<c>/repositories/<r>)."
  }
}

variable "branch_regex" {
  type        = string
  description = "Branch regex whose pushes publish platform chart versions. Only the canonical branch may publish; feature branches are verified by pull-request checks, not by this trigger."
  default     = "^main$"
}

variable "chart_source_root" {
  type        = string
  description = "Repository-relative directory that contains one subdirectory per platform chart (each with Chart.yaml)."
  default     = "helm/platform"

  validation {
    condition     = !startswith(var.chart_source_root, "/") && !endswith(var.chart_source_root, "/")
    error_message = "chart_source_root must be a repository-relative path without leading or trailing slashes."
  }
}

variable "chart_test_glob" {
  type        = string
  description = "Repository-relative shell glob of platform chart test scripts executed before publication (deterministic render, schema and policy tests)."
  default     = "helm/test/platform-*.test.sh"
}

# --- Target registry (ONE unified repository, owned by platform-gcp) --------
variable "artifact_registry_location" {
  type        = string
  description = "Location of the unified Artifact Registry repository platform charts are pushed to (e.g. europe-west3)."
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "ID of the unified Artifact Registry repository platform charts are pushed to (e.g. docker). The chart-publish SA gets a single repo-scoped writer binding on it."
}

variable "chart_path_prefix" {
  type        = string
  description = "Path segment under the unified repository that holds OCI chart artifacts. Charts are pushed to oci://<location>-docker.pkg.dev/<project>/<repository>/<prefix>/<chart-name>:<chart-version>."
  default     = "charts"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.chart_path_prefix))
    error_message = "chart_path_prefix must be lowercase kebab-case."
  }
}

# --- Release evidence -------------------------------------------------------
variable "evidence_bucket_name" {
  type        = string
  description = "Existing private bucket that receives one JSON evidence object per published chart version (source revision, chart version, OCI digest, test results, build ID). null disables evidence upload; Cloud Logging still records the build."
  default     = null
}

# --- Pinned build tool images ------------------------------------------------
variable "helm_image" {
  type        = string
  description = "Pinned Helm 3 image whose static helm binary is reused by the verify-and-publish step. Pinned by digest so chart packaging cannot change underneath an immutable source revision."
  default     = "docker.io/alpine/helm:3.21.4@sha256:82c0ce1b4196539946ed01bdfd9345cf74ca999b95d3074ce3f2f5ea45c96e80"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.helm_image))
    error_message = "helm_image must be pinned by digest."
  }
}

variable "cloud_cli_image" {
  type        = string
  description = "Pinned Google Cloud CLI image used for registry authentication and evidence upload."
  default     = "gcr.io/google.com/cloudsdktool/google-cloud-cli:573.0.0@sha256:f0b4abeb30773243f9ae95abe201ec01de07d5ed582b56ca52879eb3dbe209c3"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.cloud_cli_image))
    error_message = "cloud_cli_image must be pinned by digest."
  }
}

variable "build_timeout" {
  type        = string
  description = "Cloud Build timeout for one publication run."
  default     = "1200s"
}
