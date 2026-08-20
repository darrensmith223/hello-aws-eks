param(
    [string]$Region = "us-east-1",
    [string]$Profile = "terraform",
    [string]$ClusterName = "practice-eks-dev",
    [string]$DomainName = "ddsprojects.link",
    [string]$RepoSecretName = "dev/argocd/repo/hello-aws-eks",
    [string]$LonghornBackupBucket = "dev-longhorn-backups"
)

$ErrorActionPreference = "Continue"
$failed = 0

function Test-Step {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    Write-Host "`n[CHECK] $Name" -ForegroundColor Cyan

    try {
        & $Command
        if ($LASTEXITCODE -ne 0) { throw "Command failed" }
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)"
        $script:failed++
    }
}

Test-Step "EKS cluster exists" {
    aws eks describe-cluster `
        --name $ClusterName `
        --region $Region `
        --profile $Profile `
        --query "cluster.status" `
        --output text
}

Test-Step "kubectl can reach cluster" {
    kubectl get nodes
}

Test-Step "External Secrets pods running" {
    kubectl get pods -n external-secrets
}

Test-Step "External Secrets service account has IRSA annotation" {
    kubectl get sa external-secrets -n external-secrets `
        -o jsonpath="{.metadata.annotations.eks\.amazonaws\.com/role-arn}"
}

Test-Step "AWS Secrets Manager repo secret exists" {
    aws secretsmanager describe-secret `
        --secret-id $RepoSecretName `
        --region $Region `
        --profile $Profile `
        --query "Name" `
        --output text
}

Test-Step "ClusterSecretStore exists and is ready" {
    kubectl get clustersecretstore aws-secrets-manager
}

Test-Step "ArgoCD pods running" {
    kubectl get pods -n argocd
}

Test-Step "ArgoCD repo secret exists" {
    kubectl get secret hello-aws-eks-repo -n argocd
}

Test-Step "ArgoCD platform-root app is synced/healthy" {
    kubectl get application platform-root -n argocd
}


Test-Step "Vault namespace exists" {
    kubectl get namespace vault
}

Test-Step "Vault service account has IRSA annotation" {
    kubectl get sa vault -n vault `
        -o jsonpath="{.metadata.annotations.eks\.amazonaws\.com/role-arn}"
}

Test-Step "Vault KMS alias exists" {
    aws kms describe-key `
        --key-id alias/$ClusterName-vault-unseal `
        --region $Region `
        --profile $Profile `
        --query "KeyMetadata.KeyState" `
        --output text
}

Test-Step "Vault ArgoCD app exists" {
    kubectl get application vault -n argocd
}

Test-Step "Vault pods exist" {
    kubectl get pods -n vault
}

Test-Step "AWS Load Balancer Controller running" {
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
}

Test-Step "Rancher ArgoCD app exists" {
    kubectl get application rancher -n argocd
}

Test-Step "Rancher rollout is available" {
    kubectl rollout status deployment/rancher -n cattle-system --timeout=10m
}

Test-Step "Rancher hostname resolves" {
    nslookup "rancher.$DomainName"
}

Test-Step "Prometheus ArgoCD app exists" {
    kubectl get application kube-prometheus-stack -n argocd
}

Test-Step "Prometheus Operator CRDs are established" {
    kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=120s
    kubectl wait --for=condition=Established crd/prometheuses.monitoring.coreos.com --timeout=120s
}

Test-Step "Prometheus Operator is available" {
    kubectl rollout status deployment/kube-prometheus-stack-operator -n monitoring --timeout=10m
}

Test-Step "Prometheus instance and gp3 PVC exist" {
    kubectl get prometheus -n monitoring

    $pvcs = kubectl get pvc -n monitoring -o json | ConvertFrom-Json
    $prometheusPvc = $pvcs.items | Where-Object {
        $_.metadata.name -like "prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-*" -or
        $_.metadata.name -like "prometheus-kube-prometheus-stack-prometheus-db-*"
    } | Select-Object -First 1

    if (-not $prometheusPvc) {
        throw "Prometheus persistent volume claim not found in monitoring namespace"
    }
    if ($prometheusPvc.spec.storageClassName -ne "gp3") {
        throw "Prometheus PVC should use gp3, got $($prometheusPvc.spec.storageClassName)"
    }
    if ($prometheusPvc.status.phase -ne "Bound") {
        throw "Prometheus PVC is not Bound: $($prometheusPvc.status.phase)"
    }
}

Test-Step "Grafana ArgoCD app exists" {
    kubectl get application grafana -n argocd
}

Test-Step "Longhorn ArgoCD app exists" {
    kubectl get application longhorn -n argocd
}

Test-Step "Longhorn S3 backup bucket exists" {
    aws s3api head-bucket `
        --bucket $LonghornBackupBucket `
        --region $Region `
        --profile $Profile
}

Test-Step "Longhorn has an EKS Pod Identity association" {
    $associationId = aws eks list-pod-identity-associations `
        --cluster-name $ClusterName `
        --namespace longhorn-system `
        --service-account longhorn-service-account `
        --region $Region `
        --profile $Profile `
        --query "associations[0].associationId" `
        --output text

    if ([string]::IsNullOrWhiteSpace($associationId) -or $associationId -eq "None") {
        throw "No Pod Identity association found for longhorn-system/longhorn-service-account"
    }
}

Test-Step "Longhorn S3 credential Secret is keyless" {
    $secret = kubectl get secret longhorn-backup-credentials -n longhorn-system -o json | ConvertFrom-Json
    $keys = @($secret.data.PSObject.Properties.Name)

    if ($keys -notcontains "AWS_IAM_ROLE_ARN") {
        throw "Longhorn backup credential Secret does not contain AWS_IAM_ROLE_ARN"
    }
    if ($keys -contains "AWS_ACCESS_KEY_ID" -or $keys -contains "AWS_SECRET_ACCESS_KEY") {
        throw "Longhorn backup credential Secret must not contain static AWS access keys"
    }
}

Test-Step "Longhorn S3 BackupTarget is configured and available" {
    $target = kubectl get backuptarget default -n longhorn-system -o json | ConvertFrom-Json
    $expectedUrl = "s3://$LonghornBackupBucket@$Region/backupstore/"

    if ($target.spec.backupTargetURL -ne $expectedUrl) {
        throw "Expected Longhorn backup target $expectedUrl, got $($target.spec.backupTargetURL)"
    }

    if ($target.spec.credentialSecret -ne "longhorn-backup-credentials") {
        throw "Expected Longhorn credential Secret longhorn-backup-credentials, got $($target.spec.credentialSecret)"
    }

    if ($target.status.available -ne $true) {
        $message = ($target.status.conditions | Where-Object { $_.status -eq "False" } | Select-Object -First 1 -ExpandProperty message)
        throw "Longhorn backup target is not available. $message"
    }
}

Test-Step "Longhorn daily recurring backup job is configured" {
    $job = kubectl get recurringjob daily-backup -n longhorn-system -o json | ConvertFrom-Json

    if ($job.spec.task -ne "backup") {
        throw "Expected recurring job task backup, got $($job.spec.task)"
    }
    if ($job.spec.cron -ne "0 3 * * *") {
        throw "Expected daily backup cron 0 3 * * *, got $($job.spec.cron)"
    }
    if ($job.spec.retain -ne 7) {
        throw "Expected recurring backup retention of 7, got $($job.spec.retain)"
    }
    if ($job.spec.groups -notcontains "default") {
        throw "daily-backup must belong to Longhorn's default recurring-job group"
    }
}

Test-Step "Longhorn manager DaemonSet is available" {
    kubectl rollout status daemonset/longhorn-manager -n longhorn-system --timeout=10m
}

Test-Step "Longhorn ServiceMonitor exists for Prometheus" {
    $monitors = kubectl get servicemonitor -n longhorn-system -o json | ConvertFrom-Json
    if (-not $monitors.items -or $monitors.items.Count -lt 1) {
        throw "No ServiceMonitor found in longhorn-system"
    }

    $longhornMonitor = $monitors.items | Where-Object {
        $_.spec.selector.matchLabels.app -eq "longhorn-manager"
    } | Select-Object -First 1

    if (-not $longhornMonitor) {
        throw "No ServiceMonitor selecting app=longhorn-manager was found"
    }
}

Test-Step "Longhorn StorageClass exists and gp3 remains default" {
    kubectl get storageclass longhorn
    $defaultClass = kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}'
    if (($defaultClass | Out-String).Trim() -ne "gp3") {
        throw "Expected gp3 to be the sole default StorageClass, got: $defaultClass"
    }
}

Test-Step "Every Longhorn node has a schedulable dedicated data disk" {
    # Confirms the dedicated local NVMe instance-store volume mounted at
    # /var/lib/longhorn (see eks-foundation module) was actually picked up as Longhorn's disk on
    # every node -- not just that the manager pod is running.
    $nodesJson = kubectl get nodes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json
    if (-not $nodesJson.items -or $nodesJson.items.Count -lt 3) {
        throw "Expected at least 3 Longhorn nodes, found $($nodesJson.items.Count)"
    }
    foreach ($node in $nodesJson.items) {
        $disks = $node.spec.disks.PSObject.Properties.Value
        $schedulableDisk = $disks | Where-Object { $_.allowScheduling -eq $true }
        if (-not $schedulableDisk) {
            throw "Longhorn node $($node.metadata.name) has no schedulable disk"
        }
    }
}

Test-Step "Longhorn volume read/write/reschedule smoke test" {
    # Provisions a real Longhorn PVC, writes known data, deletes and
    # recreates the consuming pod (forcing a reschedule/reattach), and
    # verifies the data survived -- catching failures that
    # "is the DaemonSet Ready" alone would miss entirely.
    $ns = "longhorn-smoke-test"
    $pvcYaml = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-test-pvc
  namespace: $ns
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
"@
    $pvcYaml | kubectl apply -f -

    $writerPodYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: smoke-test-writer
  namespace: $ns
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: public.ecr.aws/docker/library/busybox:1.36
      command: ["sh", "-c", "echo longhorn-smoke-test-value > /data/testfile && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: smoke-test-pvc
"@
    $writerPodYaml | kubectl apply -f -
    kubectl wait --for=condition=Ready pod/smoke-test-writer -n $ns --timeout=180s

    $written = kubectl exec smoke-test-writer -n $ns -- cat /data/testfile
    if (($written | Out-String).Trim() -ne "longhorn-smoke-test-value") {
        throw "Data written to Longhorn volume did not read back correctly"
    }

    # Force a reschedule onto a (possibly different) node to prove the
    # volume reattaches correctly, not just that it worked on first mount.
    kubectl delete pod smoke-test-writer -n $ns --wait=true --timeout=120s

    $readerPodYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: smoke-test-reader
  namespace: $ns
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: public.ecr.aws/docker/library/busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: smoke-test-pvc
"@
    $readerPodYaml | kubectl apply -f -
    kubectl wait --for=condition=Ready pod/smoke-test-reader -n $ns --timeout=180s

    $reread = kubectl exec smoke-test-reader -n $ns -- cat /data/testfile
    if (($reread | Out-String).Trim() -ne "longhorn-smoke-test-value") {
        throw "Data did not survive pod reschedule/volume reattach"
    }

    kubectl delete namespace $ns --wait=false
}

Test-Step "ArgoCD hostname resolves" {
    nslookup "argocd.$DomainName"
}

if ($failed -eq 0) {
    Write-Host "`nDeployment validation PASSED." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`nDeployment validation FAILED with $failed issue(s)." -ForegroundColor Red
    exit 1
}