#Requires -Version 7.4
<#
.SYNOPSIS
  Runs the local sources from a home connection and publishes them. Run from the city repo, about
  once a week, when the Sunday reminder email arrives.
.DESCRIPTION
  Some sites turn away or time out on GitHub's servers but load from a home connection. Those
  sources are marked local in sources.json, and the nightly ingest skips them. This script:

  1. pulls main, so the raw file is current;
  2. runs Invoke-Ingest.ps1 -Local, which replaces only the local sources' entries in
     data/raw-events.json;
  3. commits that file alone and pushes it.

  The push starts the refine workflow (its push trigger watches data/raw-events.json), which
  rebuilds the site's data and deploys it. The commit has no [skip ci], because GitHub would then
  skip refine too; Cloudflare also builds it, which changes nothing on the site.

  API keys, if a local source ever needs one, come from environment variables only: set them in
  the shell before running this.
.PARAMETER CityRoot
  The city repo. Defaults to $env:WEEKEND_CITY_ROOT, else the nearest folder at or above the
  current directory with a city.json.
.PARAMETER NoPublish
  Fetch and write the raw file, but don't commit or push.
#>
[CmdletBinding()]
param([string]$CityRoot, [switch]$NoPublish)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'City.ps1')
$root = Set-WkCityRoot $CityRoot
Push-Location $root
try {
  if (-not $NoPublish) {
    git pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw 'git pull failed; commit or stash your changes, then run this again' }
  }

  & (Join-Path $PSScriptRoot 'Invoke-Ingest.ps1') -Local
  if ($LASTEXITCODE -ne 0) { throw 'No local source succeeded, so nothing was published' }
  if ($NoPublish) { return }

  & (Join-Path $PSScriptRoot 'Publish-Data.ps1') -Path data/raw-events.json -Message 'data: local ingest'
  Write-Host 'Pushed. The refine workflow starts on its own and updates the site in a few minutes.'
} finally {
  Pop-Location
}
