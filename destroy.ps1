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

    return @{
        Output   = $output
        ExitCode = $exitCode
    }
}

function Wait-Until(
    $Description,
    [scriptblock]$Check,
    $TimeoutSeconds = 600,
    $SleepSeconds = 15,
    [bool]$ThrowOnTimeout = $true
) {
    Step "Waiting for $Description"

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (& $Check) {
            Write-Host "$Description complete."
            return $true
        }

        Start-Sleep -Seconds $SleepSeconds
        $elapsed += $SleepSeconds
        Write-Host "Still waiting for $Description... ${elapsed}s elapsed"
    }

    if ($ThrowOnTimeout) {
        throw "Timed out waiting for $Description"
    }

    Warn "Timed out waiting for $Description"
    return $false
}

function Invoke-KubectlMergePatch {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$KubectlArgs,

        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    # PowerShell/native-command quoting can corrupt inline JSON passed with
    # kubectl -p. Always use a temporary patch file instead.
    $patchFile = Join-Path $env:TEMP ("kubectl-patch-{0}.json" -f ([guid]::NewGuid().ToString("N")))

    try {
        [System.IO.File]::WriteAllText(
            $patchFile,
            $Json,
            [System.Text.Encoding]::ASCII
        )

        & kubectl @KubectlArgs --type=merge --patch-file $patchFile
    }
    finally {
        Remove-Item $patchFile -ErrorAction SilentlyContinue
    }
}

function Force-Finalize-Namespace($Namespace) {
    Warn "Force-finalizing namespace '$Namespace' because the cluster is being destroyed."

    $namespaceResult = Run-AllowFailure {
        kubectl get namespace $Namespace -o json
    }

    if ($namespaceResult.ExitCode -ne 0) {
        Write-Host "Namespace '$Namespace' is already gone."
        return
    }

    $namespaceObject = ($namespaceResult.Output | Out-String) | ConvertFrom-Json
    $namespaceObject.spec.finalizers = @()

    $finalizeFile = Join-Path $env:TEMP ("namespace-finalize-{0}.json" -f ([guid]::NewGuid().ToString("N")))

    try {
        $json = $namespaceObject | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText(
            $finalizeFile,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )

        $result = Run-AllowFailure {
            kubectl replace `
                --raw "/api/v1/namespaces/$Namespace/finalize" `
                -f $finalizeFile
        }

        if ($result.ExitCode -ne 0) {
            Write-Host ($result.Output | Out-String)
            Warn "Could not force-finalize namespace '$Namespace'."
        }
    }
    finally {
        Remove-Item $finalizeFile -ErrorAction SilentlyContinue
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

function Disable-ApplicationAutoSync {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [string]$Namespace = "argocd",

        [bool]$Required = $false
    )

    $appCheck = Run-AllowFailure {
        kubectl get application $AppName -n $Namespace -o json
    }

    if ($appCheck.ExitCode -ne 0) {
        Write-Host "Application '$AppName' not found. No auto-sync policy to disable."
        return $false
    }

    # Older Argo CD CRDs do not support spec.syncPolicy.automated.enabled.
    # Removing the entire automated block works across old and new CRDs.
    $patch = Run-AllowFailure {
        Invoke-KubectlMergePatch `
            -KubectlArgs @("patch", "application", $AppName, "-n", $Namespace) `
            -Json '{"spec":{"syncPolicy":{"automated":null}}}'
    }

    if ($patch.ExitCode -ne 0) {
        Write-Host ($patch.Output | Out-String)

        if ($Required) {
            throw "Failed to disable auto-sync for Application '$AppName'."
        }

        Warn "Could not disable auto-sync for Application '$AppName'."
        return $false
    }

    $verify = Run-AllowFailure {
        kubectl get application $AppName -n $Namespace -o json
    }

    if ($verify.ExitCode -ne 0) {
        if ($Required) {
            throw "Could not verify Application '$AppName' after disabling auto-sync."
        }

        return $false
    }

    $application = ($verify.Output | Out-String) | ConvertFrom-Json

    if ($null -ne $application.spec.syncPolicy.automated) {
        if ($Required) {
            throw "Application '$AppName' still has spec.syncPolicy.automated configured."
        }

        Warn "Application '$AppName' still has spec.syncPolicy.automated configured."
        return $false
    }

    Write-Host "Application '$AppName' auto-sync disabled."
    return $true
}

function Suspend-PlatformRootAutoSync {
    Step "Suspending platform-root auto-sync"

    $disabled = Disable-ApplicationAutoSync `
        -AppName "platform-root" `
        -Namespace "argocd" `
        -Required $true

    if (-not $disabled) {
        return
    }

    # If a sync was already running before we removed automated sync, allow
    # it a short window to finish before deleting child Applications.
    $null = Wait-Until "any in-progress platform-root sync to finish" {
        $current = Run-AllowFailure {
            kubectl get application platform-root -n argocd -o json
        }

        if ($current.ExitCode -ne 0) {
            return $true
        }

        $app = ($current.Output | Out-String) | ConvertFrom-Json
        return $app.status.operationState.phase -ne "Running"
    } 60 5 $false

    # Re-check after the operation wait to close the race where an already
    # running sync restores the Application spec after the first patch.
    $finalVerify = Run-AllowFailure {
        kubectl get application platform-root -n argocd -o json
    }

    if ($finalVerify.ExitCode -eq 0) {
        $root = ($finalVerify.Output | Out-String) | ConvertFrom-Json

        if ($null -ne $root.spec.syncPolicy.automated) {
            throw "platform-root auto-sync was restored while a sync operation was finishing. Refusing to continue."
        }
    }
}

function Set-ApplicationDeletionMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [string]$Namespace = "argocd",

        [ValidateSet("Foreground", "Background", "NonCascade")]
        [string]$Mode = "Background"
    )

    if ($Mode -eq "Foreground") {
        return
    }

    $appResult = Run-AllowFailure {
        kubectl get application $AppName -n $Namespace -o json
    }

    if ($appResult.ExitCode -ne 0) {
        return
    }

    $app = ($appResult.Output | Out-String) | ConvertFrom-Json
    $existingFinalizers = @($app.metadata.finalizers)

    $nonArgoFinalizers = @(
        $existingFinalizers |
            Where-Object {
                $_ -and
                $_ -notlike "resources-finalizer.argocd.argoproj.io*"
            }
    )

    $newFinalizers = @($nonArgoFinalizers)

    if ($Mode -eq "Background") {
        $newFinalizers += "resources-finalizer.argocd.argoproj.io/background"
    }

    $patchObject = @{
        metadata = @{
            finalizers = $newFinalizers
        }
    }

    $patchJson = $patchObject | ConvertTo-Json -Depth 10 -Compress

    $patch = Run-AllowFailure {
        Invoke-KubectlMergePatch `
            -KubectlArgs @("patch", "application", $AppName, "-n", $Namespace) `
            -Json $patchJson
    }

    if ($patch.ExitCode -ne 0) {
        Warn "Could not set deletion mode '$Mode' for Application '$AppName'."
        Write-Host ($patch.Output | Out-String)
    }
}

function Delete-Application-And-WaitOrForce {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [string]$Namespace = "argocd",

        [int]$TimeoutSeconds = 120,

        [int]$SleepSeconds = 10,

        [ValidateSet("Foreground", "Background", "NonCascade")]
        [string]$Mode = "Background"
    )

    Step "Deleting ArgoCD Application '$AppName'"

    $exists = Run-AllowFailure {
        kubectl get application $AppName -n $Namespace
    }

    if ($exists.ExitCode -ne 0) {
        Write-Host "Application '$AppName' not found. Nothing to do."
        return
    }

    # Background keeps Argo CD's cascading cleanup but avoids waiting for
    # every managed resource before the Application object can disappear.
    # NonCascade is used only when the workload has already been explicitly
    # uninstalled (for example, Longhorn).
    Set-ApplicationDeletionMode `
        -AppName $AppName `
        -Namespace $Namespace `
        -Mode $Mode

    $delete = Run-AllowFailure {
        kubectl delete application $AppName `
            -n $Namespace `
            --ignore-not-found=true `
            --wait=false
    }

    if ($delete.ExitCode -ne 0) {
        Warn "Could not request deletion of Application '$AppName'."
        Write-Host ($delete.Output | Out-String)
    }

    $deleted = Wait-Until "Application '$AppName' to disappear" {
        $check = Run-AllowFailure {
            kubectl get application $AppName -n $Namespace
        }

        return $check.ExitCode -ne 0
    } $TimeoutSeconds $SleepSeconds $false

    if ($deleted) {
        return
    }

    Warn "Application '$AppName' is still blocked. Removing all remaining finalizers as a last-resort teardown fallback."

    $patch = Run-AllowFailure {
        Invoke-KubectlMergePatch `
            -KubectlArgs @("patch", "application", $AppName, "-n", $Namespace) `
            -Json '{"metadata":{"finalizers":[]}}'
    }

    if ($patch.ExitCode -ne 0) {
        Warn "Could not remove finalizers from Application '$AppName'."
        Write-Host ($patch.Output | Out-String)
    }

    $null = Run-AllowFailure {
        kubectl delete application $AppName `
            -n $Namespace `
            --ignore-not-found=true `
            --wait=false
    }

    $null = Wait-Until "Application '$AppName' to disappear after finalizer removal" {
        $check = Run-AllowFailure {
            kubectl get application $AppName -n $Namespace
        }

        return $check.ExitCode -ne 0
    } 30 5 $false
}

function Get-LonghornVersion {
    $manager = Run-AllowFailure {
        kubectl get daemonset longhorn-manager `
            -n longhorn-system `
            -o jsonpath='{.spec.template.spec.containers[0].image}'
    }

    if ($manager.ExitCode -eq 0) {
        $image = ($manager.Output | Out-String).Trim()

        if ($image -match ':(v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?)$') {
            $version = $Matches[1]
            if ($version -notmatch '^v') {
                $version = "v$version"
            }
            return $version
        }
    }

    $setting = Run-AllowFailure {
        kubectl get setting.longhorn.io current-longhorn-version `
            -n longhorn-system `
            -o jsonpath='{.value}'
    }

    if ($setting.ExitCode -eq 0) {
        $version = ($setting.Output | Out-String).Trim()

        if ($version -match '^[v]?[0-9]+\.[0-9]+\.[0-9]+') {
            if ($version -notmatch '^v') {
                $version = "v$version"
            }
            return $version
        }
    }

    $app = Run-AllowFailure {
        kubectl get application longhorn `
            -n argocd `
            -o jsonpath='{.spec.source.targetRevision}'
    }

    if ($app.ExitCode -eq 0) {
        $version = ($app.Output | Out-String).Trim()

        if ($version -match '^[v]?[0-9]+\.[0-9]+\.[0-9]+') {
            if ($version -notmatch '^v') {
                $version = "v$version"
            }
            return $version
        }
    }

    throw "Could not determine the installed Longhorn version."
}

function Get-RemainingLonghornRuntimeObjects {
    $resourcesResult = Run-AllowFailure {
        kubectl api-resources `
            --api-group=longhorn.io `
            --verbs=list `
            --namespaced=true `
            -o name
    }

    if ($resourcesResult.ExitCode -ne 0) {
        $crds = Run-AllowFailure {
            kubectl get crd -o name | Select-String "longhorn.io"
        }

        if (
            $crds.ExitCode -ne 0 -or
            [string]::IsNullOrWhiteSpace(($crds.Output | Out-String).Trim())
        ) {
            return @()
        }

        return @("Longhorn API discovery failed while Longhorn CRDs still exist")
    }

    $remaining = @()

    foreach ($resourceLine in @($resourcesResult.Output)) {
        $resource = "$resourceLine".Trim()

        if (
            [string]::IsNullOrWhiteSpace($resource) -or
            $resource -eq "settings.longhorn.io"
        ) {
            continue
        }

        $objects = Run-AllowFailure {
            kubectl get $resource `
                -n longhorn-system `
                --ignore-not-found `
                -o name
        }

        if (
            $objects.ExitCode -eq 0 -and
            -not [string]::IsNullOrWhiteSpace(($objects.Output | Out-String).Trim())
        ) {
            foreach ($object in @($objects.Output)) {
                $name = "$object".Trim()
                if ($name) {
                    $remaining += $name
                }
            }
        }
    }

    return $remaining
}

function Remove-LonghornLeftovers {
    Step "Verifying no leftover Longhorn CRDs/webhooks"

    # Remove webhook registrations before force-cleaning CRs. A partial
    # Longhorn uninstall can remove the webhook Service first, causing
    # subsequent CR deletion requests to fail against a dead webhook.
    $leftoverWebhooks = Run-AllowFailure {
        @(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name) |
            Select-String "longhorn"
    }

    if (
        $leftoverWebhooks.ExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace(($leftoverWebhooks.Output | Out-String).Trim())
    ) {
        Warn "Longhorn webhook configurations still present. Deleting them."

        foreach ($webhook in @($leftoverWebhooks.Output)) {
            $webhookName = "$webhook".Trim()

            if ($webhookName) {
                $null = Run-AllowFailure {
                    kubectl delete $webhookName `
                        --ignore-not-found=true `
                        --wait=false
                }
            }
        }
    }

    $leftoverCrds = Run-AllowFailure {
        kubectl get crd -o name | Select-String "longhorn.io"
    }

    if (
        $leftoverCrds.ExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace(($leftoverCrds.Output | Out-String).Trim())
    ) {
        Warn "Longhorn CRDs remain after the supported uninstall. Cleaning them because the entire cluster is being destroyed."

        foreach ($crd in @($leftoverCrds.Output)) {
            $crdName = "$crd".Trim()

            if (-not $crdName) {
                continue
            }

            $resourceName = ($crdName -split "/", 2)[-1]

            $instances = Run-AllowFailure {
                kubectl get $resourceName `
                    -n longhorn-system `
                    --ignore-not-found `
                    -o name
            }

            if ($instances.ExitCode -eq 0) {
                foreach ($instance in @($instances.Output)) {
                    $instanceName = "$instance".Trim()

                    if (-not $instanceName) {
                        continue
                    }

                    $null = Run-AllowFailure {
                        Invoke-KubectlMergePatch `
                            -KubectlArgs @("patch", $instanceName, "-n", "longhorn-system") `
                            -Json '{"metadata":{"finalizers":[]}}'
                    }

                    $null = Run-AllowFailure {
                        kubectl delete $instanceName `
                            -n longhorn-system `
                            --ignore-not-found=true `
                            --wait=false
                    }
                }
            }

            $null = Run-AllowFailure {
                kubectl delete $crdName `
                    --ignore-not-found=true `
                    --wait=false
            }
        }
    }
}

function Uninstall-Longhorn {
    Step "Uninstalling Longhorn"

    $nsCheck = Run-AllowFailure {
        kubectl get namespace longhorn-system
    }

    if ($nsCheck.ExitCode -ne 0) {
        Write-Host "longhorn-system namespace not found."

        # The Application can still exist as Missing/OutOfSync after a
        # previous partial teardown. Remove it non-cascading so platform-root
        # cannot leave a stale child Application behind.
        Delete-Application-And-WaitOrForce `
            -AppName "longhorn" `
            -Namespace "argocd" `
            -TimeoutSeconds 30 `
            -SleepSeconds 5 `
            -Mode "NonCascade"

        return
    }

    $longhornCrds = Run-AllowFailure {
        kubectl get crd -o name | Select-String "longhorn.io"
    }

    $longhornWorkloads = Run-AllowFailure {
        kubectl get all -n longhorn-system --no-headers
    }

    if (
        (
            $longhornCrds.ExitCode -ne 0 -or
            [string]::IsNullOrWhiteSpace(($longhornCrds.Output | Out-String).Trim())
        ) -and
        (
            $longhornWorkloads.ExitCode -ne 0 -or
            [string]::IsNullOrWhiteSpace(($longhornWorkloads.Output | Out-String).Trim())
        )
    ) {
        Warn "longhorn-system exists, but Longhorn CRDs and workloads are already gone. Finishing partial teardown."

        Delete-Application-And-WaitOrForce `
            -AppName "longhorn" `
            -Namespace "argocd" `
            -TimeoutSeconds 30 `
            -SleepSeconds 5 `
            -Mode "NonCascade"

        $null = Run-AllowFailure {
            kubectl delete namespace longhorn-system `
                --ignore-not-found=true `
                --wait=false
        }

        $null = Wait-Until "longhorn-system namespace to disappear" {
            $ns = Run-AllowFailure {
                kubectl get namespace longhorn-system
            }

            return $ns.ExitCode -ne 0
        } 60 5 $false

        return
    }

    $version = Get-LonghornVersion
    Write-Host "Detected Longhorn version: $version"

    # The parent app-of-apps is already suspended, but the existing Longhorn
    # child Application can have its own selfHeal/automated policy. Disable
    # it before the kubectl uninstall job starts removing Longhorn resources.
    $longhornApp = Run-AllowFailure {
        kubectl get application longhorn -n argocd
    }

    if ($longhornApp.ExitCode -eq 0) {
        $null = Disable-ApplicationAutoSync `
            -AppName "longhorn" `
            -Namespace "argocd" `
            -Required $true
    }

    Step "Deleting Longhorn-backed PVCs"

    $pvcQuery = Run-AllowFailure {
        kubectl get pvc -A -o json
    }

    if ($pvcQuery.ExitCode -eq 0) {
        $pvcDocument = ($pvcQuery.Output | Out-String) | ConvertFrom-Json
        $longhornPvcs = @(
            $pvcDocument.items |
                Where-Object {
                    $_.spec.storageClassName -eq "longhorn"
                }
        )

        if ($longhornPvcs.Count -gt 0) {
            foreach ($pvc in $longhornPvcs) {
                $ns = $pvc.metadata.namespace
                $name = $pvc.metadata.name

                Write-Host "Deleting PVC $ns/$name (storageClassName: longhorn)"

                $null = Run-AllowFailure {
                    kubectl delete pvc $name `
                        -n $ns `
                        --ignore-not-found=true `
                        --wait=false
                }
            }

            Wait-Until "Longhorn-backed PVCs to finish deleting" {
                $remainingQuery = Run-AllowFailure {
                    kubectl get pvc -A -o json
                }

                if ($remainingQuery.ExitCode -ne 0) {
                    return $false
                }

                $remainingDocument = ($remainingQuery.Output | Out-String) | ConvertFrom-Json
                $remainingPvcs = @(
                    $remainingDocument.items |
                        Where-Object {
                            $_.spec.storageClassName -eq "longhorn"
                        }
                )

                return $remainingPvcs.Count -eq 0
            } 300 10
        }
        else {
            Write-Host "No Longhorn-backed PVCs found."
        }
    }
    else {
        throw "Could not query PVCs before Longhorn uninstall."
    }

    Step "Setting and verifying Longhorn's deleting-confirmation-flag"

    $flagPatch = Run-AllowFailure {
        Invoke-KubectlMergePatch `
            -KubectlArgs @(
                "patch",
                "setting.longhorn.io",
                "deleting-confirmation-flag",
                "-n",
                "longhorn-system"
            ) `
            -Json '{"value":"true"}'
    }

    if ($flagPatch.ExitCode -ne 0) {
        Write-Host ($flagPatch.Output | Out-String)
        throw "Could not set Longhorn deleting-confirmation-flag."
    }

    $flag = Run-AllowFailure {
        kubectl get setting.longhorn.io deleting-confirmation-flag `
            -n longhorn-system `
            -o jsonpath='{.value}'
    }

    if (
        $flag.ExitCode -ne 0 -or
        (($flag.Output | Out-String).Trim() -ne "true")
    ) {
        throw "Longhorn deleting-confirmation-flag was not verified as true."
    }

    Write-Host "Longhorn deleting-confirmation-flag verified true."

    $uninstallUrl = "https://raw.githubusercontent.com/longhorn/longhorn/$version/uninstall/uninstall.yaml"
    $deployUrl = "https://raw.githubusercontent.com/longhorn/longhorn/$version/deploy/longhorn.yaml"

    Step "Running Longhorn's supported uninstall job"

    # Remove stale uninstall-job RBAC/Job objects from an earlier interrupted
    # attempt before creating a fresh uninstall job.
    $null = Run-AllowFailure {
        kubectl delete -f $uninstallUrl `
            --ignore-not-found=true `
            --wait=false
    }

    $null = Wait-Until "any previous Longhorn uninstall job to disappear" {
        $job = Run-AllowFailure {
            kubectl get job longhorn-uninstall -n longhorn-system
        }

        return $job.ExitCode -ne 0
    } 60 5 $false

    $createJob = Run-AllowFailure {
        kubectl create -f $uninstallUrl
    }

    if ($createJob.ExitCode -ne 0) {
        Write-Host ($createJob.Output | Out-String)
        throw "Failed to create Longhorn uninstall job for $version."
    }

    $jobCompleted = $false
    $jobEverSeen = $false
    $elapsed = 0
    $timeoutSeconds = 600
    $sleepSeconds = 10

    while ($elapsed -lt $timeoutSeconds) {
        $jobResult = Run-AllowFailure {
            kubectl get job longhorn-uninstall `
                -n longhorn-system `
                -o json
        }

        if ($jobResult.ExitCode -eq 0) {
            $jobEverSeen = $true
            $job = ($jobResult.Output | Out-String) | ConvertFrom-Json

            if ($job.status.succeeded -ge 1) {
                Write-Host "Longhorn uninstall job completed."
                $jobCompleted = $true
                break
            }

            $failedCondition = @(
                $job.status.conditions |
                    Where-Object {
                        $_.type -eq "Failed" -and
                        $_.status -eq "True"
                    }
            )

            if ($failedCondition.Count -gt 0) {
                $logs = Run-AllowFailure {
                    kubectl logs `
                        -n longhorn-system `
                        job/longhorn-uninstall `
                        --tail=200
                }

                Write-Host ($logs.Output | Out-String)
                throw "Longhorn uninstall job failed."
            }
        }
        elseif ($jobEverSeen) {
            # We observed this with Longhorn v1.12.0: the Job can disappear
            # while teardown has already removed the manager/runtime CRs.
            # Validate actual Longhorn state instead of blindly timing out.
            Warn "Longhorn uninstall job disappeared before a Complete condition was observed. Validating remaining Longhorn runtime objects."
            break
        }

        Start-Sleep -Seconds $sleepSeconds
        $elapsed += $sleepSeconds
        Write-Host "Still waiting for Longhorn uninstall job... ${elapsed}s elapsed"
    }

    $remainingRuntimeObjects = @(Get-RemainingLonghornRuntimeObjects)

    if (
        -not $jobCompleted -and
        $remainingRuntimeObjects.Count -gt 0
    ) {
        $logs = Run-AllowFailure {
            kubectl logs `
                -n longhorn-system `
                job/longhorn-uninstall `
                --tail=200
        }

        if ($logs.ExitCode -eq 0) {
            Write-Host ($logs.Output | Out-String)
        }

        Write-Host "Remaining Longhorn runtime objects:"
        $remainingRuntimeObjects | ForEach-Object {
            Write-Host "  $_"
        }

        throw "Longhorn uninstall did not complete cleanly and runtime objects remain."
    }

    if (-not $jobCompleted) {
        Warn "The uninstall Job did not report Complete, but no Longhorn runtime CRs remain. Continuing with Longhorn's documented remaining-component cleanup."
    }

    Step "Deleting remaining Longhorn components"

    $deleteDeploy = Run-AllowFailure {
        kubectl delete -f $deployUrl `
            --ignore-not-found=true `
            --wait=false
    }

    if ($deleteDeploy.ExitCode -ne 0) {
        Warn "Deleting Longhorn deployment manifest returned an error. Leftover cleanup will handle any remaining resources."
        Write-Host ($deleteDeploy.Output | Out-String)
    }

    $null = Run-AllowFailure {
        kubectl delete -f $uninstallUrl `
            --ignore-not-found=true `
            --wait=false
    }

    # Longhorn has already been explicitly uninstalled. Deleting the Argo
    # Application non-cascading avoids a second, unsupported Argo-driven
    # Longhorn deletion pass.
    Delete-Application-And-WaitOrForce `
        -AppName "longhorn" `
        -Namespace "argocd" `
        -TimeoutSeconds 60 `
        -SleepSeconds 5 `
        -Mode "NonCascade"

    $null = Wait-Until "Longhorn CRDs to disappear" {
        $crds = Run-AllowFailure {
            kubectl get crd -o name | Select-String "longhorn.io"
        }

        return (
            $crds.ExitCode -ne 0 -or
            [string]::IsNullOrWhiteSpace(($crds.Output | Out-String).Trim())
        )
    } 90 5 $false

    Remove-LonghornLeftovers

    $nsStillThere = Run-AllowFailure {
        kubectl get namespace longhorn-system
    }

    if ($nsStillThere.ExitCode -eq 0) {
        Step "Deleting longhorn-system namespace"

        $null = Run-AllowFailure {
            kubectl delete namespace longhorn-system `
                --ignore-not-found=true `
                --wait=false
        }

        $namespaceDeleted = Wait-Until "longhorn-system namespace to disappear" {
            $ns = Run-AllowFailure {
                kubectl get namespace longhorn-system
            }

            return $ns.ExitCode -ne 0
        } 120 5 $false

        if (-not $namespaceDeleted) {
            Force-Finalize-Namespace "longhorn-system"
        }
    }

    $finalAppCheck = Run-AllowFailure {
        kubectl get application longhorn -n argocd
    }

    if ($finalAppCheck.ExitCode -eq 0) {
        throw "Longhorn Application was recreated during teardown. platform-root or another reconciler is still managing it."
    }

    $finalNamespaceCheck = Run-AllowFailure {
        kubectl get namespace longhorn-system
    }

    if ($finalNamespaceCheck.ExitCode -eq 0) {
        throw "longhorn-system namespace still exists after Longhorn cleanup."
    }

    Write-Host "Longhorn uninstall complete."
}

function Remove-RancherClusterScopedLeftovers {
    Step "Cleaning Rancher aggregated APIs, webhooks, and CRDs"

    # Rancher's imperative API extension can become unavailable while
    # cattle-system is being removed. A stale v1.ext.cattle.io APIService
    # causes Kubernetes namespace discovery failures, so remove it
    # proactively during a full Rancher teardown.
    $null = Run-AllowFailure {
        kubectl delete apiservice v1.ext.cattle.io `
            --ignore-not-found=true `
            --wait=false
    }

    $leftoverWebhooks = Run-AllowFailure {
        @(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name) |
            Select-String -Pattern "rancher|cattle"
    }

    if (
        $leftoverWebhooks.ExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace(($leftoverWebhooks.Output | Out-String).Trim())
    ) {
        foreach ($webhook in @($leftoverWebhooks.Output)) {
            $webhookName = "$webhook".Trim()

            if ($webhookName) {
                Write-Host "Deleting Rancher webhook $webhookName"

                $null = Run-AllowFailure {
                    kubectl delete $webhookName `
                        --ignore-not-found=true `
                        --wait=false
                }
            }
        }
    }

    $leftoverCrds = Run-AllowFailure {
        kubectl get crd -o name | Select-String "cattle.io"
    }

    if (
        $leftoverCrds.ExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace(($leftoverCrds.Output | Out-String).Trim())
    ) {
        Warn "Rancher cattle.io CRDs remain. Requesting deletion because the entire cluster is being destroyed."

        foreach ($crd in @($leftoverCrds.Output)) {
            $crdName = "$crd".Trim()

            if ($crdName) {
                $null = Run-AllowFailure {
                    kubectl delete $crdName `
                        --ignore-not-found=true `
                        --wait=false
                }
            }
        }
    }
}

function Uninstall-Rancher {
    Step "Uninstalling Rancher"

    $nsCheck = Run-AllowFailure {
        kubectl get namespace cattle-system
    }

    $appCheck = Run-AllowFailure {
        kubectl get application rancher -n argocd
    }

    if (
        $nsCheck.ExitCode -ne 0 -and
        $appCheck.ExitCode -ne 0
    ) {
        Write-Host "Rancher Application and cattle-system namespace are both absent. Skipping Rancher uninstall."
        return
    }

    if ($appCheck.ExitCode -eq 0) {
        # Use Argo CD's background cascading finalizer. This still requests
        # deletion of Rancher's managed resources, but avoids blocking the
        # Application object on every resource finalizer.
        Delete-Application-And-WaitOrForce `
            -AppName "rancher" `
            -Namespace "argocd" `
            -TimeoutSeconds 90 `
            -SleepSeconds 5 `
            -Mode "Background"
    }

    Remove-RancherClusterScopedLeftovers

    $nsStillThere = Run-AllowFailure {
        kubectl get namespace cattle-system
    }

    if ($nsStillThere.ExitCode -eq 0) {
        Step "Deleting cattle-system namespace"

        $null = Run-AllowFailure {
            kubectl delete namespace cattle-system `
                --ignore-not-found=true `
                --wait=false
        }

        $namespaceDeleted = Wait-Until "cattle-system namespace to disappear" {
            $ns = Run-AllowFailure {
                kubectl get namespace cattle-system
            }

            return $ns.ExitCode -ne 0
        } 180 5 $false

        if (-not $namespaceDeleted) {
            $conditions = Run-AllowFailure {
                $namespace = kubectl get namespace cattle-system -o json |
                    ConvertFrom-Json

                $namespace.status.conditions |
                    Format-Table type, status, reason, message -Wrap
            }

            if ($conditions.ExitCode -eq 0) {
                Write-Host ($conditions.Output | Out-String)
            }

            # Retry APIService deletion in case Rancher recreated it during
            # its final shutdown sequence.
            $null = Run-AllowFailure {
                kubectl delete apiservice v1.ext.cattle.io `
                    --ignore-not-found=true `
                    --wait=false
            }

            Force-Finalize-Namespace "cattle-system"

            $null = Wait-Until "cattle-system namespace to disappear after finalization" {
                $ns = Run-AllowFailure {
                    kubectl get namespace cattle-system
                }

                return $ns.ExitCode -ne 0
            } 60 5 $false
        }
    }

    # A background cascade can delete/recreate Rancher webhooks while the
    # namespace is terminating, so run cluster-scoped cleanup once more.
    Remove-RancherClusterScopedLeftovers

    $finalAppCheck = Run-AllowFailure {
        kubectl get application rancher -n argocd
    }

    if ($finalAppCheck.ExitCode -eq 0) {
        throw "Rancher Application was recreated during teardown. platform-root or another reconciler is still managing it."
    }

    $finalNamespaceCheck = Run-AllowFailure {
        kubectl get namespace cattle-system
    }

    if ($finalNamespaceCheck.ExitCode -eq 0) {
        throw "cattle-system namespace still exists after Rancher cleanup."
    }

    Write-Host "Rancher uninstall complete."
}

function Prepare-RemainingApplicationsForBackgroundDeletion {
    Step "Preparing remaining ArgoCD Applications for background cascading deletion"

    $applications = Run-AllowFailure {
        kubectl get applications.argoproj.io `
            -n argocd `
            -o json
    }

    if ($applications.ExitCode -ne 0) {
        Warn "Could not list ArgoCD Applications."
        return
    }

    $document = ($applications.Output | Out-String) | ConvertFrom-Json

    foreach ($application in @($document.items)) {
        $name = $application.metadata.name

        if (-not $name) {
            continue
        }

        Set-ApplicationDeletionMode `
            -AppName $name `
            -Namespace "argocd" `
            -Mode "Background"
    }
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

# Read config from backend.hcl to avoid any hardcoded values.
if (-not (Test-Path $BackendConfig)) {
    throw "Backend config not found: $BackendConfig"
}

$StateBucket = (
    Get-Content $BackendConfig |
        Select-String 'bucket\s*=\s*"(.+)"'
).Matches[0].Groups[1].Value

$ClusterName = (
    terraform "-chdir=$AwsDir" output -raw cluster_name 2>$null
)

if (-not $ClusterName) {
    $ClusterName = (
        Get-Content "$AwsDir/terraform.tfvars" |
            Select-String 'name\s*=\s*"(.+)"'
    ).Matches[0].Groups[1].Value
}

Step "Validating AWS identity"

$CallerArn = aws sts get-caller-identity --query Arn --output text
Write-Host "AWS identity: $CallerArn"

if ($CallerArn -notlike "*$ExpectedArnFragment*") {
    throw "Refusing to destroy. Expected AWS identity containing '$ExpectedArnFragment', but got '$CallerArn'."
}

foreach ($dir in @($AwsDir, $PlatformDir)) {
    if (-not (Test-Path $dir)) {
        throw "Required Terraform directory not found: $dir"
    }
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

if (
    $ClusterCheck.ExitCode -eq 0 -and
    -not [string]::IsNullOrWhiteSpace(($ClusterCheck.Output | Out-String).Trim())
) {
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
    aws eks update-kubeconfig `
        --name $ClusterName `
        --region $Region

    # This is a hard safety gate. If platform-root can still auto-sync,
    # deleting a child Application simply causes it to be recreated.
    Suspend-PlatformRootAutoSync

    # Longhorn must use its own kubectl uninstall job because Argo CD does
    # not execute Longhorn's required PreDelete hook.
    Uninstall-Longhorn

    # Rancher is deleted with a background Argo cascade, followed by
    # explicit cleanup for the ext.cattle.io aggregated API and namespace.
    Uninstall-Rancher

    # For the remaining apps, preserve cascading cleanup but switch the
    # Argo finalizer to background so one stuck resource does not hold the
    # Application object forever.
    Prepare-RemainingApplicationsForBackgroundDeletion

    Step "Deleting remaining ArgoCD Applications"

    $deleteApps = Run-AllowFailure {
        kubectl delete applications.argoproj.io `
            --all `
            -n argocd `
            --ignore-not-found=true `
            --wait=false
    }

    if ($deleteApps.ExitCode -ne 0) {
        Warn "Could not request deletion of ArgoCD Applications."
        Write-Host ($deleteApps.Output | Out-String)
    }

    $appsDeletedNormally = Wait-Until "remaining ArgoCD Applications to disappear" {
        $remainingApps = Run-AllowFailure {
            kubectl get applications.argoproj.io `
                -n argocd `
                --no-headers
        }

        $remainingOutput = ($remainingApps.Output | Out-String).Trim()

        return (
            $remainingApps.ExitCode -ne 0 -or
            [string]::IsNullOrWhiteSpace($remainingOutput)
        )
    } 180 10 $false

    if (-not $appsDeletedNormally) {
        Warn "ArgoCD Applications are still blocked. Removing finalizers because the entire cluster is being destroyed."

        $remainingApplicationNames = Run-AllowFailure {
            kubectl get applications.argoproj.io `
                -n argocd `
                -o name
        }

        if ($remainingApplicationNames.ExitCode -eq 0) {
            foreach ($application in @($remainingApplicationNames.Output)) {
                $applicationName = "$application".Trim()

                if ([string]::IsNullOrWhiteSpace($applicationName)) {
                    continue
                }

                Write-Host "Removing finalizers from $applicationName"

                $patchResult = Run-AllowFailure {
                    Invoke-KubectlMergePatch `
                        -KubectlArgs @("patch", $applicationName, "-n", "argocd") `
                        -Json '{"metadata":{"finalizers":[]}}'
                }

                if ($patchResult.ExitCode -ne 0) {
                    Warn "Could not remove finalizers from $applicationName"
                    Write-Host ($patchResult.Output | Out-String)
                }
            }
        }
    }

    Step "Deleting ingresses"

    $deleteIngresses = Run-AllowFailure {
        kubectl delete ingress `
            --all `
            -A `
            --ignore-not-found=true `
            --wait=false
    }

    if ($deleteIngresses.ExitCode -ne 0) {
        Warn "Could not delete ingresses. Continuing."
    }
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
        ForEach-Object {
            ($_ -split '=')[1].Trim().Trim('"')
        } |
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

Step "Destroying AWS layer"

terraform "-chdir=$AwsDir" destroy -auto-approve

Write-Host ""
Write-Host "Destroy complete." -ForegroundColor Green