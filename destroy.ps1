param(
    [string]$Environment = "dev"
)

$env:AWS_PROFILE = "terraform"
Write-Host "Using AWS profile: $env:AWS_PROFILE"
aws sts get-caller-identity

$ErrorActionPreference = "Stop"

$ExpectedArnFragment = "user/darren-iam"
$AwsDir              = "infra/terraform/environments/$Environment/aws"
$PlatformDir         = "infra/terraform/environments/$Environment/platform"
$BackendConfig       = "infra/terraform/environments/$Environment/backend.hcl"
$BackendConfigAbs    = (Resolve-Path $BackendConfig).Path

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

function Delete-Application-And-WaitOrForce($AppName, $Namespace, $TimeoutSeconds = 300, $SleepSeconds = 10) {
    # Deletes a single ArgoCD Application (not --all) and waits for it to
    # actually disappear. If it's still blocked after the timeout, strips
    # finalizers as a last resort -- same fallback the generic bulk-delete
    # path already used, just scoped to one app instead of everything.
    Step "Deleting ArgoCD Application '$AppName'"

    $exists = Run-AllowFailure { kubectl get application $AppName -n $Namespace }
    if ($exists.ExitCode -ne 0) {
        Write-Host "Application '$AppName' not found. Nothing to do."
        return
    }

    $null = Run-AllowFailure {
        kubectl delete application $AppName -n $Namespace --ignore-not-found=true --wait=false
    }

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $check = Run-AllowFailure { kubectl get application $AppName -n $Namespace }
        if ($check.ExitCode -ne 0) {
            Write-Host "Application '$AppName' deleted."
            return
        }
        Start-Sleep -Seconds $SleepSeconds
        $elapsed += $SleepSeconds
        Write-Host "Still waiting for Application '$AppName'... ${elapsed}s elapsed"
    }

    Warn "Application '$AppName' is still blocked. Removing finalizers."
    $null = Run-AllowFailure {
        kubectl patch application $AppName -n $Namespace --type merge -p '{"metadata":{"finalizers":[]}}'
    }
}

function Uninstall-Longhorn {
    # Longhorn documents that it requires its own uninstall sequence and
    # will NOT clean up safely if simply deleted like an ordinary Helm
    # release: ArgoCD does not run the PreDelete hook a normal Longhorn
    # uninstall relies on, and Longhorn intentionally blocks deletion
    # behind a "deleting-confirmation-flag" setting as a safety check.
    # Skipping this sequence is exactly how you end up with orphaned
    # longhorn.io CRDs/webhooks and an API server that can't cleanly
    # tear down.
    Step "Uninstalling Longhorn"

    $nsCheck = Run-AllowFailure { kubectl get namespace longhorn-system }
    if ($nsCheck.ExitCode -ne 0) {
        Write-Host "longhorn-system namespace not found. Skipping Longhorn uninstall."
        return
    }

    Step "Deleting workloads using Longhorn-backed PVCs"
    $pvcs = Run-AllowFailure {
        kubectl get pvc -A -o json |
            ConvertFrom-Json |
            Select-Object -ExpandProperty items |
            Where-Object { $_.spec.storageClassName -eq "longhorn" }
    }
    if ($pvcs.ExitCode -eq 0 -and $pvcs.Output) {
        foreach ($pvc in $pvcs.Output) {
            $ns = $pvc.metadata.namespace
            $name = $pvc.metadata.name
            Write-Host "Deleting PVC $ns/$name (storageClassName: longhorn)"
            $null = Run-AllowFailure { kubectl delete pvc $name -n $ns --ignore-not-found=true --wait=false }
        }
        Wait-Until "Longhorn-backed PVCs to finish deleting" {
            $remaining = Run-AllowFailure {
                kubectl get pvc -A -o json |
                    ConvertFrom-Json |
                    Select-Object -ExpandProperty items |
                    Where-Object { $_.spec.storageClassName -eq "longhorn" }
            }
            return -not ($remaining.ExitCode -eq 0 -and $remaining.Output)
        } 300 10
    }
    else {
        Write-Host "No Longhorn-backed PVCs found."
    }

    Step "Setting Longhorn's deleting-confirmation-flag"
    # Longhorn refuses to let its manager tear itself down unless this is
    # explicitly set -- it's a deliberate guardrail against accidental
    # data loss, and we want it to run through its own cleanup, not skip it.
    $null = Run-AllowFailure {
        kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag `
            --type merge -p '{"value":"true"}'
    }

    Delete-Application-And-WaitOrForce "longhorn" "argocd" 300 10

    Wait-Until "longhorn-system namespace to terminate" {
        $ns = Run-AllowFailure { kubectl get namespace longhorn-system }
        return $ns.ExitCode -ne 0
    } 300 10

    Step "Verifying no leftover Longhorn CRDs/webhooks"
    $leftoverCrds = Run-AllowFailure {
        kubectl get crd -o name | Select-String "longhorn.io"
    }
    if ($leftoverCrds.ExitCode -eq 0 -and ($leftoverCrds.Output | Out-String).Trim()) {
        Warn "Longhorn CRDs still present after uninstall. Force-deleting them."
        foreach ($crd in $leftoverCrds.Output) {
            $crdName = "$crd".Trim()
            if ($crdName) {
                $null = Run-AllowFailure { kubectl delete $crdName --ignore-not-found=true }
            }
        }
    }

    $leftoverWebhooks = Run-AllowFailure {
        @(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name) |
            Select-String "longhorn"
    }
    if ($leftoverWebhooks.ExitCode -eq 0 -and ($leftoverWebhooks.Output | Out-String).Trim()) {
        Warn "Longhorn webhook configurations still present after uninstall. Force-deleting them."
        foreach ($webhook in $leftoverWebhooks.Output) {
            $webhookName = "$webhook".Trim()
            if ($webhookName) {
                $null = Run-AllowFailure { kubectl delete $webhookName --ignore-not-found=true }
            }
        }
    }

    $nsStillThere = Run-AllowFailure { kubectl get namespace longhorn-system }
    if ($nsStillThere.ExitCode -eq 0) {
        Warn "longhorn-system namespace is still present. Force-deleting it."
        $null = Run-AllowFailure { kubectl delete namespace longhorn-system --ignore-not-found=true }
    }

    Write-Host "Longhorn uninstall complete."
}

function Uninstall-Rancher {
    Step "Uninstalling Rancher"

    $nsCheck = Run-AllowFailure { kubectl get namespace cattle-system }
    if ($nsCheck.ExitCode -ne 0) {
        Write-Host "cattle-system namespace not found. Skipping Rancher uninstall."
        return
    }

    Delete-Application-And-WaitOrForce "rancher" "argocd" 300 10

    Wait-Until "cattle-system namespace to terminate" {
        $ns = Run-AllowFailure { kubectl get namespace cattle-system }
        return $ns.ExitCode -ne 0
    } 300 10

    Step "Verifying no leftover Rancher (cattle) CRDs/webhooks"
    $leftoverCrds = Run-AllowFailure {
        kubectl get crd -o name | Select-String "cattle.io"
    }
    if ($leftoverCrds.ExitCode -eq 0 -and ($leftoverCrds.Output | Out-String).Trim()) {
        Warn "Rancher (cattle.io) CRDs still present after uninstall. Force-deleting them."
        foreach ($crd in $leftoverCrds.Output) {
            $crdName = "$crd".Trim()
            if ($crdName) {
                $null = Run-AllowFailure { kubectl delete $crdName --ignore-not-found=true }
            }
        }
    }

    $leftoverWebhooks = Run-AllowFailure {
        @(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name) |
            Select-String "rancher"
    }
    if ($leftoverWebhooks.ExitCode -eq 0 -and ($leftoverWebhooks.Output | Out-String).Trim()) {
        Warn "Rancher webhook configurations still present after uninstall. Force-deleting them."
        foreach ($webhook in $leftoverWebhooks.Output) {
            $webhookName = "$webhook".Trim()
            if ($webhookName) {
                $null = Run-AllowFailure { kubectl delete $webhookName --ignore-not-found=true }
            }
        }
    }

    $nsStillThere = Run-AllowFailure { kubectl get namespace cattle-system }
    if ($nsStillThere.ExitCode -eq 0) {
        Warn "cattle-system namespace is still present. Force-deleting it."
        $null = Run-AllowFailure { kubectl delete namespace cattle-system --ignore-not-found=true }
    }

    Write-Host "Rancher uninstall complete."
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

# Read config from backend.hcl to avoid any hardcoded values.
if (-not (Test-Path $BackendConfig)) { throw "Backend config not found: $BackendConfig" }
$StateBucket = (Get-Content $BackendConfig | Select-String 'bucket\s*=\s*"(.+)"').Matches[0].Groups[1].Value
$ClusterName = (terraform "-chdir=$AwsDir" output -raw cluster_name 2>$null)
if (-not $ClusterName) {
    $ClusterName = (Get-Content "$AwsDir/terraform.tfvars" | Select-String 'name\s*=\s*"(.+)"').Matches[0].Groups[1].Value
}

Step "Validating AWS identity"
$CallerArn = aws sts get-caller-identity --query Arn --output text
Write-Host "AWS identity: $CallerArn"
if ($CallerArn -notlike "*$ExpectedArnFragment*") {
    throw "Refusing to destroy. Expected AWS identity containing '$ExpectedArnFragment', but got '$CallerArn'."
}

foreach ($dir in @($AwsDir, $PlatformDir)) {
    if (-not (Test-Path $dir)) { throw "Required Terraform directory not found: $dir" }
}

Step "Initializing Terraform layers"
foreach ($dir in @($PlatformDir, $AwsDir)) {
    terraform "-chdir=$dir" init -reconfigure "-backend-config=$BackendConfigAbs"
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
    Warn "EKS cluster does not exist or is unreachable. Skipping Kubernetes pre-cleanup."
}

if ($ClusterExists) {
    Step "Updating kubeconfig"
    $Region = terraform "-chdir=$AwsDir" output -raw aws_region
    aws eks update-kubeconfig --name $ClusterName --region $Region

    Step "Suspending platform-root auto-sync"
    # Stop ArgoCD from reconciling platform-root (and therefore
    # re-creating Longhorn/Rancher/everything else) while we tear things
    # down in a specific order below.
    $null = Run-AllowFailure {
        kubectl patch application platform-root -n argocd `
            --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
    }

    # Longhorn and Rancher each need their own uninstall handling before
    # anything else is touched -- see function comments. This must happen
    # before the generic bulk Application deletion below, or Longhorn's
    # CRDs/webhooks (and possibly Rancher's) can be left behind once the
    # EKS API server itself is gone, per Longhorn's own uninstall
    # documentation.
    Uninstall-Longhorn
    Uninstall-Rancher

    Step "Deleting remaining ArgoCD Applications"

    # Request deletion without allowing kubectl to wait forever on ArgoCD
    # resource finalizers.
    $deleteApps = Run-AllowFailure {
        kubectl delete applications.argoproj.io `
            --all `
            -n argocd `
            --ignore-not-found=true `
            --wait=false
    }

    if ($deleteApps.ExitCode -ne 0) {
        Warn "Could not request deletion of ArgoCD Applications."
    }

    # Give ArgoCD time to perform normal cascading deletion.
    $appsDeletedNormally = $false
    $elapsed = 0
    $timeoutSeconds = 300
    $sleepSeconds = 10

    while ($elapsed -lt $timeoutSeconds) {
        $remainingApps = Run-AllowFailure {
            kubectl get applications.argoproj.io `
                -n argocd `
                --no-headers
        }

        $remainingOutput = ($remainingApps.Output | Out-String).Trim()

        if (
            $remainingApps.ExitCode -ne 0 -or
            [string]::IsNullOrWhiteSpace($remainingOutput)
        ) {
            Write-Host "ArgoCD Applications deleted."
            $appsDeletedNormally = $true
            break
        }

        Start-Sleep -Seconds $sleepSeconds
        $elapsed += $sleepSeconds
        Write-Host "Still waiting for ArgoCD Applications... ${elapsed}s elapsed"
    }

    if (-not $appsDeletedNormally) {
        Warn "ArgoCD Applications are still blocked. Removing finalizers because the entire cluster is being destroyed."

        $remainingApplicationNames = Run-AllowFailure {
            kubectl get applications.argoproj.io `
                -n argocd `
                -o name
        }

        if ($remainingApplicationNames.ExitCode -eq 0) {
            foreach ($application in $remainingApplicationNames.Output) {
                $applicationName = "$application".Trim()

                if (-not [string]::IsNullOrWhiteSpace($applicationName)) {
                    Write-Host "Removing finalizers from $applicationName"

                    $patchResult = Run-AllowFailure {
                        kubectl patch $applicationName `
                            -n argocd `
                            --type merge `
                            -p '{"metadata":{"finalizers":[]}}'
                    }

                    if ($patchResult.ExitCode -ne 0) {
                        Warn "Could not remove finalizers from $applicationName"
                    }
                }
            }
        }
    }

    Step "Deleting ingresses"
    $deleteIngresses = Run-AllowFailure {
        kubectl delete ingress --all -A --ignore-not-found=true
    }
    if ($deleteIngresses.ExitCode -ne 0) { Warn "Could not delete ingresses. Continuing." }
}

# Platform destroy (refresh=false for DNS portion since ALBs may already be gone)
Terraform-Destroy-Layer "platform" $PlatformDir $ClusterExists $false

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
