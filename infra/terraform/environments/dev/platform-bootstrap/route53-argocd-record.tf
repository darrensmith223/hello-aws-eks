data "aws_route53_zone" "selected" {
  name         = var.domain_name
  private_zone = false
}

data "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }
}

resource "aws_route53_record" "argocd" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.hostnames.argocd
  type    = "CNAME"
  ttl     = 300
  records = [data.kubernetes_ingress_v1.argocd.status[0].load_balancer[0].ingress[0].hostname]

  allow_overwrite = true
}
