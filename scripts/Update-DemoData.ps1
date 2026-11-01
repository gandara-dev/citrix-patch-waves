#Requires -Version 7.2
<#
.SYNOPSIS
Regenerates the runs shown on the demo page from the simulation.

.DESCRIPTION
Runs every scenario of Invoke-PatchWaves.ps1 and writes its run.json to
site/data, plus site/data/index.json with the list. Run it after changing the
engine, the simulation, or the sample maintenance file; Pester fails when
the page data no longer matches the engine.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'site/data')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = $OutputDirectory
New-Item -ItemType Directory -Path $data -Force | Out-Null

$scenarios = [ordered]@{
    'normal' = @('A regular night', 'Every wave passes. Three machines still have a session after the 60-minute drain and go back into service unpatched.')
    'canary-failure' = @('Canary fails', 'Patching fails on LISW11FIN001 in the canary wave, so the change stops before wave 2. The machine stays in maintenance mode.')
    'wave-over-budget' = @('Wave over budget', 'Two machines fail in wave 2 and the budget is 1, so waves 3 to 5 never start.')
    'window-closes' = @('Window closes', 'The window is only three hours long. The waves that do not fit are deferred and their machines stay in service.')
    'force-logoff' = @('Force logoff', 'Sessions still open after the drain are logged off, so every machine is patched.')
}

$index = foreach ($id in $scenarios.Keys) {
    $work = Join-Path ([IO.Path]::GetTempPath()) "cpw-demo-$id"
    $summary = & (Join-Path $root 'scripts/Invoke-PatchWaves.ps1') -Simulation -Scenario $id -OutputDirectory $work
    Copy-Item -LiteralPath (Join-Path $work 'run.json') -Destination (Join-Path $data "$id.json") -Force
    Remove-Item -LiteralPath $work -Recurse -Force
    [ordered]@{ id = $id; title = $scenarios[$id][0]; description = $scenarios[$id][1]; file = "data/$id.json"; outcome = $summary.Outcome }
}
Set-Content -LiteralPath (Join-Path $data 'index.json') -Value (ConvertTo-Json -InputObject @($index) -Depth 4) -Encoding utf8NoBOM
Get-ChildItem -LiteralPath $data | Select-Object Name, Length
