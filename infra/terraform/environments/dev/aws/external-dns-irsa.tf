module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                  = "${var.name}-external-dns"
  attach_external_dns_policy = true

  external_dns_hosted_zone_arns = [
    data.aws_route53_zone.selected.arn
  ]

  oidc_providers = {
    main = {
      provider_arn               = module.eks_foundation.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  tags = {
    Component = "external-dns"
  }
}