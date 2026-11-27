# Locate's helpers: finding a venue's street address on its events' own pages, and turning an
# address into a point. No name searches: a point only ever comes from an address.

. "$PSScriptRoot/Scrape.ps1"
. "$PSScriptRoot/Schema.ps1"
. "$PSScriptRoot/VenueLocations.ps1"

$script:WkStreetTypes = 'St|Street|Rd|Road|Dr|Drive|Ave|Avenue|Ln|Lane|Way|Ct|Court|Pl|Place|Blvd|Boulevard|Cir|Circle|Loop|Trl|Trail|Pkwy|Parkway|Hwy|Highway|Ter|Terrace|Sq|Square|Plaza|Pike|Row|Run|Path|Pass|Xing|Crossing'

function ConvertTo-WkNameKey {
  # A name for comparing: lowercase, no accents or punctuation, no leading "the", single spaces.
  param([AllowEmptyString()][string]$Name)
  $text = (Remove-Diacritics "$Name").ToLowerInvariant() -replace '&', ' and ' -replace '[^a-z0-9]+', ' '
  ($text.Trim() -replace '^the ', '').Trim()
}

function Test-WkNameMatch {
  <#
  .SYNOPSIS
    Whether two names are the same place or event: equal after ConvertTo-WkNameKey, or every
    word of the shorter is in the longer and the shorter has at least two words.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$A,
    [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$B
  )
  $a = ConvertTo-WkNameKey $A
  $b = ConvertTo-WkNameKey $B
  if (-not $a -or -not $b) { return $false }
  if ($a -eq $b) { return $true }
  $wordsA = @($a -split ' ')
  $wordsB = @($b -split ' ')
  $short, $long = if ($wordsA.Count -le $wordsB.Count) { $wordsA, $wordsB } else { $wordsB, $wordsA }
  if ($short.Count -lt 2) { return $false }
  foreach ($word in $short) { if ($word -notin $long) { return $false } }
  $true
}

function Get-WkAddressRegex {
  # A US street address in running text: number, street, optional unit, town, state, ZIP.
  $state = (Get-WkCity).state
  $regions = "[A-Z]{2}|$([regex]::Escape($state.name))"
  "(?<street>\b\d{1,6}[A-Za-z]?\s+(?:[NSEW]\.?\s+)?[A-Za-z0-9.' ]{1,40}?\b(?:$($script:WkStreetTypes))\b\.?(?:\s+(?:N|S|E|W|NE|NW|SE|SW)\b)?(?:,?\s*(?:Suite|Ste\.?|Unit|Apt\.?|#)\s*[\w-]+)?),?\s+(?<town>[A-Za-z][A-Za-z .'-]{1,30}?),?\s+(?<state>$regions)\.?,?\s+(?<zip>\d{5})(?:-\d{4})?\b"
}

function ConvertFrom-WkAddressText {
  # One address line from text that is itself an address ("123 Main St, Boise, ID 83702"), or
  # $null when it isn't one.
  param([AllowEmptyString()][string]$Text)
  $match = [regex]::Match("$Text", (Get-WkAddressRegex))
  if (-not $match.Success) { return $null }
  ConvertTo-WkAddressLine -Street $match.Groups['street'].Value -Town $match.Groups['town'].Value -State $match.Groups['state'].Value -Zip $match.Groups['zip'].Value
}

function Repair-WkAddressLine {
  <#
  .SYNOPSIS
    An address line as pages really write them, made tidy: entities decoded, a country, empty
    parts, and repeated parts dropped ("6427 W Ustick Rd,, Boise, ID, Boise, ID" becomes "6427 W
    Ustick Rd, Boise, ID"), and a full address inside it taken as written. $null unless it starts
    with a house number, since "Boise, ID" is a town, not a venue's address.
  #>
  param([AllowEmptyString()][AllowNull()][string]$Line)
  $text = [Net.WebUtility]::HtmlDecode("$Line") -replace '\s+', ' '
  $full = ConvertFrom-WkAddressText $text
  if ($full) { return $full }
  $parts = [Collections.Generic.List[string]]::new()
  foreach ($part in ($text -split ',')) {
    $part = $part.Trim()
    if (-not $part -or $part -match '^(USA|US|United States( of America)?)$') { continue }
    if ($parts -notcontains $part) { $parts.Add($part) }
  }
  if (-not $parts.Count -or $parts[0] -notmatch '^\d') { return $null }
  $parts -join ', '
}

function ConvertFrom-WkLdAddress {
  # The address line of a schema.org location (a Place, or an address object or string).
  param($Location)
  if ($null -eq $Location) { return $null }
  $address = if ($Location -is [string]) { $Location } elseif ($Location.PSObject.Properties['address']) { $Location.address } else { $Location }
  if ($address -is [array]) { $address = @($address)[0] }
  if ($address -is [string]) { return Repair-WkAddressLine $address }
  if ($null -eq $address -or -not $address.PSObject.Properties['streetAddress']) { return $null }
  $street = [Net.WebUtility]::HtmlDecode("$($address.streetAddress)")
  $full = ConvertFrom-WkAddressText $street
  if ($full) { return $full }
  Repair-WkAddressLine (ConvertTo-WkAddressLine -Street ($street.Trim().TrimEnd(',')) -Town "$($address.addressLocality)" -State "$($address.addressRegion)" -Zip "$($address.postalCode)")
}

function Get-WkLdNodes {
  # Every JSON-LD object on a page, flattened through arrays and @graph.
  param([string]$Html)
  foreach ($block in [regex]::Matches($Html, '(?is)<script[^>]*application/ld\+json[^>]*>(.*?)</script>')) {
    try { $parsed = ConvertFrom-WkJson $block.Groups[1].Value.Trim() } catch { continue }
    $queue = [Collections.Generic.Queue[object]]::new()
    foreach ($item in @($parsed)) { $queue.Enqueue($item) }
    while ($queue.Count) {
      $node = $queue.Dequeue()
      if ($null -eq $node -or $node -is [string] -or $node -is [ValueType]) { continue }
      if ($node.PSObject.Properties['@graph']) { foreach ($item in @($node.'@graph')) { $queue.Enqueue($item) } }
      $node
    }
  }
}

function Get-WkPageAddress {
  <#
  .SYNOPSIS
    The address of -Venue as an event page states it, or $null.
  .DESCRIPTION
    In order: a JSON-LD Event whose name matches -Title, its location's address; a JSON-LD place
    (an event's location, or a node of its own) whose name matches -Venue; schema.org microdata
    whose streetAddress follows a name matching -Venue; a street address in the page's text with
    the venue's name in the 200 characters before it. Anything not tied to this event or venue
    is ignored, because listing pages carry many events and footers the organizer's address.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Html,
    [Parameter(Mandatory)][string]$Venue,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Title
  )

  $nodes = @(Get-WkLdNodes $Html)
  foreach ($node in $nodes) {
    if (@($node.'@type') -match 'Event$' -and (Test-WkNameMatch "$($node.name)" $Title)) {
      foreach ($location in @($node.location)) {
        $line = ConvertFrom-WkLdAddress $location
        if ($line) { return $line }
      }
    }
  }
  foreach ($node in $nodes) {
    $places = if (@($node.'@type') -match 'Event$') { @($node.location) } else { @($node) }
    foreach ($place in $places) {
      if ($place -is [string] -or $null -eq $place -or -not $place.PSObject.Properties['name']) { continue }
      if (Test-WkNameMatch "$($place.name)" $Venue) {
        $line = ConvertFrom-WkLdAddress $place
        if ($line) { return $line }
      }
    }
  }

  # Microdata: a streetAddress whose place's name, within the 1,500 characters before it, matches.
  foreach ($street in [regex]::Matches($Html, '(?is)itemprop="streetAddress"[^>]*>(.*?)</')) {
    $before = $Html.Substring([Math]::Max(0, $street.Index - 1500), [Math]::Min(1500, $street.Index))
    $names = [regex]::Matches($before, '(?is)itemprop="name"[^>]*>(.*?)</')
    if (-not $names.Count -or -not (Test-WkNameMatch (ConvertTo-PlainText $names[$names.Count - 1].Groups[1].Value) $Venue)) { continue }
    $after = $Html.Substring($street.Index, [Math]::Min(800, $Html.Length - $street.Index))
    $part = { param($name) $m = [regex]::Match($after, "(?is)itemprop=""$name""[^>]*>(.*?)</"); if ($m.Success) { ConvertTo-PlainText $m.Groups[1].Value } }
    $line = Repair-WkAddressLine (ConvertTo-WkAddressLine -Street (ConvertTo-PlainText $street.Groups[1].Value) -Town (& $part 'addressLocality') -State (& $part 'addressRegion') -Zip (& $part 'postalCode'))
    if ($line) { return $line }
  }

  # Text: an address with the venue's name just before it.
  $text = ConvertTo-PlainText ($Html -replace '(?i)<br\s*/?>', ', ')
  $venueKey = ConvertTo-WkNameKey $Venue
  if (-not $venueKey) { return $null }
  foreach ($match in [regex]::Matches($text, (Get-WkAddressRegex))) {
    $window = $text.Substring([Math]::Max(0, $match.Index - 200), [Math]::Min(200, $match.Index))
    if ((" $(ConvertTo-WkNameKey $window) ").Contains(" $venueKey ")) {
      return ConvertTo-WkAddressLine -Street $match.Groups['street'].Value -Town $match.Groups['town'].Value -State $match.Groups['state'].Value -Zip $match.Groups['zip'].Value
    }
  }
  $null
}

function Find-WkAddressPoint {
  <#
  .SYNOPSIS
    A point for a street address: @{ lat; lon; from }, from 'address' for the address itself or
    'zip' for its ZIP code's center, or $null.
  .DESCRIPTION
    Asks, in order: the US Census Bureau geocoder (official street records, free, no key);
    Nominatim's structured search by the address's parts (never by a name), rejecting answers
    that are a whole town, county, or ZIP code; Nominatim for the ZIP code's center. A point must
    be near the city (Test-WkNearCity). -Health counts each service's failures in a row (a
    timeout, a connection error, a 5xx); at three it is skipped for the rest of the run. A 4xx
    or an empty answer is not a failure.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Address,
    [Parameter(Mandatory)][scriptblock]$Fetch,
    [Parameter(Mandatory)][hashtable]$Health
  )

  $ask = {
    param([string]$Service, [string]$Url)
    if ([int]$Health[$Service] -ge 3) { return $null }
    try {
      $answer = & $Fetch $Url
      $Health[$Service] = 0
      , $answer
    } catch {
      if ("$_" -notmatch 'HTTP 4\d\d') {
        $Health[$Service] = [int]$Health[$Service] + 1
        Write-Warning "$Service request failed: $_"
      }
      $null
    }
  }
  $near = {
    param($lat, $lon)
    $lat = ConvertTo-WkCoordinate $lat
    $lon = ConvertTo-WkCoordinate $lon
    if ($null -ne $lat -and $null -ne $lon -and (Test-WkNearCity -Latitude $lat -Longitude $lon)) { @($lat, $lon) }
  }
  $escape = { param($text) [uri]::EscapeDataString("$text") }

  $census = & $ask 'census' "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?address=$(& $escape $Address)&benchmark=Public_AR_Current&format=json"
  foreach ($match in @($census.result.addressMatches)) {
    if (-not $match) { continue }
    $point = & $near $match.coordinates.y $match.coordinates.x
    if ($point) { return @{ lat = $point[0]; lon = $point[1]; from = 'address' } }
  }

  # "street[, unit], town, ST 12345"
  $parts = @($Address -split '\s*,\s*' | Where-Object { $_ })
  $zip = if ($Address -match '\b(\d{5})(?:-\d{4})?\s*$') { $Matches[1] }
  $areaTypes = @('city', 'town', 'village', 'hamlet', 'municipality', 'county', 'state', 'region', 'postcode', 'country')
  $search = 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&countrycodes=us'
  if ($parts.Count -ge 3) {
    $stateZip = $parts[-1] -replace '\s*\d{5}(?:-\d{4})?\s*$', ''
    $query = "street=$(& $escape ($parts[0..($parts.Count - 3)] -join ', '))&city=$(& $escape $parts[-2])&state=$(& $escape $stateZip)"
    if ($zip) { $query += "&postalcode=$zip" }
    foreach ($place in @(& $ask 'nominatim' "$search&$query")) {
      if (-not $place -or "$($place.addresstype)" -in $areaTypes) { continue }
      $point = & $near $place.lat $place.lon
      if ($point) { return @{ lat = $point[0]; lon = $point[1]; from = 'address' } }
    }
  }
  if ($zip) {
    foreach ($place in @(& $ask 'nominatim' "$search&postalcode=$zip&country=us")) {
      if (-not $place) { continue }
      $point = & $near $place.lat $place.lon
      if ($point) { return @{ lat = $point[0]; lon = $point[1]; from = 'zip' } }
    }
  }
  $null
}

function Update-WkVenueAddresses {
  <#
  .SYNOPSIS
    Locate's pass over the venues: finds street addresses on events' own pages, or in what
    sources sent, and turns them into points. Returns @{ State; Summary }.
  .DESCRIPTION
    Works on venues of -Events whose entry is missing, none, zip, or lookup (the old name
    search), and page or address entries checked 90 days ago or more; never manual, feed, or
    placeholder entries, nor a venue named only by a street address. Busiest venues first.

    For each, it reads up to -MaxPagesPerVenue of its events' pages (never google.com, only where
    robots.txt allows) and takes the address most of them give (Get-WkPageAddress), ties to the
    first; else the address a source sent. Find-WkAddressPoint turns it into a point. An answer
    replaces the entry unless it is worse than a point the entry already has: finding nothing
    keeps a page, address, lookup, or zip entry and only updates checked.

    Requests to one host are at least -MinDelaySeconds apart. A host or a geocoding service that
    fails three times in a row (a timeout, a connection error, a 5xx) is skipped for the rest of
    the run. The run stops when -BudgetSeconds have passed.
  .PARAMETER Fetch
    Gets a URL: with -Raw the body as text, otherwise parsed JSON; throws on failure. Defaults to
    Invoke-WkRequest. Used by tests.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawEvents,
    [Parameter(Mandatory)][hashtable]$State,
    [Parameter(Mandatory)][DateTimeOffset]$Now,
    [int]$BudgetSeconds = 2700,
    [int]$MaxPagesPerVenue = 3,
    [double]$MinDelaySeconds = 1,
    [scriptblock]$Fetch = { param([string]$Url, [switch]$Raw) Invoke-WkRequest $Url -Raw:$Raw -TimeoutSec 15 }
  )

  $invariant = [Globalization.CultureInfo]::InvariantCulture
  $today = $Now.UtcDateTime.ToString('yyyy-MM-dd', $invariant)
  $recheckBefore = $Now.UtcDateTime.AddDays(-90).ToString('yyyy-MM-dd', $invariant)
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $summary = [ordered]@{
    tried = 0; pages = 0; robotsSkipped = 0
    found = [ordered]@{ page = 0; address = 0; zip = 0 }
    none = 0; kept = 0; hostsSkipped = @(); services = @{}; stoppedEarly = $false; seconds = 0
  }

  # Requests to one host at least MinDelaySeconds apart.
  $last = @{}
  $inner = $Fetch
  $delay = $MinDelaySeconds
  $throttled = {
    param([string]$Url, [switch]$Raw)
    $hostName = ([uri]$Url).Host
    if ($last.ContainsKey($hostName)) {
      $wait = $delay - ([DateTime]::UtcNow - $last[$hostName]).TotalSeconds
      if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
    }
    try { & $inner $Url -Raw:$Raw } finally { $last[$hostName] = [DateTime]::UtcNow }
  }.GetNewClosure()

  # Upcoming events by venue, busiest first; ties keep the order venues first appear in.
  $venues = [ordered]@{}
  foreach ($event in $Events) {
    $key = "$($event.venueKey)"
    if (-not $key) { continue }
    if (-not $venues.Contains($key)) { $venues[$key] = [ordered]@{ key = $key; venue = "$($event.venue)"; count = 0; pages = [ordered]@{} } }
    $venues[$key].count++
    if ($event.url -and -not $venues[$key].pages.Contains("$($event.url)")) { $venues[$key].pages["$($event.url)"] = "$($event.title)" }
  }
  # Addresses sources sent without a point, by venue, most often sent first.
  $feedAddresses = @{}
  foreach ($raw in $RawEvents) {
    $address = "$($raw.location.address)"
    if (-not $address) { continue }
    $key = "$($raw.venueKey)"
    if (-not $feedAddresses.ContainsKey($key)) { $feedAddresses[$key] = [ordered]@{} }
    $feedAddresses[$key][$address] = 1 + [int]$feedAddresses[$key][$address]
  }
  $mostGiven = {
    param($counts)
    $best = $null
    foreach ($item in $counts.Keys) { if (-not $best -or $counts[$item] -gt $counts[$best]) { $best = $item } }
    $best
  }

  $streetOnly = Get-WkStreetOnlyPattern
  $rank = @{ none = 0; zip = 1; lookup = 2; address = 3; page = 3 }
  $queue = @($venues.Values | Where-Object {
      $entry = $State[$_.key]
      if ($_.venue -match $streetOnly) { return $false }
      if (-not $entry) { return $true }
      switch ("$($entry.from)") {
        { $_ -in 'none', 'zip', 'lookup' } { return $true }
        { $_ -in 'page', 'address' } { return "$($entry.checked)" -le $recheckBefore }
        default { return $false }
      }
    } | Sort-Object -Stable -Property @{ Expression = { $_.count }; Descending = $true })

  $robots = @{}
  $hostFailures = @{}
  $spent = { $timer.Elapsed.TotalSeconds -ge $BudgetSeconds }
  $isFailure = { param($err) "$err" -notmatch 'HTTP 4\d\d' }

  foreach ($venue in $queue) {
    if (& $spent) { $summary.stoppedEarly = $true; break }
    $summary.tried++
    $found = [ordered]@{}
    $read = 0
    foreach ($url in $venue.pages.Keys) {
      if ($read -ge $MaxPagesPerVenue) { break }
      if (& $spent) { break }
      try { $uri = [uri]$url } catch { continue }
      if ($uri.Scheme -notin 'http', 'https' -or $uri.Host -match '(^|\.)google\.com$') { continue }
      $hostName = $uri.Host
      if ([int]$hostFailures[$hostName] -ge 3) { continue }
      if (-not $robots.ContainsKey($hostName)) {
        try {
          $robots[$hostName] = "$(& $throttled "$($uri.Scheme)://$hostName/robots.txt" -Raw)"
        } catch {
          if (& $isFailure $_) {
            $hostFailures[$hostName] = [int]$hostFailures[$hostName] + 1
            Write-Warning "robots.txt for $hostName failed: $_"
            continue
          }
          $robots[$hostName] = ''
        }
      }
      if (-not (Test-WkRobotsAllowed $robots[$hostName] $uri.PathAndQuery)) { $summary.robotsSkipped++; continue }
      $read++
      try {
        $html = & $throttled $url -Raw
        $hostFailures[$hostName] = 0
        $summary.pages++
      } catch {
        if (& $isFailure $_) {
          $hostFailures[$hostName] = [int]$hostFailures[$hostName] + 1
          Write-Warning "page for '$($venue.venue)' failed: $_"
        }
        continue
      }
      $address = Get-WkPageAddress -Html "$html" -Venue $venue.venue -Title $venue.pages[$url]
      if ($address) { $found[$address] = 1 + [int]$found[$address] }
    }

    $address = & $mostGiven $found
    $source = 'page'
    if (-not $address -and $feedAddresses.ContainsKey($venue.key)) {
      $address = & $mostGiven $feedAddresses[$venue.key]
      $source = 'address'
    }
    $point = if ($address -and -not (& $spent)) { Find-WkAddressPoint -Address $address -Fetch $throttled -Health $summary.services }

    $new = [ordered]@{}
    if ($point) {
      $new.lat = $point.lat
      $new.lon = $point.lon
    }
    if ($address) { $new.address = $address }
    $new.from = if (-not $point) { 'none' } elseif ($point.from -eq 'zip') { 'zip' } else { $source }
    $new.checked = $today

    $entry = $State[$venue.key]
    if ($entry -and $rank["$($entry.from)"] -gt $rank[$new.from] -or ($entry -and $rank["$($entry.from)"] -eq $rank[$new.from] -and $new.from -eq 'none')) {
      $entry.checked = $today
      $summary.kept++
    } else {
      $State[$venue.key] = $new
      if ($new.from -eq 'none') { $summary.none++ } else { $summary.found[$new.from]++ }
    }
  }

  $summary.hostsSkipped = @($hostFailures.Keys | Where-Object { $hostFailures[$_] -ge 3 } | Sort-Object)
  $summary.seconds = [int]$timer.Elapsed.TotalSeconds
  @{ State = $State; Summary = $summary }
}
