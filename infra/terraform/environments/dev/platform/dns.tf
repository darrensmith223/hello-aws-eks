data "aws_route53_zone" "selected" {
  name         = var.domain_name
  private_zone = false
}

# The AWS Load Balancer Controller tags ALBs by Kubernetes ingress stack.
# Reading the ALB from AWS avoids destroy-time failures when Kubernetes ingress
# status has already become null or unavailable.
data "aws_lb" "argocd" {
  tags = {
    "ingress.k8s.aws/stack" = "argocd/argocd-server"
  }

  depends_on = [helm_release.argocd]
}

# Use an A alias record rather than a CNAME. ALB hostnames are always in
# AWS-controlled zones, so an alias A record is the correct record type —
# it is also exactly what ExternalDNS creates, which prevents a type conflict
# if ExternalDNS has already registered the hostname before this apply runs.
resource "aws_route53_record" "argocd" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.hostnames.argocd
  type    = "A"

  alias {
    name                   = data.aws_lb.argocd.dns_name
    zone_id                = data.aws_lb.argocd.zone_id
    evaluate_target_health = true
  }

  allow_overwrite = true
}
