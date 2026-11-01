#Requires -Version 7.2
<#
.SYNOPSIS
Plans or runs a maintenance change and writes the change record.

.DESCRIPTION
With -Simulation the change runs against the fictional site in a second,
with one of the named scenarios:

  normal            A regular night: every wave passes; three machines keep
                    a session past the 60-minute drain and go back unpatched.
  canary-failure    Patching fails on the first canary machine; the change
                    stops before wave 2 and the machine stays in maintenance.
  wave-over-budget  Two machines in wave 2 fail (patch error, no registration);
                    the budget is 1, so waves 3 to 5 never start.
  window-closes     The window is 3 hours long; the waves that do not fit are
                    deferred and their machines stay in service.
  force-logoff      drain.forceLogoff is on: sessions still open after the
                    drain are logged off and every machine is patched.

With -AdminAddress the plan is read from a real Citrix site. -PlanOnly writes
the plan and changes nothing; -Execute runs the change. In this version a real
site only runs restart-only changes (patch.windowsUpdates off and no
patch.software), and anything else is refused before a machine is touched.

.EXAMPLE
./scripts/Invoke-PatchWaves.ps1 -Simulation -Scenario wave-over-budget -OutputDirectory ./artifacts

.EXAMPLE
./scripts/Invoke-PatchWaves.ps1 -MaintenancePath ./maintenance.json -AdminAddress ddc01.corp.example.test -PlanOnly

.EXAMPLE
./scripts/Invoke-PatchWaves.ps1 -MaintenancePath ./restart.json -AdminAddress ddc01.corp.example.test -Execute
#>
[CmdletBinding(DefaultParameterSetName = 'Simulation')]
param(
    [string]$MaintenancePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'samples/lisbon-october.maintenance.json'),

    [Parameter(ParameterSetName = 'Simulation')]
    [switch]$Simulation,

    [Parameter(ParameterSetName = 'Simulation')]
    [ValidateSet('normal', 'canary-failure', 'wave-over-budget', 'window-closes', 'force-logoff')]
    [string]$Scenario = 'normal',

    [Parameter(Mandatory, ParameterSetName = 'Site')]
    [string]$AdminAddress,

    [Parameter(ParameterSetName = 'Site')]
    [pscredential]$Credential,

    [Parameter(ParameterSetName = 'Site')]
    [switch]$Execute,

    [switch]$PlanOnly,

    [string]$OutputDirectory = './artifacts'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/CitrixPatchWaves/CitrixPatchWaves.psd1') -Force

$maintenance = Import-CpwMaintenance -Path $MaintenancePath
# -Simulation is the default; the switch exists so commands can say so explicitly.
$useSimulation = $Simulation -or $PSCmdlet.ParameterSetName -eq 'Simulation'
if (-not $useSimulation) {
    if ([bool]$PlanOnly -eq [bool]$Execute) { throw 'Against a real site, add -PlanOnly to review the plan or -Execute to run the change.' }
    $providerParameters = @{ AdminAddress = $AdminAddress }
    if ($Credential) { $providerParameters.Credential = $Credential }
    $provider = New-CpwCitrixProvider @providerParameters
}
else {
    $failure = @{}
    switch ($Scenario) {
        'canary-failure' { $failure = @{ LISW11FIN001 = 'PatchFails' } }
        'wave-over-budget' { $failure = @{ LISW11FIN003 = 'PatchFails'; LISW11FIN006 = 'NoRegistration' } }
        'window-closes' { $maintenance.WindowEnd = $maintenance.WindowStart.AddHours(3) }
        'force-logoff' { $maintenance.ForceLogoff = $true }
    }
    $provider = New-CpwSimulationProvider -StartTime $maintenance.WindowStart -Failure $failure
}

$plan = Get-CpwPlan -Maintenance $maintenance -Provider $provider
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

if ($PlanOnly) {
    $planPath = Join-Path $OutputDirectory 'plan.json'
    Set-Content -LiteralPath $planPath -Value ($plan | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
    foreach ($wave in $plan.waves) {
        [pscustomobject]@{ Wave = $wave.number; Kind = $wave.kind; Budget = $wave.failureBudget; Machines = $wave.machines -join ', ' }
    }
    foreach ($machine in $plan.exclusions) { Write-Warning "$($machine.name) left out: $($machine.reason)" }
    foreach ($warning in $plan.warnings) { Write-Warning $warning }
    Write-Information "Plan written to $planPath" -InformationAction Continue
    return
}

$run = Invoke-CpwMaintenance -Maintenance $maintenance -Provider $provider -Plan $plan -Execute:$Execute -JournalPath (Join-Path $OutputDirectory 'journal.jsonl')
$files = Export-CpwChangeRecord -Run $run -OutputDirectory $OutputDirectory
[pscustomobject]@{
    Outcome = $run.outcome
    Patched = $run.totals.completed
    Failed = $run.totals.failed
    NotDrained = $run.totals.notDrained
    Deferred = $run.totals.deferred
    NotStarted = $run.totals.notStarted
    LeftInMaintenanceMode = $run.totals.leftInMaintenance
    ChangeRecord = ($files | Where-Object Name -EQ 'change-record.html').FullName
}
