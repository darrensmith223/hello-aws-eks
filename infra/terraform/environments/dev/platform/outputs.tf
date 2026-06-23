output "cluster_name" {
  value = local.aws_outputs.cluster_name
}

output "argocd_hostname" {
  value = local.hostnames.argocd
}

output "argocd_alb_dns_name" {
  value = data.aws_lb.argocd.dns_name
}

output "vpc_id" {
  value = local.aws_outputs.vpc_id
}
