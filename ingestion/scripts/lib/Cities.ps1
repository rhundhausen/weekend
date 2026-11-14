# Fills in the city for events stored as Other, from clues in their own text.

. "$PSScriptRoot/Schema.ps1"

function Get-WkZipCities {
  # ZIP code to city, from city.json: zipCodes, then zipRanges for ZIPs zipCodes does not list.
  Get-WkCityCached 'zipCities' {
    $city = Get-WkCity
    $map = @{}
    foreach ($zip in $city.zipCodes.Keys) { $map[$zip] = $city.zipCodes[$zip] }
    foreach ($range in $city.zipRanges) {
      foreach ($zip in ([int]$range.from)..([int]$range.to)) {
        $key = '{0:D5}' -f $zip
        if (-not $map.ContainsKey($key)) { $map[$key] = $range.city }
      }
    }
    $map
  }
}

function Get-WkAmbiguousCities {
  # Cities whose names are also everyday words or surnames ("star", "Emmett Till"), from city.json.
  # These are trusted only from a ZIP code or a "City, ST" pattern, never from a bare word.
  @((Get-WkCity).ambiguousCities)
}

function Get-WkCityNames {
  # Every city in city.json, longest first so "Garden City" wins over shorter names.
  Get-WkCityCached 'cityNames' { @((Get-WkCity).cities | Sort-Object Length -Descending) }
}

function Get-WkPlaceCities {
  # data/schema/place-cities.json in the city repo, loaded once.
  Get-WkCityCached 'placeCities' {
    Get-Content -LiteralPath (Get-WkCityPath 'data' 'schema' 'place-cities.json') -Raw | ConvertFrom-Json -AsHashtable
  }
}

function Remove-WkNonPlace {
  # Blanks out names that contain a city but aren't places in it, such as Boise Cascade.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowEmptyString()][string]$Text)

  foreach ($name in @((Get-WkPlaceCities).ignore)) {
    $Text = $Text -replace ('(?i)\b' + [regex]::Escape($name) + '\b'), ' '
  }
  $Text
}

function Find-WkPlace {
  # Cities of the known places named in the text.
  [CmdletBinding()]
  param([AllowEmptyString()][string]$Text)

  $places = (Get-WkPlaceCities).places
  @($places.Keys | Where-Object { $Text -match ('(?i)\b' + [regex]::Escape($_) + '(?!\w)') } | ForEach-Object { $places[$_] } | Select-Object -Unique)
}

function Find-WkCityWord {
  # Distinct cities named as whole words in the text, optionally only when followed by the state (", ID" or ", Idaho").
  [CmdletBinding()]
  param(
    [AllowEmptyString()][string]$Text,
    [switch]$WithState,
    [switch]$Unambiguous,
    [string]$Before = ''
  )

  if (-not $Text) { return @() }
  $found = [Collections.Generic.List[string]]::new()
  $ambiguous = Get-WkAmbiguousCities
  $state = Get-WkStatePattern
  foreach ($city in (Get-WkCityNames)) {
    if ($Unambiguous -and $city -in $ambiguous) { continue }
    $pattern = '(?i)' + $Before + '\b' + [regex]::Escape($city) + '\b' + ($WithState ? ",?\s+($state)\b" : '(?!\w)')
    if ($Text -match $pattern -and -not $found.Contains($city)) { $found.Add($city) }
  }
  $found.ToArray()
}

function Get-WkCityClue {
  <#
  .SYNOPSIS
    Infers an event's city from its venue, title, and description, or returns $null.
  .DESCRIPTION
    Tries clues from strongest to weakest and stops at the first that names cities:
    1. a ZIP code from city.json in the venue or description
    2. "City, ST" or "City, State" anywhere ("Boise, ID"), or "(City)" in the title
    3. a city name in the venue
    4. a known place from data/schema/place-cities.json, such as the Basque Block
    5. the venue's city, when other events place that venueKey in one city
    6. "in", "downtown", or "at" before a city name in the title or description
    7. a city name in the title
    8. a city name in the description
    A clue that names more than one city is ambiguous and ends the search with no answer.
    The city's ambiguousCities (such as Star) count only from clues 1 and 2. Names in the
    ignore list there, such as Boise Cascade, are not read as a city.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][object]$Event,
    [hashtable]$VenueCities = @{}
  )

  $venue = Remove-WkNonPlace "$($Event.venue)"
  $title = Remove-WkNonPlace "$($Event.title)"
  $description = Remove-WkNonPlace "$($Event.description)"
  $all = "$venue`n$title`n$description"

  # Each step runs only if the ones before it found nothing.
  $steps = @(
    { $zips = Get-WkZipCities; @([regex]::Matches("$venue`n$description", '\b\d{5}\b') | ForEach-Object { $zips[$_.Value] }) }
    { @(Find-WkCityWord $all -WithState) + @(Find-WkCityWord $title -Before '\(\s*' | Where-Object { $title -match ('(?i)\(\s*' + [regex]::Escape($_) + '\s*\)') }) }
    { Find-WkCityWord $venue -Unambiguous }
    { Find-WkPlace $all }
    { @(if ($VenueCities.ContainsKey("$($Event.venueKey)")) { $VenueCities["$($Event.venueKey)"] }) }
    { Find-WkCityWord "$title`n$description" -Unambiguous -Before '\b(in|downtown|at)\s+(the\s+)?' }
    { Find-WkCityWord $title -Unambiguous }
    { Find-WkCityWord $description -Unambiguous }
  )
  foreach ($step in $steps) {
    $cities = @(& $step | Where-Object { $_ } | Select-Object -Unique)
    if ($cities.Count -eq 1) { return $cities[0] }
    if ($cities.Count -gt 1) { return $null }
  }
  $null
}

function Get-WkVenueCities {
  # venueKey to city, for venues that events with a real city place in exactly one city.
  # A venue that also appears with city Other is a placeholder ("Various Treasure Valley locations"),
  # not a place, so it is left out even when a merge gave one of its events a city.
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events)

  $seen = @{}
  $placeholders = [Collections.Generic.HashSet[string]]::new()
  foreach ($event in $Events) {
    if (-not $event.venueKey) { continue }
    if (-not $event.city -or $event.city -eq 'Other') { $null = $placeholders.Add($event.venueKey); continue }
    if (-not $seen.ContainsKey($event.venueKey)) { $seen[$event.venueKey] = [Collections.Generic.HashSet[string]]::new() }
    $null = $seen[$event.venueKey].Add($event.city)
  }
  $map = @{}
  foreach ($key in $seen.Keys) {
    if ($seen[$key].Count -eq 1 -and -not $placeholders.Contains($key)) { $map[$key] = @($seen[$key])[0] }
  }
  $map
}

function Resolve-WkOtherCity {
  <#
  .SYNOPSIS
    Sets the city on events stored as Other when their text says where they are. Returns how many changed.
  .DESCRIPTION
    Only the city changes. The id is built from title, date, and venue, so it stays the same.
  .PARAMETER Known
    Extra events to learn venue cities from, such as the archive. The Events are always used.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events,
    [AllowEmptyCollection()][object[]]$Known = @()
  )

  $venueCities = Get-WkVenueCities (@($Events) + @($Known))
  $changed = 0
  foreach ($event in $Events) {
    if ($event.city -and $event.city -ne 'Other') { continue }
    $city = Get-WkCityClue $event -VenueCities $venueCities
    if ($city) {
      $event | Add-Member -NotePropertyName city -NotePropertyValue $city -Force
      $changed++
    }
  }
  $changed
}

function Resolve-WkTitleVenue {
  <#
  .SYNOPSIS
    Gives an event at a placeholder venue the venue its title names. Returns how many changed.
  .DESCRIPTION
    Aggregators list many events under one placeholder ("Various Treasure Valley locations",
    city Other) while the title names the place: "$3 Admission Day at Zoo Boise", "1st Sunday
    Brunch | Meriwether Cider". When the title ends in a known venue after "|", "@", a spaced
    dash, "at", or "at the", the event takes that venue's name, key, and city, and its id and size
    are rebuilt to match. After "|", "@", or a dash the venue is also dropped from the title, as
    New-WkEvent does; after "at" the title reads naturally and stays. Known venues are those other
    events place in exactly one city (Get-WkVenueCities), and the places in
    data/schema/place-cities.json. Anything else is left alone, since the words may name an event
    ("at Canyon County Festival of Trees", "| Dog Winter Photo Sessions"), not a place. Run it
    before Merge-WkEvents, so the event can merge with the venue's own listing.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events)

  $venueCities = Get-WkVenueCities $Events
  $names = @{}
  foreach ($event in $Events) {
    if ($event.venueKey -and $venueCities.ContainsKey($event.venueKey) -and -not $names.ContainsKey($event.venueKey)) {
      $names[$event.venueKey] = $event.venue
    }
  }

  $placeholders = @{}
  foreach ($event in $Events) {
    if ($event.venueKey -and -not $venueCities.ContainsKey($event.venueKey)) { $placeholders[$event.venueKey] = $true }
  }
  $places = (Get-WkPlaceCities).places
  foreach ($place in $places.Keys) {
    $key = Get-VenueKey $place
    if (-not $venueCities.ContainsKey($key)) {
      $venueCities[$key] = $places[$place]
      $names[$key] = $place
    }
  }

  $separator = "\s*[|@]\s*|\s+(?:-|$([char]0x2013)|$([char]0x2014))\s+"
  $changed = 0
  foreach ($event in $Events) {
    if (-not $placeholders.ContainsKey("$($event.venueKey)")) { continue }
    if ($event.city -and $event.city -ne 'Other') { continue }
    $title = "$($event.title)"
    $key = $null
    $rest = $null
    foreach ($pattern in @("^(?<rest>.+)(?:$separator)(?<the>)(?<venue>[^|@]+?)\s*[!.]?$", '^(?<keep>.+\sat\s+(?<the>the\s+)?(?<venue>.+?))\s*[!.]?$')) {
      $match = [regex]::Match($title, $pattern, 'IgnoreCase')
      if (-not $match.Success) { continue }
      $named = $match.Groups['venue'].Value
      # A bare city ("| Caldwell") says where, not at what venue.
      if (Resolve-WkCity $named.Trim()) { continue }
      foreach ($candidate in @("$($match.Groups['the'].Value)$named", $named)) {
        $try = Get-VenueKey $candidate
        $alias = Resolve-WkVenueAlias $try
        if ($alias) { $try = $alias.key }
        if ($venueCities.ContainsKey($try) -and -not $placeholders.ContainsKey($try)) { $key = $try; break }
      }
      if ($key) {
        if ($match.Groups['rest'].Success -and $match.Groups['rest'].Value.Trim().Length -ge 3) { $rest = $match.Groups['rest'].Value.Trim() }
        break
      }
    }
    if (-not $key) { continue }

    if ($rest) { $event | Add-Member -NotePropertyName title -NotePropertyValue $rest -Force }
    $event | Add-Member -NotePropertyName venue -NotePropertyValue $names[$key] -Force
    $event | Add-Member -NotePropertyName venueKey -NotePropertyValue $key -Force
    $event | Add-Member -NotePropertyName city -NotePropertyValue $venueCities[$key] -Force
    $event | Add-Member -NotePropertyName id -NotePropertyValue (Get-WkEventId $event.title $event.start $key) -Force
    $event | Add-Member -NotePropertyName size -NotePropertyValue (Get-WkEventSize -VenueKey $key -Category $event.category -Tags @($event.tags)) -Force
    $changed++
  }
  $changed
}
