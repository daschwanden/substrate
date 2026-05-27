# Copyright 2026 Google.
# This software is provided as-is, without warranty or representation for any use or purpose.
# Your use of it is subject to your agreement with Google.
variable "project_id" {
  description = "Google Cloud Project Identifier"
}

variable "region" {
  description = "region"
  default     = "us-central1"
}

variable "zone" {
  description = "zone"
  default     = "us-central1-b"
}

variable "substrate_vpc" {
  description = "substrate vpc"
  default     = "substrate-vpc"
}

variable "substrate_subnet" {
  description = "substrate subnet"
  default     = "substrate-subnet"
}

variable "cluster_name" {
  description = "cluster name"
  default     = "substrate-poc"
}
variable "cluster_version" {
  description = "cluster version"
  default     = "1.35.0-gke.2398000"
}
variable "default_pool_count" {
  description = "number of default nodepool nodes"
  default     = 1
}

variable "default_pool_name" {
  description = "default nodepool name"
  default     = "default-pool"
}

variable "default_pool_machine_type" {
  description = "default nodepool machine type"
  default     = "n2-standard-8"
}

variable "gvisor_pool_count" {
  description = "number of gvisor nodepool nodes"
  default     = 2
}

variable "gvisor_pool_name" {
  description = "gvisor nodepool name"
  default     = "gvisor-pool"
}

variable "gvisor_pool_machine_type" {
  description = "gvisor nodepool machine type"
  default     = "n2-standard-8"
}

variable "gvisor_pool_version" {
  description = "gvisor nodepool version" 
  default     = "1.35.0-gke.2398000"
}

variable "placeholder_owner" {
  description = "Owner of the repo" 
  default     = "agent-substrate"
}

variable "placeholder_repo" {
  description = "Name of the repo" 
  default     = "substrate"
}

variable "placeholder_branch" {
  description = "Name of the branch" 
  default     = "feature/iac"
}
