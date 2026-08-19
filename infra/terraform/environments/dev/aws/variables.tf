variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "name" {
  description = "Base name for project resources."
  type        = string
  default     = "practice-eks-dev"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to use."
  type        = number
  default     = 2
}

variable "node_instance_types" {
  description = "EC2 instance types for the default managed node group. c6gd instances are Graviton (arm64) and include local NVMe instance storage, which is NOT used for Longhorn here -- a separate persistent EBS volume is attached instead. See eks-foundation module notes."
  type        = list(string)
  default     = ["c6gd.xlarge"]
}

variable "node_min_size" {
  description = "Minimum number of nodes in the default managed node group. Kept equal to node_desired_size so the cluster never drops below the 3 nodes Longhorn is configured to replicate across."
  type        = number
  default     = 3
}

variable "node_desired_size" {
  description = "Desired number of nodes in the default managed node group."
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum number of nodes in the default managed node group. One node of headroom above desired_size to allow surge replacement during rolling upgrades."
  type        = number
  default     = 4
}

variable "domain_name" {
  description = "Base DNS domain for this environment."
  type        = string
}
