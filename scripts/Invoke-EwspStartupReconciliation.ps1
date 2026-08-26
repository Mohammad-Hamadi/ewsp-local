[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LocalRoot,

    [ValidateRange(0, 255)]
    [int]$DeferredExitCode = 0
)

$ErrorActionPreference = 'Stop'
$resolvedRoot = [IO.Path]::GetFullPath($LocalRoot)
$modulePath = Join-Path $resolvedRoot 'scripts\Ewsp.Local.psm1'
$env:EWSP_STARTUP_RECONCILIATION = 'true'
try {
    Import-Module $modulePath -Force -DisableNameChecking -ErrorAction Stop
    $result = Invoke-EwspBoundedDeploymentReconciliation -LocalRoot $resolvedRoot
    Write-Host "EWSP_RECONCILIATION_RESULT=$($result.Result) category=$($result.Category) attempts=$($result.Attempts)"
    if ($result.Result -eq 'RECONCILIATION_SUCCEEDED') { exit 0 }
    if ($result.Result -eq 'TEMPORARY_HOST_NOT_READY') {
        Write-Host 'Deployment was safely deferred after bounded host-readiness retries; no configuration or deployment failure was hidden.' -ForegroundColor Yellow
        exit $DeferredExitCode
    }
    [Console]::Error.WriteLine('Reconciliation encountered a real configuration, authentication, or deployment failure; retry stopped.')
    exit $result.ExitCode
} finally {
    Remove-Item Env:EWSP_STARTUP_RECONCILIATION -ErrorAction SilentlyContinue
}
