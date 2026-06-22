variable "name" {
  description = "Base name used for the VPC and EKS cluster."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "environment" {
  description = "Environment name, for example dev, test, prod."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Must be set explicitly by the caller — no default to prevent silent drift across environments."
  type        = string
  # No default: callers must always pin this intentionally.
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
  description = "EC2 instance types for the default managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_min_size" {
  description = "Minimum number of nodes in the default managed node group."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 1
    error_message = "node_min_size must be at least 1."
  }
}

variable "node_desired_size" {
  description = "Desired number of nodes in the default managed node group."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= var.node_min_size
    error_message = "node_desired_size must be >= node_min_size."
  }
}

variable "node_max_size" {
  description = "Maximum number of nodes in the default managed node group."
  type        = number
  default     = 3

  validation {
    condition     = var.node_max_size >= var.node_desired_size
    error_message = "node_max_size must be >= node_desired_size."
  }
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}
