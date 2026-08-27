<#
.SYNOPSIS
    Paradigm Azure DevOps Pipeline Trigger Script

.DESCRIPTION
    This script processes DBmaestro package information and triggers Azure DevOps pipelines
    based on package type and event status.
    Update the Personal Access Token (PAT) and organization/project details as needed.
    Configure pipeline names in the 'Configuration' section.

.NOTES
    Version:        1.1.0
    Author:         DBmaestro
    Creation Date:  2026-02-05
    Last Modified:  2026-02-05
    
    Change Log:
    - 1.0.0 (2026-02-05): Initial version with logging, error handling, and pipeline integration
    - 1.1.0 (2026-08-07): Cleanup. Adjust for ad-hoc only

.PARAMETER param1
    Path to the JSON file containing package and flow details

.EXAMPLE
    .\paradigm-hook.ps1 "C:\path\to\package.json"
#>

#Set-PSDebug -Trace 1

$param1=$args[0]

# Configuration
$PAT = " "
$ADOOrganization = "paradigmoutcomes"
$ADOProject = "Network and Operations"
$adhocPipelineName = "[DEV02] Adva-Pro DB Ad Hoc"

# Setup logging
$logsFolder = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logsFolder)) {
    New-Item -ItemType Directory -Path $logsFolder -Force | Out-Null
}
$logFile = Join-Path $logsFolder "$([System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)).log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
"`n=== Script Started at $timestamp ===" | Out-File -Append $logFile

function Write-Log {
    param($Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host $Message
    "$ts - $Message" | Out-File -Append $logFile
}

Write-Log "Powershell script processing file: $param1"
 
$parameters_json = Get-Content -Path $param1 | ConvertFrom-Json
$DOP_ProjectName = $parameters_json.FlowDetails.name

Write-Log "Project Name: $DOP_ProjectName"

# Extract the package name (from Versions.Package.versionString)
foreach ($version in $parameters_json.Versions) {
    $DOP_PackageName = $version.Package.versionString
    Write-Log "Package Name: $DOP_PackageName"
}
 
# Extract policy names (from Policies.policies.policy.Value)
foreach ($policy in $parameters_json.Policies.policies) {
    $policyName = $policy.policy.Value
    Write-Log "Policy Name: $policyName" 
}


foreach ($version in $parameters_json.Versions) {
    # Extract TypeId and set flag if it is 2
    $typeId = $version.Package.TypeId
    Write-Log "TypeId: $typeId"
    if ($typeId -eq 2) {
        $foundAdhoc = $true
    }
}

# Extract the event and step
$DOP_Event = $parameters_json.Event
$DOP_Step = $parameters_json.Step
Write-Log "Event: $DOP_Event"
Write-Log "Step: $DOP_Step"
Write-Log $DOP_PackageName


if ($foundAdhoc) {
    Write-Log "Is adhoc Package"

    $loginOutput = Write-Output $PAT | az devops login --organization "https://dev.azure.com/$ADOOrganization" --only-show-errors 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Azure DevOps login failed with exit code $LASTEXITCODE"
        Write-Log "Azure DevOps Login Output: $loginOutput"
        exit 1
    }

    $pipelineOutput = az pipelines run --name $adhocPipelineName --branch "main" --org "https://dev.azure.com/$ADOOrganization" --project $ADOProject --parameters "packageName=$DOP_PackageName" 2>&1
    Write-Log "Command output: $pipelineOutput"
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Pipeline execution failed with exit code $LASTEXITCODE"
        exit 1
    }
}
else {
    Write-Log "Package type is not adhoc. Won't trigger ADO pipeline"
}

Write-Log "=== Script Completed ==="