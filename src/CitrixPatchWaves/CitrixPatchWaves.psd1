@{
    RootModule = 'CitrixPatchWaves.psm1'
    ModuleVersion = '0.2.0'
    GUID = '1449ba59-ac64-432e-b77a-73e629d83c9f'
    Author = 'Mateus Gandara'
    Description = 'Patches Citrix VDAs in place in waves: drain, patch, restart, verify registration, and stop when a wave exceeds its failure budget. Ships with a deterministic simulation and writes a change record.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Export-CpwChangeRecord',
        'Get-CpwPlan',
        'Import-CpwMaintenance',
        'Invoke-CpwMaintenance',
        'New-CpwCitrixProvider',
        'New-CpwSimulationProvider',
        'Test-CpwMaintenance'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            LicenseUri = 'https://github.com/gandara-dev/citrix-patch-waves/blob/main/LICENSE'
            ProjectUri = 'https://github.com/gandara-dev/citrix-patch-waves'
        }
    }
}
