resource "kubernetes_manifest" "aws_secrets_manager_cluster_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"

    metadata = {
      name = "aws-secrets-manager"
    }

    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region

          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  }

}

resource "kubernetes_manifest" "argocd_repo_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"

    metadata = {
      name      = "hello-aws-eks-repo"
      namespace = "argocd"
    }

    spec = {
      refreshInterval = "1h"

      secretStoreRef = {
        name = kubernetes_manifest.aws_secrets_manager_cluster_store.manifest.metadata.name
        kind = "ClusterSecretStore"
      }

      target = {
        name           = "hello-aws-eks-repo"
        creationPolicy = "Owner"

        template = {
          metadata = {
            labels = {
              "argocd.argoproj.io/secret-type" = "repository"
            }
          }

          data = {
            type     = "git"
            url      = var.gitops_repo_url
            username = "{{ .username }}"
            password = "{{ .password }}"
          }
        }
      }

      data = [
        {
          secretKey = "username"
          remoteRef = {
            key      = "${var.environment}/argocd/repo/hello-aws-eks"
            property = "username"
          }
        },
        {
          secretKey = "password"
          remoteRef = {
            key      = "${var.environment}/argocd/repo/hello-aws-eks"
            property = "password"
          }
        }
      ]
    }
  }

  depends_on = [
    kubernetes_manifest.aws_secrets_manager_cluster_store
  ]
}
