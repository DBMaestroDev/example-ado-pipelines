# Creates the 8 approval-gate environments and adds an Approval check (single
# approver) to each, via the ADO REST API directly (the azure-devops CLI
# extension has no `environment` or `checks` command group).
# Requires: az login (with an account that has permission in the org/project)
$Org = "dbmsc"
$Project = "Example"
$ApproverId = "ea7b4fe7-32f3-6ee1-8cec-632b290acf75"  # nicolast@DBmaestro.com
$AdoResource = "499b84ac-1321-427f-aa17-267ca6975798"

$environments = @(
    "Release-Source-pre-approval",
    "Release-Source-post-approval",
    "UAT_Env_1-pre-approval",
    "UAT_Env_1-post-approval",
    "Pre_Prod_Env_1-pre-approval",
    "Pre_Prod_Env_1-post-approval",
    "Prod_Env_1-pre-approval",
    "Prod_Env_1-post-approval"
)

$envUri = "https://dev.azure.com/$Org/$Project/_apis/pipelines/environments?api-version=7.1-preview.1"
$checkUri = "https://dev.azure.com/$Org/$Project/_apis/pipelines/checks/configurations?api-version=7.1-preview.1"
$tempFile = Join-Path $env:TEMP "ado-request-body.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

foreach ($envName in $environments) {
    Write-Host "Creating environment: $envName"
    $envBody = (@{ name = $envName; description = "" } | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllText($tempFile, $envBody, $utf8NoBom)
    $created = az rest --method post --uri $envUri --resource $AdoResource --body "@$tempFile" --headers "Content-Type=application/json" -o json | ConvertFrom-Json
    $envId = $created.id

    Write-Host "Adding approval check to environment id: $envId"
    $checkBody = @{
        type     = @{ name = "Approval"; id = "8C6F20A7-A545-4486-9777-F762FAFE0D4D" }
        settings = @{
            approvers            = @(@{ id = $ApproverId })
            executionOrder       = "anyOrder"
            minRequiredApprovers = 0
            instructions         = ""
            blockedApprovers     = @()
        }
        resource = @{ type = "environment"; id = "$envId" }
        timeout  = 43200
    }
    $checkJson = ($checkBody | ConvertTo-Json -Depth 10 -Compress)
    [System.IO.File]::WriteAllText($tempFile, $checkJson, $utf8NoBom)
    az rest --method post --uri $checkUri --resource $AdoResource --body "@$tempFile" --headers "Content-Type=application/json" | Out-Null
}

Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
