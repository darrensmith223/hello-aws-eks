param(
    [string]$Region = "us-east-1",
    [string]$Profile = "terraform",
    [string]$ClusterName = "practice-eks-dev",
    [string]$RepoSecretName = "dev/argocd/repo/hello-aws-eks"
)

$ErrorActionPreference = "Continue"
$failed = 0

function Test-Gone {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    Write-Host "`n[CHECK] $Name" -ForegroundColor Cyan

    try {
        & $Command *> $null
        Write-Host "[FAIL] $Name still exists" -ForegroundColor Red
        $script:failed++
    }
    catch {
        Write-Host "[PASS] $Name not found" -ForegroundColor Green
    }
}

function Test-Exists {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    Write-Host "`n[CHECK] $Name" -ForegroundColor Cyan

    try {
        & $Command *> $null
        Write-Host "[PASS] $Name exists" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] $Name missing" -ForegroundColor Red
        $script:failed++
    }
}

Test-Gone "EKS cluster" {
    aws eks describe-cluster `
        --name $ClusterName `
        --region $Region `
        --profile $Profile
}

Test-Gone "EKS node groups" {
    aws eks list-nodegroups `
        --cluster-name $ClusterName `
        --region $Region `
        --profile $Profile
}

Test-Gone "Load balancers tagged for project" {
    $lbs = aws elbv2 describe-load-balancers `
        --region $Region `
        --profile $Profile `
        --query "LoadBalancers[*].LoadBalancerArn" `
        --output text

    if ($lbs) {
        foreach ($lb in $lbs.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $tags = aws elbv2 describe-tags `
                --resource-arns $lb `
                --region $Region `
                --profile $Profile `
                --query "TagDescriptions[0].Tags[?Key=='Project' && Value=='practice-eks-dev']" `
                --output text

            if ($tags) {
                throw "Project load balancer still exists: $lb"
            }
        }
    }

    throw "No matching project load balancers found"
}

Test-Gone "IAM role external-secrets" {
    aws iam get-role `
        --role-name "practice-eks-dev-external-secrets" `
        --profile $Profile
}

Test-Gone "IAM policy external-secrets" {
    aws iam get-policy `
        --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --profile $Profile --query Account --output text):policy/practice-eks-dev-external-secrets" `
        --profile $Profile
}

Test-Gone "CloudFormation stacks for EKS" {
    aws cloudformation describe-stacks `
        --region $Region `
        --profile $Profile `
        --query "Stacks[?contains(StackName, 'practice-eks-dev')].[StackName]" `
        --output text | Select-String "practice-eks-dev"
}

Test-Exists "Persistent ArgoCD repo secret in AWS Secrets Manager" {
    aws secretsmanager describe-secret `
        --secret-id $RepoSecretName `
        --region $Region `
        --profile $Profile
}

if ($failed -eq 0) {
    Write-Host "`nDestroy validation PASSED." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`nDestroy validation FAILED with $failed issue(s)." -ForegroundColor Red
    exit 1
}