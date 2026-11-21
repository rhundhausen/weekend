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
  3. commits that file alone and pushes it;
  4. starts the city's refine workflow by hand with the GitHub CLI (gh workflow run), which
     rebuilds the site's data and deploys it. No workflow starts on a push. Without gh, or if it
     fails, the local events reach the site with the next nightly refine, or a refine run by hand
     from Actions.

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
  $repo = (Get-WkCity).repo
  $started = $false
  if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh workflow run refine.yml -R $repo
    $started = $LASTEXITCODE -eq 0
  }
  if ($started) {
    Write-Host 'Pushed, and started the refine workflow, which updates the site in about 20 minutes.'
  } else {
    Write-Host "Pushed. Could not start refine with gh, so run it from https://github.com/$repo/actions/workflows/refine.yml, or the events reach the site with the next nightly refine."
  }
} finally {
  Pop-Location
}
