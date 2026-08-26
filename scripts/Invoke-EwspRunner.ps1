[CmdletBinding()]
param(
    [string]$RunnerRoot = 'C:\actions-runner',
    [string]$DockerDesktopPath = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
)

$ErrorActionPreference = 'Stop'
$runnerCommand = Join-Path $RunnerRoot 'run.cmd'
if (-not (Test-Path -LiteralPath $runnerCommand -PathType Leaf)) {
    [Console]::Error.WriteLine("EWSP runner command is missing: $runnerCommand")
    exit 2
}
if (-not (Test-Path -LiteralPath $DockerDesktopPath -PathType Leaf)) {
    [Console]::Error.WriteLine("Docker Desktop is missing: $DockerDesktopPath")
    exit 2
}

$dockerProcesses = @(Get-Process -Name 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue)
if ($dockerProcesses.Count -eq 0) {
    Write-Host 'Starting Docker Desktop for the EWSP deployment substrate.'
    Start-Process -FilePath $DockerDesktopPath -WindowStyle Hidden
} else {
    Write-Host 'Docker Desktop is already running.'
}

Push-Location -LiteralPath $RunnerRoot
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $runnerCommand
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousPreference
    Pop-Location
}
exit $exitCode
