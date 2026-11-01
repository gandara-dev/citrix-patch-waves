# Helpers shared by the validator, the planner, the engine, and the record.
#
# Maintenance files arrive from ConvertFrom-Json (PSCustomObject) or as
# hashtables built in PowerShell, so every accessor accepts both shapes.

function Get-CpwValue {
    param($InputObject, [string]$Name, $Default = $null)

    # The unary comma keeps one-element and empty arrays intact instead of
    # letting the pipeline unroll them.
    if ($null -eq $InputObject) { return , $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return , $InputObject[$Name] }
        return , $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return , $Default }
    return , $property.Value
}

function Get-CpwList {
    param($InputObject, [string]$Name)

    # Emits the items one by one, for foreach loops and pipelines; wrap the
    # call in @() when an array is needed.
    $value = Get-CpwValue $InputObject $Name
    if ($null -eq $value) { return }
    foreach ($item in $value) { $item }
}

function Test-CpwHasValue {
    param($InputObject, [string]$Name)

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject.Contains($Name) }
    return $null -ne $InputObject.PSObject.Properties[$Name]
}

# ConvertFrom-Json turns ISO 8601 strings into DateTime on some PowerShell
# versions and leaves them as strings on others. A time without a UTC offset is
# ambiguous for a change window, so it is rejected (returns $null).
function ConvertTo-CpwDate {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return $null }
        return [DateTimeOffset]::new($Value.ToUniversalTime())
    }
    $text = [string]$Value
    if ($text -notmatch '(Z|[+-]\d{2}:\d{2})$') { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $null }
    return $parsed.ToUniversalTime()
}

function Format-CpwDate {
    param($Value)

    if ($null -eq $Value) { return $null }
    $date = if ($Value -is [DateTimeOffset]) { $Value } else { ConvertTo-CpwDate $Value }
    if ($null -eq $date) { return $null }
    return $date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

# Machine names are compared without the domain and without case:
# "CORP\LISW11FIN001", "lisw11fin001.corp.example.test", and "LISW11FIN001"
# are the same machine.
function Get-CpwShortName {
    param([string]$Name)

    $short = ($Name -split '\\')[-1]
    return ($short -split '\.')[0].ToUpperInvariant()
}

# JSON numbers arrive as Int32 or Int64; doubles and strings are rejected.
function Test-CpwInteger {
    param($Value, [long]$Minimum, [long]$Maximum)

    if ($Value -isnot [int] -and $Value -isnot [long]) { return $false }
    return $Value -ge $Minimum -and $Value -le $Maximum
}
