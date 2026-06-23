resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = var.argocd_chart_version

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
            "alb.ingress.kubernetes.io/certificate-arn" = local.aws_outputs.argocd_certificate_arn
            "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.argocd,
    helm_release.aws_load_balancer_controller,
  ]
}

# ArgoCD repo secret created as a plain Kubernetes Secret whose value is
# fetched once from AWS Secrets Manager at apply time by the deploy script
# (via `aws secretsmanager get-secret-value`). This avoids the chicken-and-egg
# problem of the old approach where ArgoCD couldn't pull its own repo because
# the ExternalSecret needed ArgoCD to already be syncing in order to work.
#
# The secret is labelled so ArgoCD picks it up automatically as a repository
# credential. Rotation: re-run `scripts/create-repo-keys.ps1`, then
# `terraform apply` to push the new value.
data "aws_secretsmanager_secret_version" "argocd_repo" {
  secret_id = "${var.environment}/argocd/repo/hello-aws-eks"
}

locals {
  argocd_repo_creds = jsondecode(data.aws_secretsmanager_secret_version.argocd_repo.secret_string)
}

resource "kubernetes_secret" "argocd_repo" {
  metadata {
    name      = "hello-aws-eks-repo"
    namespace = kubernetes_namespace.argocd.metadata[0].name

    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.gitops_repo_url
    username = local.argocd_repo_creds["username"]
    password = local.argocd_repo_creds["password"]
  }

  depends_on = [helm_release.argocd]
}

# The platform-root Application tells ArgoCD to manage everything under
# infra/k8s/platform, making this the single bootstrap point for all
# platform-level workloads (vault, observability, ldap, apps).
resource "kubernetes_manifest" "argocd_platform_root" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = "platform-root"
      namespace = "argocd"
    }

    spec = {
      project = "default"

      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "main"
        path           = "infra/k8s/platform"
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }

        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  }

  depends_on = [
    kubernetes_secret.argocd_repo,
    helm_release.argocd,
  ]
}
