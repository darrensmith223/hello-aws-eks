param(
    [string]$Environment = "dev",
    [switch]$PlanOnly,
    [switch]$SkipBootstrap,
    [switch]$SkipKubeconfig
)

$env:AWS_PROFILE = "terraform"
Write-Host "Using AWS profile: $env:AWS_PROFILE"
aws sts get-caller-identity

$ErrorActionPreference = "Stop"

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Run-Step($Message, [scriptblock]$ScriptBlock) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
    & $ScriptBlock
    if ($LASTEXITCODE -ne 0) {
        throw "Step failed: $Message"
    }
}

function Run-AllowFailure([scriptblock]$ScriptBlock) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $ScriptBlock 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return @{ Output = $output; ExitCode = $exitCode }
}

function Wait-Until($Description, [scriptblock]$Check, $TimeoutSeconds = 600, $SleepSeconds = 15) {
    Write-Host ""
    Write-Host "=== Waiting for $Description ===" -ForegroundColor Cyan
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (& $Check) {
            Write-Host "$Description complete."
            return
        }
        Start-Sleep -Seconds $SleepSeconds
        $elapsed += $SleepSeconds
        Write-Host "Still waiting for $Description... ${elapsed}s elapsed"
    }
    throw "Timed out waiting for $Description"
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$BootstrapDir     = "infra/terraform/bootstrap"
$AwsDir           = "infra/terraform/environments/$Environment/aws"
$PlatformDir      = "infra/terraform/environments/$Environment/platform"
$BackendConfig    = "infra/terraform/environments/$Environment/backend.hcl"
$BackendConfigAbs = (Resolve-Path $BackendConfig).Path

Require-Command terraform
Require-Command aws
Require-Command helm
if (-not $SkipKubeconfig) { Require-Command kubectl }

foreach ($dir in @($BootstrapDir, $AwsDir, $PlatformDir)) {
    if (-not (Test-Path $dir)) { throw "Required directory not found: $dir" }
}
if (-not (Test-Path $BackendConfig)) { throw "Backend config not found: $BackendConfig" }

# Read bucket name from backend.hcl once so it never needs to be hardcoded
# in scripts or remote-state configs.
$StateBucket = (Get-Content $BackendConfig | Select-String 'bucket\s*=\s*"(.+)"').Matches[0].Groups[1].Value
if (-not $StateBucket) { throw "Could not parse bucket from $BackendConfig" }
Write-Host "State bucket: $StateBucket"

Run-Step "Checking AWS identity" {
    aws sts get-caller-identity
}

if (-not $SkipBootstrap) {
    Run-Step "Terraform init - bootstrap" {
        terraform "-chdir=$BootstrapDir" init
    }

    if ($PlanOnly) {
        Run-Step "Terraform plan - bootstrap" {
            terraform "-chdir=$BootstrapDir" plan
        }
    }
    else {
        Write-Host ""
        Write-Host "=== Terraform apply - bootstrap ===" -ForegroundColor Cyan
        $bootstrapApply = Run-AllowFailure {
            terraform "-chdir=$BootstrapDir" apply -auto-approve
        }

        if ($bootstrapApply.ExitCode -ne 0) {
            Write-Host "Bootstrap apply failed. Attempting to import existing bootstrap resources..." -ForegroundColor Yellow

            $lockTable  = (Get-Content "infra/terraform/bootstrap/terraform.tfvars" | Select-String 'lock_table_name\s*=\s*"(.+)"').Matches[0].Groups[1].Value
            $logsBacket = "$StateBucket-access-logs"

            # Import every bootstrap resource that may already exist in AWS.
            # Run-AllowFailure means an "already in state" or "does not exist"
            # result is silently ignored — only a genuine AWS error will surface.
            Run-AllowFailure { terraform "-chdir=$BootstrapDir" import aws_s3_bucket.terraform_state $StateBucket } | Out-Null
            Run-AllowFailure { terraform "-chdir=$BootstrapDir" import aws_s3_bucket.terraform_state_logs $logsBacket } | Out-Null
            Run-AllowFailure { terraform "-chdir=$BootstrapDir" import aws_dynamodb_table.terraform_locks $lockTable } | Out-Null

            Run-Step "Retrying Terraform apply - bootstrap" {
                terraform "-chdir=$BootstrapDir" apply -auto-approve
            }
        }
    }
}

foreach ($layer in @(
    @{ Name = "aws"; Path = $AwsDir },
    @{ Name = "platform"; Path = $PlatformDir }
)) {
    Run-Step "Terraform init - $($layer.Name)" {
        terraform "-chdir=$($layer.Path)" init -reconfigure "-backend-config=$BackendConfigAbs"
    }
}

if ($PlanOnly) {
    Run-Step "Terraform plan - aws layer" { terraform "-chdir=$AwsDir" plan }
    Write-Host ""
    Write-Host "PlanOnly stops after the aws plan because the platform plan requires the cluster to exist." -ForegroundColor Yellow
    exit 0
}

Run-Step "Terraform apply - aws layer" {
    terraform "-chdir=$AwsDir" apply -auto-approve
}

$clusterName          = terraform "-chdir=$AwsDir" output -raw cluster_name
$region               = terraform "-chdir=$AwsDir" output -raw aws_region
$longhornBackupBucket = terraform "-chdir=$AwsDir" output -raw longhorn_backup_bucket_name
$longhornBackupRoleArn = terraform "-chdir=$AwsDir" output -raw longhorn_backup_role_arn

if (-not $SkipKubeconfig) {
    Run-Step "Updating kubeconfig" {
        aws eks update-kubeconfig --region $region --name $clusterName
    }

    Run-Step "Verifying EKS nodes" {
        kubectl get nodes
    }
}

Run-Step "Adding Helm repositories" {
    helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ --force-update
    helm repo update
}

# ── Pass 1a: ALB Controller only ──────────────────────────────────────────────
# The ALB controller installs a mutating webhook. Any resource whose creation
# triggers that webhook (including other Helm chart ServiceAccounts) will fail
# with "no endpoints available" if the controller pods are not yet ready.
# Install and fully roll out the ALB controller before touching anything else.
Run-Step "Terraform apply - platform layer (pass 1a: ALB controller)" {
    terraform "-chdir=$PlatformDir" apply -auto-approve `
        -var "state_bucket=$StateBucket" `
        -target kubernetes_service_account.aws_load_balancer_controller `
        -target helm_release.aws_load_balancer_controller
}

Run-Step "Waiting for AWS Load Balancer Controller webhook to be ready" {
    kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=5m
}

# Give the webhook endpoint a moment to register after the rollout reports ready.
Start-Sleep -Seconds 15

# ── Pass 1b: Remaining Helm releases ──────────────────────────────────────────
# Now that the ALB webhook is healthy, install External Secrets, ExternalDNS,
# and ArgoCD. StorageClass and all namespaces/service accounts are included here.
Run-Step "Terraform apply - platform layer (pass 1b: remaining Helm releases)" {
    terraform "-chdir=$PlatformDir" apply -auto-approve `
        -var "state_bucket=$StateBucket" `
        -target helm_release.external_dns `
        -target helm_release.external_secrets `
        -target helm_release.argocd `
        -target kubernetes_storage_class.gp3 `
        -target kubernetes_annotations.gp2_not_default `
        -target kubernetes_namespace.external_dns `
        -target kubernetes_namespace.external_secrets `
        -target kubernetes_namespace.argocd `
        -target kubernetes_namespace.logging `
        -target kubernetes_namespace.vault `
        -target kubernetes_service_account.external_dns `
        -target kubernetes_service_account.external_secrets `
        -target kubernetes_service_account.vault `
        -target kubernetes_service_account.loki
}

Run-Step "Waiting for ExternalDNS rollout" {
    kubectl rollout status deployment/external-dns -n external-dns --timeout=5m
}

Run-Step "Waiting for External Secrets rollout" {
    kubectl rollout status deployment/external-secrets -n external-secrets --timeout=5m
}

Run-Step "Waiting for ArgoCD server rollout" {
    kubectl rollout status deployment/argocd-server -n argocd --timeout=10m
}

Run-Step "Waiting for ArgoCD repo-server rollout" {
    kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=10m
}

# ── Pass 2: CRD-dependent resources + DNS ─────────────────────────────────────
# ArgoCD CRDs (Application) and ESO CRDs (ClusterSecretStore) are now
# registered. Wait until the ESO webhook is answerable before applying —
# kubernetes_manifest validates the CRD via the API server at plan time and
# will fail with "cannot select exact GV" if the webhook is not yet ready.
Wait-Until "External Secrets webhook to be ready" {
    $ready = kubectl get endpointslice `
        -n external-secrets `
        -l kubernetes.io/service-name=external-secrets-webhook `
        -o jsonpath='{.items[0].endpoints[0].conditions.ready}' 2>$null

    return $ready -eq "true"
} 300 10

# Same for ArgoCD — wait for its CRD registration to settle.
Wait-Until "ArgoCD Application CRD to be established" {
    $crd = kubectl get crd applications.argoproj.io -o json 2>$null | ConvertFrom-Json
    if (-not $crd) { return $false }
    $established = $crd.status.conditions | Where-Object { $_.type -eq "Established" } | Select-Object -ExpandProperty status
    return $established -eq "True"
} 120 5

Run-Step "Terraform apply - platform layer (pass 2: CRD-dependent resources + DNS)" {
    terraform "-chdir=$PlatformDir" apply -auto-approve `
        -var "state_bucket=$StateBucket"
}

Wait-Until "ArgoCD ingress load balancer hostname" {
    $hostname = kubectl get ingress argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
    return -not [string]::IsNullOrWhiteSpace($hostname)
} 600 20

# Longhorn's S3 bucket and IAM role are Terraform outputs, while the Longhorn
# Helm Application stays GitOps-managed. Longhorn requires a credential Secret
# for S3 even when static access keys are not used. The Secret below contains
# only AWS_IAM_ROLE_ARN; EKS Pod Identity supplies short-lived credentials to
# longhorn-service-account, so no AWS access key or secret key is stored here.
# The BackupTarget CR is a first-class resource in Longhorn 1.12 and is applied
# only after its CRD/controller are ready.
Wait-Until "Longhorn BackupTarget CRD to be established" {
    $crd = kubectl get crd backuptargets.longhorn.io -o json 2>$null | ConvertFrom-Json
    if (-not $crd) { return $false }
    $established = $crd.status.conditions | Where-Object { $_.type -eq "Established" } | Select-Object -ExpandProperty status
    return $established -eq "True"
} 900 10

Wait-Until "Longhorn manager to be ready" {
    $result = Run-AllowFailure {
        kubectl rollout status daemonset/longhorn-manager -n longhorn-system --timeout=30s
    }
    return $result.ExitCode -eq 0
} 900 15

$longhornBackupCredentialSecret = "longhorn-backup-credentials"
$longhornBackupTarget = "s3://$longhornBackupBucket@$region/backupstore/"
$longhornBackupCredentialYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: $longhornBackupCredentialSecret
  namespace: longhorn-system
type: Opaque
stringData:
  AWS_IAM_ROLE_ARN: "$longhornBackupRoleArn"
"@

$longhornBackupTargetYaml = @"
apiVersion: longhorn.io/v1beta2
kind: BackupTarget
metadata:
  name: default
  namespace: longhorn-system
spec:
  backupTargetURL: "$longhornBackupTarget"
  credentialSecret: "$longhornBackupCredentialSecret"
  pollInterval: "5m"
"@

# Back up Longhorn volumes every day at 03:00 UTC. Putting the job in the
# "default" recurring-job group makes it apply automatically to Longhorn
# volumes that do not define their own recurring-job policy. Retain seven
# backups per volume and force a full backup after every seven incrementals.
$longhornRecurringBackupYaml = @"
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "0 3 * * *"
  task: "backup"
  groups:
    - default
  retain: 7
  concurrency: 1
  parameters:
    full-backup-interval: "7"
"@

Run-Step "Configuring Longhorn S3 backup credentials" {
    $longhornBackupCredentialYaml | kubectl apply -f -
}

Run-Step "Configuring Longhorn S3 backup target" {
    $longhornBackupTargetYaml | kubectl apply -f -
}

Wait-Until "Longhorn S3 backup target to be available" {
    $available = kubectl get backuptarget default -n longhorn-system -o jsonpath='{.status.available}' 2>$null
    return $available -eq "true"
} 600 15

Run-Step "Configuring Longhorn daily recurring backups" {
    $longhornRecurringBackupYaml | kubectl apply -f -
}

Write-Host "Longhorn backup target: $longhornBackupTarget"
Write-Host "Longhorn recurring backup: daily-backup at 03:00 UTC (retain 7)"
Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
