resource "kubernetes_manifest" "aws_secrets_manager_cluster_secret_store" {
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
          region  = data.terraform_remote_state.aws.outputs.aws_region

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