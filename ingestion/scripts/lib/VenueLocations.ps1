# Where each venue is, for the site's map. Refine runs Update-WkVenueLocations after the events
# are final and keeps the answers in data/venue-locations.json, keyed by venueKey. In order: the
# location a source sent (New-WkEvent's location), a Nominatim lookup by address or by name and
# town, and the center of the address's ZIP code. The site puts an event with none of these at
# its town's center (city.json cityCenters).

. "$PSScriptRoot/Http.ps1"
. "$PSScriptRoot/Schema.ps1"

$script:WkNominatimSearch = 'https://nominatim.openstreetmap.org/search'

function Get-WkPlaceholderVenues {
  <#
  .SYNOPSIS
    The venueKeys that are not one place: a various- or -area key, or a venue whose events fall
    in more than one town (Other doesn't count), such as an auction company or an estate sale
    site stored as the venue.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events)

  $towns = @{}
  foreach ($event in $Events) {
    $key = "$($event.venueKey)"
    if (-not $towns.ContainsKey($key)) { $towns[$key] = [Collections.Generic.HashSet[string]]::new() }
    if ($event.city -and $event.city -ne 'Other') { [void]$towns[$key].Add("$($event.city)") }
  }
  @($towns.Keys | Where-Object { $_ -like 'various-*' -or $_ -like '*-area' -or $towns[$_].Count -gt 1 } | Sort-Object)
}

function Get-WkNominatimBox {
  # The viewbox for lookups: about 150 miles each way from the city's coordinates.
  $center = (Get-WkCity).coordinates
  $dLat = 150 / 69.0
  $dLon = 150 / (69.0 * [Math]::Cos($center.lat * [Math]::PI / 180))
  $invariant = [Globalization.CultureInfo]::InvariantCulture
  (@(($center.lon - $dLon), ($center.lat + $dLat), ($center.lon + $dLon), ($center.lat - $dLat)) |
    ForEach-Object { ([Math]::Round($_, 3)).ToString($invariant) }) -join ','
}

function Update-WkVenueLocations {
  <#
  .SYNOPSIS
    Brings the venue location state up to date for the venues of -Events. Returns the state and
    counts (Looked: venues looked up, Found: of those, found; Feed: entries set from sources).
  .DESCRIPTION
    A manual entry is never changed. A venue a raw event has coordinates for takes the point
    reported most often, ties going to the first reported, and keeps a feed point it has even when
    its events name two towns (sources disagree about towns more than about points). Otherwise a
    placeholder venue (Get-WkPlaceholderVenues) is marked so and never looked up; once it no
    longer is one, it is looked up again. Any other venue with no entry, or a none entry checked
    30 days ago or more, is looked up: by the source's address when there is one, else by
    "venue, town, state". An answer must fall within 150 miles of the city (Test-WkNearCity) and
    be a place, not a whole town, county, or ZIP code. With no answer, an address's ZIP code is
    looked up. Requests are at least MinDelaySeconds apart, at most MaxLookups per run, and
    stop when BudgetSeconds have passed or after three failures in a row; a failed request warns
    and leaves the entry as it was. Entries of venues with no events now are kept, since venues
    come back.
  .PARAMETER RawEvents
    The raw events, whose location field holds what sources sent.
  .PARAMETER State
    venueKey to entry (lat, lon, address, from, checked). Updated in place.
  .PARAMETER Fetch
    Returns Nominatim's parsed answer for a URL, or throws. Defaults to Invoke-WkRequest. Used by tests.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawEvents,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][DateTimeOffset]$Now,
    [int]$MaxLookups = 300,
    [int]$BudgetSeconds = 300,
    [double]$MinDelaySeconds = 1,
    [scriptblock]$Fetch = { param([string]$Url) Invoke-WkRequest $Url -TimeoutSec 10 }
  )

  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $today = $Now.UtcDateTime.ToString('yyyy-MM-dd', $invariant)
  $retryBefore = $Now.UtcDateTime.AddDays(-30).ToString('yyyy-MM-dd', $invariant)
  $counts = @{ Looked = 0; Found = 0; Feed = 0 }
  # Requests so far and when the last one ended, shared with $ask.
  $clock = @{ requests = 0; last = $null; failures = 0 }
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $spent = { $clock.requests -ge $MaxLookups -or $timer.Elapsed.TotalSeconds -ge $BudgetSeconds -or $clock.failures -ge 3 }

  # What sources sent, by venue: each point with how often it was reported, and the first address.
  $points = @{}
  $addresses = @{}
  foreach ($raw in $RawEvents) {
    $location = $raw.location
    if (-not $location) { continue }
    $key = "$($raw.venueKey)"
    if ($location.address -and -not $addresses.ContainsKey($key)) { $addresses[$key] = "$($location.address)" }
    if ($null -eq $location.lat -or $null -eq $location.lon) { continue }
    if (-not $points.ContainsKey($key)) { $points[$key] = [ordered]@{} }
    $pair = '{0},{1}' -f ([double]$location.lat).ToString($invariant), ([double]$location.lon).ToString($invariant)
    if (-not $points[$key].Contains($pair)) { $points[$key][$pair] = [ordered]@{ count = 0; address = $null } }
    $points[$key][$pair].count++
    if ($location.address -and -not $points[$key][$pair].address) { $points[$key][$pair].address = "$($location.address)" }
  }

  # Each venue's town: the one most of its events name.
  $towns = @{}
  foreach ($event in $Events) {
    $key = "$($event.venueKey)"
    if (-not $towns.ContainsKey($key)) { $towns[$key] = @{ venue = "$($event.venue)"; cities = @{} } }
    if ($event.city -and $event.city -ne 'Other') { $towns[$key].cities["$($event.city)"] = 1 + [int]$towns[$key].cities["$($event.city)"] }
  }
  $placeholders = @(Get-WkPlaceholderVenues $Events)
  $stateName = (Get-WkCity).state.name
  $box = Get-WkNominatimBox

  # A town, county, or ZIP code is where a venue is, not the venue: a lookup of "Downtown Boise"
  # answers with Boise itself.
  $streetOnly = '^\s*\d+[A-Za-z]?\s+.*\b(St|Street|Rd|Road|Dr|Drive|Ave|Avenue|Ln|Lane|Way|Ct|Court|Pl|Place|Blvd|Boulevard|Cir|Circle|Loop|Trl|Trail|Pkwy|Parkway|Hwy|Highway|Ter|Terrace)\.?\s*(,.*)?$'
  $areaTypes = @('city', 'town', 'village', 'hamlet', 'municipality', 'county', 'state', 'region', 'postcode', 'country')
  $ask = {
    param([string]$Query, [switch]$Area)
    if ($null -ne $clock.last) {
      $wait = $MinDelaySeconds - ([DateTime]::UtcNow - $clock.last).TotalSeconds
      if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
    }
    $clock.requests++
    try {
      $answer = @(& $Fetch "$($script:WkNominatimSearch)?format=jsonv2&limit=1&countrycodes=us&$Query")
    } finally {
      $clock.last = [DateTime]::UtcNow
    }
    foreach ($place in $answer) {
      if (-not $Area -and "$($place.addresstype)" -in $areaTypes) { continue }
      $lat = ConvertTo-WkCoordinate $place.lat
      $lon = ConvertTo-WkCoordinate $place.lon
      if ($null -ne $lat -and $null -ne $lon -and (Test-WkNearCity -Latitude $lat -Longitude $lon)) { return @($lat, $lon) }
    }
    $null
  }

  foreach ($key in ($towns.Keys | Sort-Object)) {
    $entry = $State[$key]
    if ($entry -and $entry.from -eq 'manual') { continue }

    # A venue named only by a street address is most often someone's home (an estate sale, a
    # class in a living room), so it stays at its town's center and its address is not kept.
    $named = $key -like 'various-*' -or $key -like '*-area' -or $towns[$key].venue -match $streetOnly
    if ($named -or ($key -in $placeholders -and -not $points.ContainsKey($key) -and -not ($entry -and $entry.from -eq 'feed'))) {
      if (-not $entry -or $entry.from -ne 'placeholder') { $State[$key] = [ordered]@{ from = 'placeholder'; checked = $today } }
      continue
    }

    if ($points.ContainsKey($key)) {
      $best = $null
      foreach ($pair in $points[$key].Keys) {
        if (-not $best -or $points[$key][$pair].count -gt $points[$key][$best].count) { $best = $pair }
      }
      $lat, $lon = $best -split ',' | ForEach-Object { [double]::Parse($_, $invariant) }
      $address = $points[$key][$best].address
      if (-not $entry -or $entry.from -ne 'feed' -or $entry.lat -ne $lat -or $entry.lon -ne $lon -or $entry.address -ne $address) {
        $new = [ordered]@{ lat = $lat; lon = $lon }
        if ($address) { $new.address = $address }
        $new.from = 'feed'
        $new.checked = $today
        $State[$key] = $new
        $counts.Feed++
      }
      continue
    }

    $due = -not $entry -or $entry.from -eq 'placeholder' -or ($entry.from -eq 'none' -and "$($entry.checked)" -le $retryBefore)
    if (-not $due -or (& $spent)) { continue }

    $address = $addresses[$key]
    $town = @($towns[$key].cities.GetEnumerator() | Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, Name | Select-Object -First 1).Name
    $text = if ($address) { $address } else { (@($towns[$key].venue, $town, $stateName) | Where-Object { $_ }) -join ', ' }
    $counts.Looked++
    try {
      $from = 'lookup'
      $found = & $ask "bounded=1&viewbox=$box&q=$([uri]::EscapeDataString($text))"
      $zip = if ($address -match '\b(\d{5})(?:-\d{4})?\s*$') { $Matches[1] }
      if (-not $found -and $zip -and -not (& $spent)) {
        $from = 'zip'
        $found = & $ask "postalcode=$zip&country=us" -Area
      }
      $clock.failures = 0
      $new = [ordered]@{}
      if ($found) {
        $new.lat = $found[0]
        $new.lon = $found[1]
        if ($from -eq 'lookup') { $counts.Found++ }
      } else {
        $from = 'none'
      }
      if ($address) { $new.address = $address }
      $new.from = $from
      $new.checked = $today
      $State[$key] = $new
    } catch {
      $clock.failures++
      Write-Warning "venue lookup for '$($towns[$key].venue)' failed: $_"
    }
  }

  @{ State = $State; Looked = $counts.Looked; Found = $counts.Found; Feed = $counts.Feed }
}

function Read-WkVenueLocationState {
  # data/venue-locations.json as a hashtable of venueKey to entry, empty when the file is missing.
  param([Parameter(Mandatory, Position = 0)][string]$Path)

  $state = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $state }
  $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String
  foreach ($property in @($parsed.PSObject.Properties)) {
    $entry = [ordered]@{}
    foreach ($field in $property.Value.PSObject.Properties) {
      $entry[$field.Name] = if ($field.Name -in 'lat', 'lon') { [double]$field.Value } else { "$($field.Value)" }
    }
    $state[$property.Name] = $entry
  }
  $state
}

function Write-WkVenueLocationState {
  # Sorted by venueKey, fields in a fixed order, LF line endings, no BOM, so nightly diffs stay small.
  param([Parameter(Mandatory, Position = 0)][string]$Path, [Parameter(Mandatory, Position = 1)][hashtable]$State)

  $sorted = [ordered]@{}
  foreach ($key in ($State.Keys | Sort-Object)) {
    $entry = [ordered]@{}
    foreach ($name in 'lat', 'lon', 'address', 'from', 'checked') {
      if ($null -ne $State[$key][$name] -and "$($State[$key][$name])" -ne '') { $entry[$name] = $State[$key][$name] }
    }
    $sorted[$key] = $entry
  }
  $json = (($sorted | ConvertTo-Json -Depth 4) -replace "`r`n", "`n") + "`n"
  [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Test-WkVenueLocationFile {
  # The problems with a venue location file against schema/venue-locations.schema.json, one line
  # per entry that fails; nothing when it is valid.
  param([Parameter(Mandatory, Position = 0)][string]$Path)

  $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'schema' 'venue-locations.schema.json') -Raw
  $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String
  foreach ($property in @($parsed.PSObject.Properties)) {
    $json = @{ $property.Name = $property.Value } | ConvertTo-Json -Depth 4
    if (-not ($json | Test-Json -Schema $schema -ErrorAction SilentlyContinue)) {
      "data/venue-locations.json: '$($property.Name)' does not match schema/venue-locations.schema.json"
    }
  }
}
