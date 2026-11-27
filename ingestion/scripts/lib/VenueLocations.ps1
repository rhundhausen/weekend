# Where each venue is, for the site's map, kept in data/venue-locations.json keyed by venueKey.
# Refine (Update-WkVenueLocations) records the locations sources send and marks venues that are not
# one place; it makes no requests. Locate (VenueAddress.ps1, Invoke-Locate.ps1) finds the street
# addresses of the rest on their events' pages. The site puts an event with no entry at its town's
# center (city.json cityCenters).

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

function Get-WkStreetOnlyPattern {
  # A venue name that is only a street address ("7497 W Whisper Rdg Dr"). Such a venue is most
  # often someone's home (an estate sale, a class in a living room), so it stays at its town's
  # center and its address is not kept.
  '^\s*\d+[A-Za-z]?\s+.*\b(St|Street|Rd|Road|Dr|Drive|Ave|Avenue|Ln|Lane|Way|Ct|Court|Pl|Place|Blvd|Boulevard|Cir|Circle|Loop|Trl|Trail|Pkwy|Parkway|Hwy|Highway|Ter|Terrace)\.?\s*(,.*)?$'
}

function Update-WkVenueLocations {
  <#
  .SYNOPSIS
    Refine's part of the venue location state: what sources sent, and which venues are not one
    place. It makes no requests; locate (Invoke-Locate.ps1) finds addresses for the rest. Returns
    the state and Feed, the entries set from sources.
  .DESCRIPTION
    A manual entry is never changed. A venue a raw event has coordinates for takes the point
    reported most often, ties going to the first reported, and replaces any entry but manual (a
    source's own location is taken as correct), even when its events name two towns. Otherwise a
    placeholder venue (Get-WkPlaceholderVenues, or a name that is only a street address) is marked
    so, unless it has a feed point; a placeholder entry whose venue is now one place is removed, so
    locate takes it up. Every other entry is locate's and is left alone. Entries of venues with no
    events now are kept, since venues come back.
  .PARAMETER RawEvents
    The raw events, whose location field holds what sources sent.
  .PARAMETER State
    venueKey to entry (lat, lon, address, from, checked). Updated in place.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawEvents,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][DateTimeOffset]$Now
  )

  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $today = $Now.UtcDateTime.ToString('yyyy-MM-dd', $invariant)
  $feed = 0

  # What sources sent, by venue: each point with how often it was reported, and its first address.
  $points = @{}
  foreach ($raw in $RawEvents) {
    $location = $raw.location
    if (-not $location -or $null -eq $location.lat -or $null -eq $location.lon) { continue }
    $key = "$($raw.venueKey)"
    if (-not $points.ContainsKey($key)) { $points[$key] = [ordered]@{} }
    $pair = '{0},{1}' -f ([double]$location.lat).ToString($invariant), ([double]$location.lon).ToString($invariant)
    if (-not $points[$key].Contains($pair)) { $points[$key][$pair] = [ordered]@{ count = 0; address = $null } }
    $points[$key][$pair].count++
    if ($location.address -and -not $points[$key][$pair].address) { $points[$key][$pair].address = "$($location.address)" }
  }

  $names = @{}
  foreach ($event in $Events) { if (-not $names.ContainsKey("$($event.venueKey)")) { $names["$($event.venueKey)"] = "$($event.venue)" } }
  $placeholders = @(Get-WkPlaceholderVenues $Events)
  $streetOnly = Get-WkStreetOnlyPattern

  foreach ($key in ($names.Keys | Sort-Object)) {
    $entry = $State[$key]
    if ($entry -and $entry.from -eq 'manual') { continue }

    $named = $key -like 'various-*' -or $key -like '*-area' -or $names[$key] -match $streetOnly
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
        $feed++
      }
      continue
    }

    if ($entry -and $entry.from -eq 'placeholder') { $State.Remove($key) }
  }

  @{ State = $State; Feed = $feed }
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
