[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help'
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'scripts\Ewsp.Local.psm1'

try {
    Import-Module $modulePath -Force -DisableNameChecking -ErrorAction Stop
    Invoke-EwspCommand -Command $Command -LocalRoot $PSScriptRoot
} catch {
    [Console]::Error.WriteLine("EWSP: $($_.Exception.Message)")
    exit 1
}
