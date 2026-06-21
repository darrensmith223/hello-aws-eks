variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "name" {
  type    = string
  default = "practice-eks-dev"
}

variable "kubernetes_version" {
  type    = string
  default = "1.33"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Helm chart version for the AWS Load Balancer Controller."
  type        = string
  default     = "1.14.0"
}

variable "domain_name" {
  description = "Base DNS domain for this environment."
  type        = string
}

variable "gitops_repo_url" {
  description = "Git repository URL containing ArgoCD platform manifests."
  type        = string
}

variable "gitops_repo_username" {
  description = "Username for ArgoCD to access the GitOps repo."
  type        = string
  sensitive   = true
}

variable "gitops_repo_token" {
  description = "Token/password for ArgoCD to access the GitOps repo."
  type        = string
  sensitive   = true
}