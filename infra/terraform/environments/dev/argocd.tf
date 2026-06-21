resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

locals {
  hostnames = {
    argocd  = "argocd.${var.domain_name}"
    grafana = "grafana.${var.domain_name}"
    ldap    = "ldap.${var.domain_name}"
    hello   = "hello.${var.domain_name}"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [
    yamlencode({
      global = {
        domain = local.hostnames.argocd
      }

      configs = {
        params = {
          "server.insecure" = true
        }
      }

      server = {
        service = {
          type = "ClusterIP"
        }

        ingress = {
          enabled          = true
          ingressClassName = "alb"
          hosts            = [local.hostnames.argocd]
          path             = "/"
          pathType         = "Prefix"

          annotations = {
            "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"     = "ip"
            "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\":80},{\"HTTPS\":443}]"
            "alb.ingress.kubernetes.io/certificate-arn" = aws_acm_certificate_validation.argocd.certificate_arn
            "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.argocd,
    aws_acm_certificate_validation.argocd,
    helm_release.aws_load_balancer_controller
  ]
}