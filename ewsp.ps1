[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommandArguments = @()
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'scripts\Ewsp.Local.psm1'

try {
    Import-Module $modulePath -Force -DisableNameChecking -ErrorAction Stop
    if ($Command -eq 'help' -and $CommandArguments.Count -eq 1 -and $CommandArguments[0] -in @('-h', '--help')) {
        $CommandArguments = @()
    }
    Invoke-EwspCommand -Command $Command -Arguments $CommandArguments -LocalRoot $PSScriptRoot
} catch {
    [Console]::Error.WriteLine("EWSP: $($_.Exception.Message)")
    exit 1
}
