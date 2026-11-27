BeforeAll {
  . "$PSScriptRoot/../TestCity.ps1"
  . "$PSScriptRoot/../../scripts/lib/VenueLocations.ps1"

  $script:now = [DateTimeOffset]::Parse('2026-11-23T08:00:00Z')

  function New-Stored([string]$Key, [string]$Venue = 'Star Library', [string]$City = 'Star') {
    [pscustomobject]@{ id = "e-$Key-$City"; title = 'Story Time'; venue = $Venue; venueKey = $Key; city = $City }
  }

  function New-Raw([string]$Key, $Lat, $Lon, [string]$Address) {
    $location = [ordered]@{}
    if ($null -ne $Lat) { $location.lat = $Lat; $location.lon = $Lon }
    if ($Address) { $location.address = $Address }
    [pscustomobject]@{ venueKey = $Key; location = $location }
  }

  function Invoke-Update($Events, $Raw = @(), $State = @{}) {
    Update-WkVenueLocations -RawEvents $Raw -Events $Events -State $State -Now $now
  }
}

Describe 'Update-WkVenueLocations' {
  It 'uses the source''s location' {
    $result = Invoke-Update @(New-Stored 'morrison-center') @(New-Raw 'morrison-center' 43.6033 -116.2012 '2201 W Cesar Chavez Ln, Boise, ID 83725')
    $entry = $result.State['morrison-center']
    $entry.from | Should -Be 'feed'
    $entry.lat | Should -Be 43.6033
    $entry.lon | Should -Be -116.2012
    $entry.address | Should -Be '2201 W Cesar Chavez Ln, Boise, ID 83725'
    $entry.checked | Should -Be '2026-11-23'
    $result.Feed | Should -Be 1
  }

  It 'takes the point sources report most often' {
    $raw = @((New-Raw 'v' 43.61 -116.21), (New-Raw 'v' 43.60 -116.20), (New-Raw 'v' 43.60 -116.20))
    $entry = (Invoke-Update @(New-Stored 'v') $raw).State['v']
    $entry.lat | Should -Be 43.60
    $entry.lon | Should -Be (-116.20)
  }

  It 'never changes a manual entry' {
    $state = @{ v = [ordered]@{ lat = 43.5; lon = -116.1; from = 'manual'; checked = '2026-01-01' } }
    $entry = (Invoke-Update @(New-Stored 'v') @(New-Raw 'v' 43.60 -116.20) $state).State['v']
    $entry.lat | Should -Be 43.5
    $entry.from | Should -Be 'manual'
    $entry.checked | Should -Be '2026-01-01'
  }

  It 'has no way to make requests' {
    (Get-Command Update-WkVenueLocations).Parameters.Keys | Should -Not -Contain 'Fetch'
  }

  It 'marks placeholder venues' {
    $events = @(
      (New-Stored 'various-treasure-valley' 'Various locations' 'Boise'),
      (New-Stored 'mccall-area' 'McCall area' 'Valley County'),
      (New-Stored 'corbett-auctions' 'Corbett Auctions' 'Boise'),
      (New-Stored 'corbett-auctions' 'Corbett Auctions' 'Kuna')
    )
    $state = (Invoke-Update $events).State
    foreach ($key in 'various-treasure-valley', 'mccall-area', 'corbett-auctions') { $state[$key].from | Should -Be 'placeholder' }
  }

  It 'keeps a venue named only by a street address at town level, even with a source''s point' {
    $events = @(New-Stored '7497-w-whisper-rdg-dr' '7497 W Whisper Rdg Dr' 'Boise')
    $raw = @(New-Raw '7497-w-whisper-rdg-dr' 43.61 -116.31 '7497 W Whisper Rdg Dr, Boise, ID 83709')
    $entry = (Invoke-Update $events $raw).State['7497-w-whisper-rdg-dr']
    $entry.from | Should -Be 'placeholder'
    $entry.Keys | Should -Not -Contain 'address'
    $entry.Keys | Should -Not -Contain 'lat'
  }

  It 'does not take a venue whose name only starts with a number for a street address' {
    (Invoke-Update @(New-Stored '10-barrel' '10 Barrel Brewing' 'Boise')).State.ContainsKey('10-barrel') | Should -BeFalse
  }

  It 'does not count Other as a second town' {
    $events = @((New-Stored 'star-library'), (New-Stored 'star-library' 'Star Library' 'Other'))
    (Invoke-Update $events).State.ContainsKey('star-library') | Should -BeFalse
  }

  It 'leaves a venue with no point for locate' {
    $result = Invoke-Update @(New-Stored 'star-library')
    $result.State.ContainsKey('star-library') | Should -BeFalse
    $result.Feed | Should -Be 0
  }

  It 'removes a placeholder entry once the venue is one place' {
    $state = @{ 'v' = [ordered]@{ from = 'placeholder'; checked = '2026-11-20' } }
    (Invoke-Update @(New-Stored 'v' 'V Hall') -State $state).State.ContainsKey('v') | Should -BeFalse
  }

  It 'replaces a page entry with a source''s point' {
    $state = @{ v = [ordered]@{ lat = 43.5; lon = -116.1; address = '1 Main St, Boise, ID 83702'; from = 'page'; checked = '2026-11-01' } }
    $entry = (Invoke-Update @(New-Stored 'v') @(New-Raw 'v' 43.60 -116.20) $state).State['v']
    $entry.from | Should -Be 'feed'
    $entry.lat | Should -Be 43.60
  }

  It 'leaves entries locate wrote alone' {
    $state = @{}
    foreach ($from in 'page', 'address', 'zip', 'lookup') { $state[$from] = [ordered]@{ lat = 43.5; lon = -116.1; from = $from; checked = '2026-11-01' } }
    $state['none'] = [ordered]@{ from = 'none'; checked = '2026-11-01' }
    $events = @('page', 'address', 'zip', 'lookup', 'none' | ForEach-Object { New-Stored $_ "$_ Hall" })
    $after = (Invoke-Update $events -State $state).State
    foreach ($from in 'page', 'address', 'zip', 'lookup', 'none') {
      $after[$from].from | Should -Be $from
      $after[$from].checked | Should -Be '2026-11-01'
    }
  }

  It 'keeps a source''s point for a venue whose events name two towns' {
    $events = @((New-Stored 'expo-idaho' 'Expo Idaho' 'Boise'), (New-Stored 'expo-idaho' 'Expo Idaho' 'Garden City'))
    $entry = (Invoke-Update $events @(New-Raw 'expo-idaho' 43.65 -116.28)).State['expo-idaho']
    $entry.from | Should -Be 'feed'
    $entry.lat | Should -Be 43.65
  }

  It 'keeps an earlier source''s point when the events now name two towns' {
    $events = @((New-Stored 'expo-idaho' 'Expo Idaho' 'Boise'), (New-Stored 'expo-idaho' 'Expo Idaho' 'Garden City'))
    $state = @{ 'expo-idaho' = [ordered]@{ lat = 43.65; lon = -116.28; from = 'feed'; checked = '2026-11-01' } }
    (Invoke-Update $events -State $state).State['expo-idaho'].from | Should -Be 'feed'
  }

  It 'keeps entries for venues with no events now' {
    $state = @{ gone = [ordered]@{ lat = 43.6; lon = -116.2; from = 'lookup'; checked = '2026-01-01' } }
    (Invoke-Update @() -State $state).State['gone'].from | Should -Be 'lookup'
  }
}

Describe 'venue location file' {
  It 'writes sorted keys with LF endings and reads back the same entries' {
    $path = Join-Path $TestDrive 'venue-locations.json'
    $state = @{
      zeta  = [ordered]@{ from = 'none'; checked = '2026-11-23' }
      alpha = [ordered]@{ lat = 43.6033; lon = -116.2012; address = '2201 W Cesar Chavez Ln, Boise, ID 83725'; from = 'feed'; checked = '2026-11-23' }
    }
    Write-WkVenueLocationState $path $state
    $text = [IO.File]::ReadAllText($path)
    $text | Should -Not -Match "`r"
    $text.IndexOf('"alpha"') | Should -BeLessThan $text.IndexOf('"zeta"')
    $back = Read-WkVenueLocationState $path
    $back['alpha'].lat | Should -Be 43.6033
    $back['alpha'].from | Should -Be 'feed'
    $back['zeta'].Keys | Should -Not -Contain 'lat'
    @(Test-WkVenueLocationFile $path) | Should -BeNullOrEmpty
  }

  It 'reads a missing file as empty' {
    (Read-WkVenueLocationState (Join-Path $TestDrive 'missing.json')).Count | Should -Be 0
  }

  It 'accepts page and address entries with a point and rejects them without one' {
    $good = Join-Path $TestDrive 'page-good.json'
    [IO.File]::WriteAllText($good, '{ "a": { "lat": 43.6, "lon": -116.2, "address": "1 Main St, Boise, ID 83702", "from": "page", "checked": "2026-11-29" }, "b": { "lat": 43.6, "lon": -116.2, "from": "address", "checked": "2026-11-29" } }')
    @(Test-WkVenueLocationFile $good) | Should -BeNullOrEmpty
    $bad = Join-Path $TestDrive 'page-bad.json'
    [IO.File]::WriteAllText($bad, '{ "a": { "from": "page", "checked": "2026-11-29" } }')
    @(Test-WkVenueLocationFile $bad).Count | Should -Be 1
  }

  It 'reports a looked-up entry with no point' {
    $path = Join-Path $TestDrive 'bad.json'
    [IO.File]::WriteAllText($path, '{ "v": { "from": "lookup", "checked": "2026-11-23" } }')
    @(Test-WkVenueLocationFile $path).Count | Should -Be 1
  }
}
