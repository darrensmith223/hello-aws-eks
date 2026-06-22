output "argocd_hostname" {
  value = local.hostnames.argocd
}

output "argocd_alb_dns_name" {
  value = data.aws_lb.argocd.dns_name
}

output "route53_record_fqdn" {
  value = aws_route53_record.argocd.fqdn
}
