output "argocd_hostname" {
  value = local.hostnames.argocd
}

output "cluster_name" {
  value = local.aws_outputs.cluster_name
}

output "vpc_id" {
  value = local.aws_outputs.vpc_id
}
