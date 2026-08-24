[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LocalRoot
)

$ErrorActionPreference = 'Stop'
$resolvedRoot = [IO.Path]::GetFullPath($LocalRoot)
$entryPoint = Join-Path $resolvedRoot 'ewsp.ps1'
if (-not (Test-Path -LiteralPath $entryPoint -PathType Leaf)) {
    [Console]::Error.WriteLine("EWSP startup reconciliation entry point is missing: $entryPoint")
    exit 2
}

$delays = @(0, 15, 30, 60, 120, 180)
$env:EWSP_STARTUP_RECONCILIATION = 'true'
try {
    for ($attempt = 1; $attempt -le $delays.Count; $attempt++) {
        if ($delays[$attempt - 1] -gt 0) { Start-Sleep -Seconds $delays[$attempt - 1] }
        Write-Host "EWSP startup reconciliation attempt $attempt/$($delays.Count)"
        $output = @(& powershell.exe -NoProfile -File $entryPoint deploy 2>&1)
        $exitCode = $LASTEXITCODE
        $safeOutput = $output -join "`n"
        Write-Output $safeOutput
        if ($exitCode -eq 0) {
            Write-Host 'RECONCILIATION_SUCCEEDED'
            exit 0
        }
        if ($safeOutput -notmatch 'EWSP_DEPLOY_RESULT=DEPLOYMENT_DEFERRED') {
            [Console]::Error.WriteLine('Startup reconciliation encountered a non-transient deployment failure; bounded retry stopped.')
            exit $exitCode
        }
        Write-Host 'K8S_UNAVAILABLE or external artifact service unavailable; deployment deferred.' -ForegroundColor Yellow
    }
    [Console]::Error.WriteLine('DEPLOYMENT_DEFERRED: bounded startup reconciliation retries were exhausted.')
    exit 75
} finally {
    Remove-Item Env:EWSP_STARTUP_RECONCILIATION -ErrorAction SilentlyContinue
}
