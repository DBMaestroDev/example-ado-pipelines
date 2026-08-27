<#
.SYNOPSIS
    Paradigm Azure DevOps Pipeline Trigger Script

.DESCRIPTION
    This script processes DBmaestro package information and triggers Azure DevOps pipelines
    based on package type and event status.
    Configurable for regular and adhoc pipelines.
    Authenticates using an Azure Service Principal (client credentials).
    Configure service principal details and pipeline names in the 'Configuration' section.

.NOTES
    Version:        2.1.0
    Author:         DBmaestro
    Creation Date:  2026-02-05
    Last Modified:  2026-06-12

    Change Log:
    - 1.0.0 (2026-02-05): Initial version with logging, error handling, and pipeline integration
    - 2.0.0 (2026-02-05): Updated version with enhanced logging and Azure DevOps pipeline integration
    - 2.1.0 (2026-06-12): Replaced PAT authentication with Azure Service Principal

.PARAMETER param1
    Path to the JSON file containing package and flow details

.EXAMPLE
    .\paradigm_advapro.ps1 "C:\path\to\package.json"
#>

#Set-PSDebug -Trace 1

$param1=$args[0]

# Configuration
$regularPipelineName = "[DEV02] Adva-Pro DB"
$adhocPipelineName = "[DEV02] Adva-Pro DB Ad Hoc"

# Service Principal credentials (set these as system environment variables)
$spClientId     = $env:AZURE_SP_CLIENT_ID
$spClientSecret = $env:AZURE_SP_CLIENT_SECRET
$spTenantId     = $env:AZURE_SP_TENANT_ID

# Setup logging
$logsFolder = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logsFolder)) {
    New-Item -ItemType Directory -Path $logsFolder -Force | Out-Null
}
$logFile = Join-Path $logsFolder "paradigm_advapro.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
"`n=== Script Started at $timestamp ===" | Out-File -Append $logFile

function Write-Log {
    param($Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host $Message
    "$ts - $Message" | Out-File -Append $logFile
}

Write-Log "Powershell script processing file: $param1"
 
$gen_doc = Get-Content -Path $param1 | ConvertFrom-Json
 
#$doc_var = "C:\workspace\scripts\paradigm_output.txt"

# If you want to extract the project name (from FlowDetails or Job)

# (Note: In your JSON, 'FlowDetails.name' is the project name)

$projectName = $gen_doc.FlowDetails.name

Write-Log "Project Name: $projectName"

#$projectName | Out-File -Append $doc_var
 
# If you want to extract the package name (from Versions.Package.versionString)

foreach ($version in $gen_doc.Versions) {

    $packageName = $version.Package.versionString

    Write-Log "Package Name: $packageName" 

 #   $packageName | Out-File -Append $doc_var

}
 
# Extract policy names (from Policies.policies.policy.Value)

foreach ($policy in $gen_doc.Policies.policies) {

    $policyName = $policy.policy.Value

    Write-Log "Policy Name: $policyName" 

#    $policyName | Out-File -Append $doc_var

}
 
foreach ($version in $gen_doc.Versions) {
    # Extract TypeId and set flag if it is 2
    $typeId = $version.Package.TypeId
    Write-Log "TypeId: $typeId"
    if ($typeId -eq 2) {
        $foundAdhoc = $true
    }
}
 



# Extract the event and step

$event = $gen_doc.Event

$step = $gen_doc.Step
 
Write-Log "Event: $event"  

Write-Log "Step: $step" 

#$event | Out-File -Append $doc_var

#$step | Out-File -Append $doc_var

Write-Log $packageName


$loginOutput = az login --service-principal --username $spClientId --password $spClientSecret --tenant $spTenantId --only-show-errors 2>&1
Write-Log "Azure Login Output: $loginOutput"

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Azure service principal login failed with exit code $LASTEXITCODE"
    exit 1
}

 
if ($foundAdhoc) {
    Write-Log "Is adhoc Package"
    #"adhoc" | Out-File -Append $doc_var
    $pipelineOutput = az pipelines run --name $adhocPipelineName --branch "main" --org "https://dev.azure.com/paradigmoutcomes" --project "Network and Operations" --variables "BuildPipeline.packagename=$packageName" 2>&1
    Write-Log "Command output: $pipelineOutput"
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Pipeline execution failed with exit code $LASTEXITCODE"
        exit 1
    }
}
else
{
    Write-Log "Is regular Package"
    $pipelineOutput = az pipelines run --name $regularPipelineName --branch "main" --org "https://dev.azure.com/paradigmoutcomes" --project "Network and Operations" --variables "BuildPipeline.packagename=$packageName" 2>&1
    Write-Log "Command output: $pipelineOutput"
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: Pipeline execution failed with exit code $LASTEXITCODE"
        exit 1
    }
}

Write-Log "=== Script Completed ==="