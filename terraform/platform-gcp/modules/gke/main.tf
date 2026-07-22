locals {
  # Named after var.location (zonal -> europe-west3-b, regional -> europe-west3).
  cluster_name  = var.location
  node_sa_id    = var.location
  workload_pool = "${var.project_id}.svc.id.goog"
}

# Dedicated least-privilege node identity (never use the default compute SA).
resource "google_service_account" "node" {
  project      = var.project_id
  account_id   = local.node_sa_id
  display_name = "GKE node SA for ${local.cluster_name}"
}

# Minimum roles a node needs for logging, monitoring and pulling images.
resource "google_project_iam_member" "node" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = local.cluster_name
  location = var.location

  network    = var.network_id
  subnetwork = var.subnet_id

  # Manage node pools separately from the cluster lifecycle.
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"
  datapath_provider = (
    var.enable_dataplane_v2 ? "ADVANCED_DATAPATH" : "DATAPATH_PROVIDER_UNSPECIFIED"
  )

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block

    master_global_access_config {
      enabled = true
    }
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_networks) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_networks
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  workload_identity_config {
    workload_pool = local.workload_pool
  }

  secret_manager_config {
    enabled = var.enable_secret_manager_csi
  }

  # Application-layer Secrets encryption: envelope-encrypt every Kubernetes
  # Secret in etcd with the shared CMEK key BEFORE it is written (KEK wraps the
  # DEK, DEK is cached). Null key -> block omitted -> Google-managed at-rest only.
  # In-place update (not ForceNew); enabling on a live cluster re-encrypts
  # existing Secrets in the background. The GKE service agent needs
  # cryptoKeyEncrypterDecrypter on the key (granted by the kms component).
  dynamic "database_encryption" {
    for_each = var.database_encryption_key == null ? [] : [var.database_encryption_key]
    content {
      state    = "ENCRYPTED"
      key_name = database_encryption.value
    }
  }

  logging_config {
    enable_components = var.logging_components
  }

  monitoring_config {
    enable_components = var.monitoring_components

    managed_prometheus {
      enabled = var.enable_managed_prometheus
    }
  }

  maintenance_policy {
    daily_maintenance_window {
      start_time = formatdate("hh:mm", var.maintenance_start_time)
    }
  }

  deletion_protection = var.deletion_protection
  resource_labels     = var.resource_labels

  lifecycle {
    ignore_changes = [
      # The initial node pool is removed right after creation.
      initial_node_count,
      # GKE reports database_encryption.state as the RUNTIME CurrentState (e.g.
      # ALL_OBJECTS_ENCRYPTION_ENABLED once encryption has fully applied), which
      # never textually equals the config's "ENCRYPTED" -> a cosmetic perpetual
      # diff on every plan (the apply is a GKE no-op). Ignore the reported state;
      # key_name stays managed, so a key change is still detected, and the block
      # is still created with state=ENCRYPTED on a fresh cluster.
      database_encryption[0].state,
    ]
  }
}

resource "google_container_node_pool" "pool" {
  for_each = var.node_pools

  project  = var.project_id
  name     = "${var.location}-${each.key}"
  cluster  = google_container_cluster.this.id
  location = var.location

  autoscaling {
    min_node_count = each.value.min_count
    max_node_count = each.value.max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = each.value.machine_type
    spot         = each.value.spot
    disk_size_gb = each.value.disk_size_gb
    disk_type    = each.value.disk_type
    image_type   = "COS_CONTAINERD"

    service_account = google_service_account.node.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels          = merge(var.resource_labels, each.value.labels)
    resource_labels = var.resource_labels

    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    ignore_changes = [
      # Autoscaler owns the live node count.
      node_count,
    ]
  }
}
