<#
.SYNOPSIS
  Finds venues' street addresses for the site's map: the weekly locate run.
.DESCRIPTION
  Reads data/events.json, data/raw-events.json, and data/venue-locations.json, and for venues with
  no known place (or only a ZIP code's center, or an old name-search point) reads the address on
  their events' own pages, else the address a source sent, and turns it into a point with the US
  Census Bureau geocoder (lib/VenueAddress.ps1). It never searches by a venue's name. Writes
  data/venue-locations.json and out/locate.json, a summary of the run.

  Refine records the locations sources send and marks venues that are not one place; locate does
  everything that needs a request, so a slow site or service never holds up the nightly refine.
.PARAMETER DataDir
  The city's data folder. Defaults to the city repo's data/.
.PARAMETER BudgetMinutes
  How long the run may spend. Venues left over wait for the next run, busiest first.
.PARAMETER NoWrite
  Find addresses but write no data file (out/locate.json is still written).
.PARAMETER Fetch
  Gets a URL (with -Raw as text, otherwise parsed JSON). Used by tests.
#>
[CmdletBinding()]
param(
  [string]$CityRoot,
  [string]$DataDir,
  [string]$OutDir = './out',
  [int]$BudgetMinutes = 45,
  [int]$MaxPagesPerVenue = 3,
  [double]$MinDelaySeconds = 1,
  [switch]$NoWrite,
  [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
  [scriptblock]$Fetch
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'Raw.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Store.ps1')
. (Join-Path $PSScriptRoot 'lib' 'VenueAddress.ps1')

$null = Set-WkCityRoot $CityRoot
if (-not $DataDir) { $DataDir = Get-WkCityPath 'data' }
$dataPath = [IO.Path]::GetFullPath($DataDir, $PWD.Path)
$outPath = [IO.Path]::GetFullPath($OutDir, $PWD.Path)
$venuePath = Join-Path $dataPath 'venue-locations.json'

$events = @(Read-WkEventFile (Join-Path $dataPath 'events.json'))
$raw = Read-WkRawFile (Join-Path $dataPath 'raw-events.json')
$rawLocations = @(if ($raw) {
    Get-WkRawEvents $raw | Where-Object location | ForEach-Object { [pscustomobject]@{ venueKey = $_.venueKey; location = $_.location } }
  })
$state = Read-WkVenueLocationState $venuePath
Write-Host "Locate: $($events.Count) upcoming events, $($state.Count) venues on file"

$options = @{
  Events           = $events
  RawEvents        = $rawLocations
  State            = $state
  Now              = $Now
  BudgetSeconds    = $BudgetMinutes * 60
  MaxPagesPerVenue = $MaxPagesPerVenue
  MinDelaySeconds  = $MinDelaySeconds
}
if ($Fetch) { $options.Fetch = $Fetch }
$result = Update-WkVenueAddresses @options

if (-not $NoWrite) {
  Write-WkVenueLocationState $venuePath $result.State
  $problems = @(Test-WkVenueLocationFile $venuePath)
  if ($problems) { throw ($problems -join "`n") }
}

$summary = $result.Summary
$null = New-Item -ItemType Directory -Force -Path $outPath
[IO.File]::WriteAllText((Join-Path $outPath 'locate.json'), (($summary | ConvertTo-Json -Depth 4) -replace "`r`n", "`n") + "`n")
$line = "Locate: $($summary.tried) venues tried, $($summary.pages) pages read, $($summary.robotsSkipped) skipped by robots.txt; " +
  "found $($summary.found.page) on pages, $($summary.found.address) from source addresses, $($summary.found.zip) ZIP centers; " +
  "$($summary.none) none, $($summary.kept) kept; $($summary.seconds)s$($summary.stoppedEarly ? ', stopped at the time budget' : '')$($NoWrite ? ' (not written)' : '')"
Write-Host $line
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $line }
