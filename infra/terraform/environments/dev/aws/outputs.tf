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

output "external_secrets_role_arn" {
  value = module.external_secrets_irsa.iam_role_arn
}

output "argocd_certificate_arn" {
  value = aws_acm_certificate_validation.argocd.certificate_arn
}

output "hostnames" {
  value = local.hostnames
}

output "vault_kms_key_id" {
  value = aws_kms_key.vault_unseal.key_id
}

output "vault_kms_key_arn" {
  value = aws_kms_key.vault_unseal.arn
}

output "vault_role_arn" {
  value = module.vault_irsa.iam_role_arn
}

output "external_dns_role_arn" {
  value = module.external_dns_irsa.iam_role_arn
}

output "route53_zone_id" {
  value = data.aws_route53_zone.selected.zone_id
}

output "route53_zone_arn" {
  value = data.aws_route53_zone.selected.arn
}
output "loki_bucket_name" {
  value = aws_s3_bucket.loki.id
}

output "loki_role_arn" {
  value = module.loki_irsa.iam_role_arn
}
