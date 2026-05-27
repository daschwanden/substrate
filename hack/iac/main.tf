# Copyright 2026 Google.
# This software is provided as-is, without warranty or representation for any use or purpose.
# Your use of it is subject to your agreement with Google.

data "google_project" "project" {
}

data "google_compute_default_service_account" "default" {
}

##########################################################################
# Enable the required Cloud APIs
##########################################################################
resource "google_project_service" "services" {
  for_each = toset([
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudtrace.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ])
  project = var.project_id
  service = each.key

  disable_on_destroy = false
}

##########################################################################
# Set up the VPC and subnet
##########################################################################
resource "google_compute_network" "substrate_vpc" {
  name                    = var.substrate_vpc
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "substrate_subnet" {
  name          = var.substrate_subnet
  ip_cidr_range = "10.0.0.0/16"
  region        = var.region
  network       = google_compute_network.substrate_vpc.id
  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.1.0.0/16"
  }
  secondary_ip_range {
    range_name    = "pod-range"
    ip_cidr_range = "10.2.0.0/16"
  }
}

# allow access from health check ranges
resource "google_compute_firewall" "allow_l7_xlb_fw_hc" {
  name          = "allow-l7-xlb-fw-hc"
  direction     = "INGRESS"
  network       = google_compute_network.substrate_vpc.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  allow {
    protocol = "tcp"
  }
  target_tags = ["allow-health-check"]
}

# allow ssh ingress from iap
resource "google_compute_firewall" "allow_ssh_ingress_from_iap" {
  name          = "allow-ssh-ingress-from-iap"
  direction     = "INGRESS"
  network       = google_compute_network.substrate_vpc.id
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

##########################################################################
# Set up default service account permissions
##########################################################################
resource "google_project_iam_member" "default_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

resource "google_project_iam_member" "default_service_usage_admin" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageAdmin"
  member  = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

##########################################################################
# Set up the NAT Router
##########################################################################
resource "google_compute_router" "substrate_router" {
  name    = "substrate-router"
  region  = var.region
  network = google_compute_network.substrate_vpc.id

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "substrate_router_nat" {
  name                               = "substrate-router-nat"
  router                             = google_compute_router.substrate_router.name
  region                             = google_compute_router.substrate_router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

##########################################################################
# Set up the Artifact Registry 
##########################################################################
resource "google_artifact_registry_repository" "container_registry" {
  location      = var.region
  repository_id = "ate-images"
  description   = "docker repository"
  format        = "DOCKER"
  depends_on = [
    google_project_service.services["artifactregistry.googleapis.com"]
  ]
}

resource "google_artifact_registry_repository_iam_member" "atelet_artifact_reader" {
  location   = google_artifact_registry_repository.container_registry.location
  repository = google_artifact_registry_repository.container_registry.name
  role       = "roles/artifactregistry.reader"
  member     = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/ate-system/sa/atelet"
  depends_on = [
    google_container_cluster.substrate
  ]
}

resource "google_artifact_registry_repository_iam_member" "default_sa_artifact_reader" {
  location   = google_artifact_registry_repository.container_registry.location
  repository = google_artifact_registry_repository.container_registry.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

##########################################################################
# Set up the Snapshot bucket
##########################################################################
resource "google_storage_bucket" "snapshots" {
  name          = "snapshot-substrate-test-${var.project_id}"
  location      = "US"

  force_destroy               = true
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "atelet_snapshots_bucket_viewer" {
  bucket     = google_storage_bucket.snapshots.name
  role       = "roles/storage.bucketViewer"
  member     = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/ate-system/sa/atelet"
  depends_on = [
    google_container_cluster.substrate
  ]
}

resource "google_storage_bucket_iam_member" "atelet_snapshots_object_admin" {
  bucket     = google_storage_bucket.snapshots.name
  role       = "roles/storage.objectAdmin"
  member     = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/ate-system/sa/atelet"
  depends_on = [
    google_container_cluster.substrate
  ]
}

###########################################################################
# Set up the GKE cluster
##########################################################################
resource "google_container_cluster" "substrate" {
  name     = var.cluster_name
  provider = google-beta
  location = var.zone

  initial_node_count = var.default_pool_count

  network    = google_compute_network.substrate_vpc.id
  subnetwork = google_compute_subnetwork.substrate_subnet.id

  min_master_version = var.cluster_version 

  enable_k8s_beta_apis {
    enabled_apis = [
      "certificates.k8s.io/v1beta1/podcertificaterequests",
      "certificates.k8s.io/v1beta1/clustertrustbundles"
    ]
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pod-range"
    services_secondary_range_name = google_compute_subnetwork.substrate_subnet.secondary_ip_range.0.range_name
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  node_config {
    service_account = data.google_compute_default_service_account.default.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    labels = {
      env = var.project_id
    }

    machine_type = var.default_pool_machine_type
    tags         = ["default-pool-node", "allow-health-check"]
    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot = true
    }
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }

    gcp_filestore_csi_driver_config {
      enabled = true
    }

    pod_snapshot_config {
      enabled = true
    }
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  monitoring_config {
    managed_prometheus {
      enabled = true
    }

    advanced_datapath_observability_config {
      enable_metrics = true
      enable_relay   = true
    }
  }

  private_cluster_config {
    enable_private_nodes = true
  }

  datapath_provider = "ADVANCED_DATAPATH"

  enable_shielded_nodes = true

  deletion_protection = false
}

resource "google_container_node_pool" "gvisor" {
  provider   = google-beta
  name       = var.gvisor_pool_name
  cluster    = google_container_cluster.substrate.id
  node_count = var.gvisor_pool_count

  version = var.gvisor_pool_version
  
  node_config {
    service_account = data.google_compute_default_service_account.default.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    image_type = "COS_CONTAINERD"

    labels = {
      env = var.project_id
    }

    machine_type = var.gvisor_pool_machine_type
    tags         = ["gvisor-pool-node", "allow-health-check"]
    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot = true
    }

    sandbox_config {
      type = "GVISOR"
    }
  }
}

###########################################################################
# Set up permissions for Agents to access Vertex AI and Cloud Trace
###########################################################################
resource "google_project_iam_member" "cloud_trace" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/agents/sa/agents-sa"
  depends_on = [
    google_container_cluster.substrate
  ]
}

###########################################################################
# Set up permissions for Cloud Build to deploy to GKE and push to AR
###########################################################################
resource "google_project_iam_member" "cloudbuild_gke_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "cloudbuild_ar_writer" {
  location   = google_artifact_registry_repository.container_registry.location
  repository = google_artifact_registry_repository.container_registry.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

###########################################################################
# Cloud Build Trigger for ATE Deployment
###########################################################################
resource "google_cloudbuild_trigger" "ate_deploy" {
  name        = "ate-deploy-trigger"
  description = "Trigger to deploy ATE system using cloudbuild.yaml"

  filename = "hack/iac/cloudbuild.yaml"

  substitutions = {
    _CLUSTER_NAME     = var.cluster_name
    _CLUSTER_LOCATION = var.zone
    _REGISTRY_PATH    = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.container_registry.repository_id}"
  }

  github {
    owner = var.placeholder_owner
    name  = var.placeholder_repo
    push {
      branch = "^${var.placeholder_branch}$"
    }
  }

  depends_on = [
    google_project_service.services["cloudbuild.googleapis.com"]
  ]
}

