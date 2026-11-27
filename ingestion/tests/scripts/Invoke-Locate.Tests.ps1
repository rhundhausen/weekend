BeforeAll {
  . "$PSScriptRoot/../TestCity.ps1"
  $script:locate = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Invoke-Locate.ps1'
  . "$PSScriptRoot/../../scripts/lib/Raw.ps1"
  . "$PSScriptRoot/../../scripts/lib/VenueLocations.ps1"

  $script:fetch = {
    param([string]$Url, [switch]$Raw)
    if ($Url -like '*/robots.txt') { return '' }
    if ($Url -like '*geocoding.geo.census.gov*') {
      return [pscustomobject]@{ result = [pscustomobject]@{ addressMatches = @([pscustomobject]@{ coordinates = [pscustomobject]@{ x = -116.2; y = 43.6 } }) } }
    }
    if ($Url -eq 'https://hall.test/show') { return '<p>Hall, 1 Main St, Boise, ID 83702</p>' }
    throw "HTTP 404 from $Url"
  }
}

Describe 'Invoke-Locate' {
  BeforeEach {
    $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    $null = New-Item -ItemType Directory -Path (Join-Path $dir 'data')
    $event = New-WkEvent -Title 'Show' -Start '2026-12-05T19:30:00-07:00' -Venue 'Hall' -City 'Boise' -Category 'music' -Url 'https://hall.test/show' `
      -Sources @(@{ name = 'beta'; url = 'https://hall.test/show'; fetchedAt = '2026-11-29T07:01:00Z' })
    Write-WkEventFile -Path (Join-Path $dir 'data' 'events.json') -Events @($event)
    $results = @([pscustomobject]@{ Name = 'beta'; Status = 'ok'; Events = @($event) })
    Write-WkRawFile (Join-Path $dir 'data' 'raw-events.json') (Update-WkRawFile $null -Results $results -Keep @('beta') -AsOf '2026-11-29T07:00:00Z' -FetchedAt '2026-11-29T07:01:00Z')
  }

  It 'writes the venues it placed and a summary' {
    & $locate -DataDir (Join-Path $dir 'data') -OutDir (Join-Path $dir 'out') -Now '2026-11-29T10:00:00Z' -MinDelaySeconds 0 -Fetch $fetch *>&1 | Out-Null
    $state = Read-WkVenueLocationState (Join-Path $dir 'data' 'venue-locations.json')
    $state['hall'].from | Should -Be 'page'
    $state['hall'].address | Should -Be '1 Main St, Boise, ID 83702'
    $summary = Get-Content (Join-Path $dir 'out' 'locate.json') -Raw | ConvertFrom-Json -DateKind String
    $summary.tried | Should -Be 1
    $summary.found.page | Should -Be 1
  }

  It 'writes nothing with -NoWrite' {
    & $locate -DataDir (Join-Path $dir 'data') -OutDir (Join-Path $dir 'out') -Now '2026-11-29T10:00:00Z' -MinDelaySeconds 0 -Fetch $fetch -NoWrite *>&1 | Out-Null
    Test-Path (Join-Path $dir 'data' 'venue-locations.json') | Should -BeFalse
  }
}
