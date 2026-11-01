# Installs Pester and runs one simulated change so artifacts/ has a change
# record to open straight away.
$ErrorActionPreference = 'Stop'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
& (Join-Path $PSScriptRoot '../scripts/Invoke-PatchWaves.ps1') -Simulation -Scenario wave-over-budget -OutputDirectory (Join-Path $PSScriptRoot '../artifacts') | Format-List
