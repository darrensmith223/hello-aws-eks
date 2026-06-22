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
}

resource "aws_route53_record" "argocd" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.hostnames.argocd
  type    = "CNAME"
  ttl     = 300
  records = [data.aws_lb.argocd.dns_name]

  allow_overwrite = true
}
