$ErrorActionPreference = "Stop"

$ExpectedArnFragment = "user/darren-iam"
$ClusterName = "practice-eks-dev"
$TerraformDir = "infra/terraform/environments/dev"

function Step($Message) {
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Warn($Message) {
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Run-AllowFailure($ScriptBlock) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $output = & $ScriptBlock 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    return @{
        Output = $output
        ExitCode = $exitCode
    }
}

function Wait-Until($Description, [scriptblock]$Check, $TimeoutSeconds = 600, $SleepSeconds = 15) {
    Step "Waiting for $Description"

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

Step "Validating AWS identity"

$CallerArn = aws sts get-caller-identity --query Arn --output text
Write-Host "AWS identity: $CallerArn"

if ($CallerArn -notlike "*$ExpectedArnFragment*") {
    throw "Refusing to destroy. Expected AWS identity containing '$ExpectedArnFragment', but got '$CallerArn'."
}

Step "Checking EKS cluster"

$ClusterExists = $false

$ClusterCheck = Run-AllowFailure {
    aws eks describe-cluster `
        --name $ClusterName `
        --query "cluster.status" `
        --output text
}

if ($ClusterCheck.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($ClusterCheck.Output | Out-String).Trim())) {
    $ClusterStatus = ($ClusterCheck.Output | Out-String).Trim()
    Write-Host "Cluster status: $ClusterStatus"
    $ClusterExists = $true
}
else {
    Warn "EKS cluster does not exist or is unreachable. Skipping Kubernetes cleanup."
}

if ($ClusterExists) {
    Step "Updating kubeconfig"

    $Region = terraform -chdir=$TerraformDir output -raw aws_region

    aws eks update-kubeconfig `
        --name $ClusterName `
        --region $Region

    Step "Deleting ArgoCD Applications"

    $deleteApps = Run-AllowFailure {
        kubectl delete applications.argoproj.io --all -n argocd --ignore-not-found=true
    }

    if ($deleteApps.ExitCode -ne 0) {
        Warn "Could not delete ArgoCD Applications. Continuing."
    }

    Step "Deleting ingresses"

    $deleteIngresses = Run-AllowFailure {
        kubectl delete ingress --all -A --ignore-not-found=true
    }

    if ($deleteIngresses.ExitCode -ne 0) {
        Warn "Could not delete ingresses. Continuing."
    }

    Step "Uninstalling ArgoCD"

    $uninstallArgo = Run-AllowFailure {
        helm uninstall argocd -n argocd --timeout 10m --wait
    }

    if ($uninstallArgo.ExitCode -ne 0) {
        Warn "ArgoCD uninstall failed or was already gone. Continuing."
    }

    Step "Uninstalling External Secrets"

    $uninstallEso = Run-AllowFailure {
        helm uninstall external-secrets -n external-secrets --timeout 10m --wait
    }

    if ($uninstallEso.ExitCode -ne 0) {
        Warn "External Secrets uninstall failed or was already gone. Continuing."
    }

    Step "Deleting namespaces"

    $deleteNamespaces = Run-AllowFailure {
        kubectl delete namespace argocd external-secrets --ignore-not-found=true --timeout=120s
    }

    if ($deleteNamespaces.ExitCode -ne 0) {
        Warn "Namespace deletion failed or timed out. Terraform may finish cleanup."
    }
}

Step "Detecting VPC from Terraform state"

$VpcId = $null

$vpcState = Run-AllowFailure {
    terraform -chdir=$TerraformDir state show "module.eks_foundation.module.vpc.aws_vpc.this[0]"
}

if ($vpcState.ExitCode -eq 0) {
    $VpcId = $vpcState.Output |
        Select-String '^\s*id\s+=' |
        ForEach-Object { ($_ -split '=')[1].Trim().Trim('"') } |
        Select-Object -First 1
}

if ($VpcId) {
    Write-Host "Detected VPC: $VpcId"

    Wait-Until "load balancers in VPC $VpcId" {
        $lbCheck = Run-AllowFailure {
            aws elbv2 describe-load-balancers `
                --query "LoadBalancers[?VpcId=='$VpcId'].LoadBalancerArn" `
                --output text
        }

        if ($lbCheck.ExitCode -ne 0) {
            return $true
        }

        $lbs = ($lbCheck.Output | Out-String).Trim()
        return [string]::IsNullOrWhiteSpace($lbs)
    } 600 20

    Wait-Until "ELB network interfaces in VPC $VpcId" {
        $eniCheck = Run-AllowFailure {
            aws ec2 describe-network-interfaces `
                --filters Name=vpc-id,Values=$VpcId `
                --query "NetworkInterfaces[?contains(Description, 'ELB') || contains(Description, 'load balancer')].[NetworkInterfaceId]" `
                --output text
        }

        if ($eniCheck.ExitCode -ne 0) {
            return $true
        }

        $enis = ($eniCheck.Output | Out-String).Trim()
        return [string]::IsNullOrWhiteSpace($enis)
    } 600 20
}
else {
    Warn "Could not detect VPC ID from Terraform state. Skipping ALB/ENI wait."
}

Step "Checking for stale Kubernetes or Helm resources in Terraform state"

$staleState = Run-AllowFailure {
    terraform -chdir=$TerraformDir state list
}

if ($staleState.ExitCode -eq 0) {
    $staleResources = $staleState.Output | Select-String "kubernetes_|helm_release"

    if ($staleResources) {
        Warn "Stale Kubernetes/Helm resources still exist in Terraform state:"
        $staleResources | ForEach-Object { Write-Host $_ }

        throw "Remove stale Kubernetes/Helm state entries before continuing."
    }
}

Step "Running Terraform destroy"

terraform -chdir=$TerraformDir destroy