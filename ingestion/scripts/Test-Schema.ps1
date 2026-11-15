#Requires -Version 7.4
<#
.SYNOPSIS
  Validates stored events and checks what they refer to.
.DESCRIPTION
  Checks data/events.json and data/archive/*.json against the event schema.
  Then checks that every category, tag, and source referenced by an event exists. Sources are
  validated by Test-Sources.ps1. Exits non-zero on any failure.
  Categories and tags are the core's vocabulary with the city's additions.
.PARAMETER CityRoot
  The city repo (holds city.json, ingestion/sources.json, and data/). Defaults to
  $env:WEEKEND_CITY_ROOT, else the nearest folder at or above the current directory with a city.json.
#>
[CmdletBinding()]
param(
  [string]$CityRoot
)

. (Join-Path $PSScriptRoot 'lib' 'Http.ps1')

$DataRoot = Set-WkCityRoot $CityRoot
$eventSchema = Get-WkSchemaText event
$failures = [System.Collections.Generic.List[string]]::new()

function Read-JsonFile {
  param([string]$Path)
  ConvertFrom-WkJson (Get-Content -LiteralPath $Path -Raw)
}

$categoryIds = @((Get-WkVocabulary categories).id)
$tagIds = @((Get-WkVocabulary tags).id)

# Events can only come from configured entries, the ones with a name.
$sourceNames = @((Read-JsonFile (Join-Path $DataRoot 'ingestion' 'sources.json')).sources | Where-Object name | ForEach-Object name)

$files = @(Join-Path $DataRoot 'data' 'events.json')
$archive = Join-Path $DataRoot 'data' 'archive'
if (Test-Path -LiteralPath $archive) {
  $files += @(Get-ChildItem -LiteralPath $archive -Filter '*.json' | ForEach-Object FullName)
}

foreach ($file in ($files | Where-Object { Test-Path -LiteralPath $_ })) {
  $label = [IO.Path]::GetRelativePath($DataRoot, $file) -replace '\\', '/'
  $events = @(Read-JsonFile $file)
  $before = $failures.Count

  foreach ($event in $events) {
    $json = $event | ConvertTo-Json -Depth 6
    if (-not ($json | Test-Json -Schema $eventSchema -ErrorAction SilentlyContinue)) {
      $failures.Add("$label`: $($event.id) does not match schema/event.schema.json")
    }
    if ($event.category -notin $categoryIds) {
      $failures.Add("$label`: $($event.id) has unknown category '$($event.category)'")
    }
    foreach ($tag in @($event.tags | Where-Object { $_ })) {
      if ($tag -notin $tagIds) { $failures.Add("$label`: $($event.id) has unknown tag '$tag'") }
    }
    foreach ($source in @($event.sources)) {
      if ($source.name -notin $sourceNames) { $failures.Add("$label`: $($event.id) has unknown source '$($source.name)'") }
    }
  }

  if ($failures.Count -eq $before) { Write-Host "OK: $label, $($events.Count) events" }
}

if ($failures.Count -gt 0) {
  $failures | Select-Object -First 20 | ForEach-Object { Write-Host "FAIL: $_" }
  if ($failures.Count -gt 20) { Write-Host "... and $($failures.Count - 20) more" }
  exit 1
}

Write-Host "OK: references valid, $($categoryIds.Count) categories, $($tagIds.Count) tags, $($sourceNames.Count) sources"
