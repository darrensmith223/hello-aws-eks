param(
    [string]$Environment = "dev"
)

$ErrorActionPreference = "Stop"

$ExpectedArnFragment = "user/darren-iam"
$ClusterName = "practice-eks-dev"

$AwsDir = "infra/terraform/environments/$Environment/aws"
$CoreDir = "infra/terraform/environments/$Environment/platform-core"
$ServicesDir = "infra/terraform/environments/$Environment/platform-services"
$BootstrapPlatformDir = "infra/terraform/environments/$Environment/platform-bootstrap"
$DnsDir = "infra/terraform/environments/$Environment/platform-dns"
$BackendConfigRelative = "infra/terraform/environments/$Environment/backend.hcl"

function Step($Message) {
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Warn($Message) {
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
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

function Terraform-Init-Layer($Name, $Path) {
    Step "Initializing $Name"

    terraform "-chdir=$Path" init `
        -reconfigure `
        "-backend-config=$BackendConfig"

    if ($LASTEXITCODE -ne 0) {
        throw "$Name terraform init failed."
    }
}

function Terraform-Destroy-Layer($Name, $Path, [bool]$ClusterExists, [bool]$Refresh = $true) {
    Step "Destroying $Name"

    $refreshArg = if ($Refresh) { "-refresh=true" } else { "-refresh=false" }

    $destroy = Run-AllowFailure {
        terraform "-chdir=$Path" destroy -auto-approve $refreshArg
    }

    if ($destroy.ExitCode -ne 0) {
        if ($ClusterExists) {
            Write-Host ($destroy.Output | Out-String)
            throw "$Name destroy failed while the cluster still exists. Review the Terraform error before continuing."
        }
        else {
            Warn "$Name destroy failed, likely because the EKS API is already gone. Continuing to AWS cleanup."
        }
    }
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root
$BackendConfig = Join-Path $Root $BackendConfigRelative

Step "Validating AWS identity"
$CallerArn = aws sts get-caller-identity --query Arn --output text
Write-Host "AWS identity: $CallerArn"
if ($CallerArn -notlike "*$ExpectedArnFragment*") {
    throw "Refusing to destroy. Expected AWS identity containing '$ExpectedArnFragment', but got '$CallerArn'."
}

foreach ($dir in @($AwsDir, $CoreDir, $ServicesDir, $BootstrapPlatformDir, $DnsDir)) {
    if (-not (Test-Path $dir)) {
        throw "Required Terraform directory not found: $dir"
    }
}

if (-not (Test-Path $BackendConfig)) {
    throw "Required Terraform backend config not found: $BackendConfig"
}

Terraform-Init-Layer "platform-dns" $DnsDir
Terraform-Init-Layer "platform-bootstrap" $BootstrapPlatformDir
Terraform-Init-Layer "platform-services" $ServicesDir
Terraform-Init-Layer "platform-core" $CoreDir
Terraform-Init-Layer "aws" $AwsDir

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
    Warn "EKS cluster does not exist or is unreachable. Skipping Kubernetes pre-cleanup."
}

if ($ClusterExists) {
    Step "Updating kubeconfig"
    $Region = terraform "-chdir=$AwsDir" output -raw aws_region
    aws eks update-kubeconfig --name $ClusterName --region $Region
}

Terraform-Destroy-Layer "platform-dns" $DnsDir $ClusterExists $false

if ($ClusterExists) {
    Step "Deleting ArgoCD Applications"
    $deleteApps = Run-AllowFailure {
        kubectl delete applications.argoproj.io --all -n argocd --ignore-not-found=true
    }
    if ($deleteApps.ExitCode -ne 0) { Warn "Could not delete ArgoCD Applications. Continuing." }

    Step "Deleting ingresses"
    $deleteIngresses = Run-AllowFailure {
        kubectl delete ingress --all -A --ignore-not-found=true
    }
    if ($deleteIngresses.ExitCode -ne 0) { Warn "Could not delete ingresses. Continuing." }
}

Terraform-Destroy-Layer "platform-bootstrap" $BootstrapPlatformDir $ClusterExists
Terraform-Destroy-Layer "platform-services" $ServicesDir $ClusterExists
Terraform-Destroy-Layer "platform-core" $CoreDir $ClusterExists

Step "Detecting VPC from AWS Terraform state"
$VpcId = $null
$vpcState = Run-AllowFailure {
    terraform "-chdir=$AwsDir" state show "module.eks_foundation.module.vpc.aws_vpc.this[0]"
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
        if ($lbCheck.ExitCode -ne 0) { return $true }
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
        if ($eniCheck.ExitCode -ne 0) { return $true }
        $enis = ($eniCheck.Output | Out-String).Trim()
        return [string]::IsNullOrWhiteSpace($enis)
    } 600 20
}
else {
    Warn "Could not detect VPC ID from Terraform state. Skipping ALB/ENI wait."
}

Step "Destroying AWS layer"
terraform "-chdir=$AwsDir" destroy -auto-approve

Write-Host ""
Write-Host "Destroy complete." -ForegroundColor Green