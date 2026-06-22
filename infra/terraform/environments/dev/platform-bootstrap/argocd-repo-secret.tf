# The ClusterSecretStore "aws-secrets-manager" is managed by ArgoCD via
# infra/k8s/platform/cluster-secret-store.yaml — do NOT re-create it here.
# Terraform only manages the ExternalSecret that populates the ArgoCD repo secret.

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
        name = "aws-secrets-manager"
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
}
