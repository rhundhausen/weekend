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

  # Answers by URL fragment: the first key found in the URL wins; anything else answers no
  # results. Every requested URL is recorded in $script:calls.
  function New-Fetcher([hashtable]$Answers = @{}, [switch]$Throw) {
    $script:calls = [Collections.Generic.List[string]]::new()
    $list = $script:calls
    $fail = [bool]$Throw
    {
      param([string]$Url)
      $list.Add($Url)
      if ($fail) { throw 'service unavailable' }
      foreach ($key in $Answers.Keys) { if ($Url -like "*$key*") { return , @($Answers[$key]) } }
      , @()
    }.GetNewClosure()
  }

  function Invoke-Update($Events, $Raw = @(), $State = @{}, $Fetch = (New-Fetcher), [int]$Max = 300) {
    Update-WkVenueLocations -RawEvents $Raw -Events $Events -State $State -Now $now -MaxLookups $Max -MinDelaySeconds 0 -Fetch $Fetch
  }

  $script:boise = [pscustomobject]@{ lat = '43.6187'; lon = '-116.2146'; display_name = 'Somewhere, Boise' }
}

Describe 'Update-WkVenueLocations' {
  It 'uses the source''s location without a lookup' {
    $result = Invoke-Update @(New-Stored 'morrison-center') @(New-Raw 'morrison-center' 43.6033 -116.2012 '2201 W Cesar Chavez Ln, Boise, ID 83725')
    $entry = $result.State['morrison-center']
    $entry.from | Should -Be 'feed'
    $entry.lat | Should -Be 43.6033
    $entry.lon | Should -Be -116.2012
    $entry.address | Should -Be '2201 W Cesar Chavez Ln, Boise, ID 83725'
    $entry.checked | Should -Be '2026-11-23'
    $calls.Count | Should -Be 0
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

  It 'marks placeholder venues and looks none of them up' {
    $events = @(
      (New-Stored 'various-treasure-valley' 'Various locations' 'Boise'),
      (New-Stored 'mccall-area' 'McCall area' 'Valley County'),
      (New-Stored 'corbett-auctions' 'Corbett Auctions' 'Boise'),
      (New-Stored 'corbett-auctions' 'Corbett Auctions' 'Kuna')
    )
    $state = (Invoke-Update $events).State
    foreach ($key in 'various-treasure-valley', 'mccall-area', 'corbett-auctions') { $state[$key].from | Should -Be 'placeholder' }
    $calls.Count | Should -Be 0
  }

  It 'does not count Other as a second town' {
    $events = @((New-Stored 'star-library'), (New-Stored 'star-library' 'Star Library' 'Other'))
    (Invoke-Update $events -Fetch (New-Fetcher @{ 'q=' = $boise })).State['star-library'].from | Should -Be 'lookup'
  }

  It 'looks a venue up by name, town, and state' {
    $result = Invoke-Update @(New-Stored 'star-library') -Fetch (New-Fetcher @{ 'q=' = $boise })
    $entry = $result.State['star-library']
    $entry.from | Should -Be 'lookup'
    $entry.lat | Should -Be 43.6187
    $entry.lon | Should -Be -116.2146
    $calls[0] | Should -BeLike 'https://nominatim.openstreetmap.org/search?*'
    $calls[0] | Should -BeLike '*q=Star%20Library%2C%20Star%2C%20Idaho*'
    $calls[0] | Should -BeLike '*bounded=1*'
    $result.Looked | Should -Be 1
    $result.Found | Should -Be 1
  }

  It 'looks a venue up by the source''s address when the source sent no point' {
    Invoke-Update @(New-Stored 'v') @(New-Raw 'v' $null $null '1 Main St, Boise, ID 83702') -Fetch (New-Fetcher @{ 'q=' = $boise }) | Out-Null
    $calls[0] | Should -BeLike '*q=1%20Main%20St%2C%20Boise%2C%20ID%2083702*'
  }

  It 'rejects an answer far from the city' {
    $slc = [pscustomobject]@{ lat = '40.76'; lon = '-111.89' }
    (Invoke-Update @(New-Stored 'star-library') -Fetch (New-Fetcher @{ 'q=' = $slc })).State['star-library'].from | Should -Be 'none'
  }

  It 'tries a venue with no answer again after 30 days' {
    $state = @{ a = [ordered]@{ from = 'none'; checked = '2026-10-25' }; b = [ordered]@{ from = 'none'; checked = '2026-10-24' } }
    Invoke-Update @((New-Stored 'a' 'A Hall'), (New-Stored 'b' 'B Hall')) -State $state | Out-Null
    $calls.Count | Should -Be 1
    $calls[0] | Should -BeLike '*q=B%20Hall*'
  }

  It 'falls back to the ZIP code of the source''s address' {
    $result = Invoke-Update @(New-Stored 'v') @(New-Raw 'v' $null $null '9 Nowhere Rd, Boise, ID 83702') -Fetch (New-Fetcher @{ 'postalcode=83702' = $boise })
    $calls.Count | Should -Be 2
    $calls[1] | Should -BeLike '*postalcode=83702*'
    $calls[1] | Should -Not -BeLike '*q=*'
    $result.State['v'].from | Should -Be 'zip'
    $result.State['v'].address | Should -Be '9 Nowhere Rd, Boise, ID 83702'
  }

  It 'stops after the most lookups a run may make' {
    $events = @('a', 'b', 'c', 'd', 'e' | ForEach-Object { New-Stored $_ "$_ Hall" })
    $state = (Invoke-Update $events -Max 2).State
    $calls.Count | Should -Be 2
    @($state.Keys).Count | Should -Be 2
  }

  It 'keeps the entry when the lookup fails' {
    $state = @{ v = [ordered]@{ from = 'none'; checked = '2026-01-01' } }
    $result = Invoke-Update @(New-Stored 'v') -State $state -Fetch (New-Fetcher -Throw) 3>$null
    $result.State['v'].checked | Should -Be '2026-01-01'
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

  It 'reports a looked-up entry with no point' {
    $path = Join-Path $TestDrive 'bad.json'
    [IO.File]::WriteAllText($path, '{ "v": { "from": "lookup", "checked": "2026-11-23" } }')
    @(Test-WkVenueLocationFile $path).Count | Should -Be 1
  }
}
