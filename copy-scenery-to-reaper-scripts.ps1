$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'scenery'
$destinationRoot = 'C:\REAPER\Scripts'
$destination = Join-Path $destinationRoot 'scenery'

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Scenery source folder was not found: $source"
}

if (-not (Test-Path -LiteralPath $destinationRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationRoot | Out-Null
}

if (Test-Path -LiteralPath $destination -PathType Container) {
    Remove-Item -LiteralPath $destination -Recurse -Force
}

Copy-Item -LiteralPath $source -Destination $destinationRoot -Recurse -Force

Write-Host "Copied Scenery to $destination"