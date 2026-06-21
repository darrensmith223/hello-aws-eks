output "cluster_name" {
  value = module.eks_foundation.cluster_name
}

output "cluster_endpoint" {
  value = module.eks_foundation.cluster_endpoint
}

output "cluster_version" {
  value = module.eks_foundation.cluster_version
}

output "vpc_id" {
  value = module.eks_foundation.vpc_id
}

output "private_subnet_ids" {
  value = module.eks_foundation.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.eks_foundation.public_subnet_ids
}

output "oidc_provider_arn" {
  value = module.eks_foundation.oidc_provider_arn
}

output "kubectl_update_kubeconfig_command" {
  value = module.eks_foundation.kubectl_update_kubeconfig_command
}

output "aws_region" {
  value = var.region
}

output "aws_load_balancer_controller_role_arn" {
  value = module.aws_load_balancer_controller_irsa.iam_role_arn
}
