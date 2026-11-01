$script:ModuleVersion = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'CitrixPatchWaves.psd1')).ModuleVersion
$script:SchemaVersion = 1

$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath = Join-Path $PSScriptRoot 'Public'

foreach ($file in Get-ChildItem -Path $privatePath -Filter '*.ps1' -File | Sort-Object Name) {
    . $file.FullName
}

foreach ($file in Get-ChildItem -Path $publicPath -Filter '*.ps1' -File | Sort-Object Name) {
    . $file.FullName
}
