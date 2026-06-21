resource "aws_acm_certificate" "argocd" {
  domain_name       = local.argocd_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "argocd_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.argocd.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.selected.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "argocd" {
  certificate_arn         = aws_acm_certificate.argocd.arn
  validation_record_fqdns = [for record in aws_route53_record.argocd_cert_validation : record.fqdn]
}