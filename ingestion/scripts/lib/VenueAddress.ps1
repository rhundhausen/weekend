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

function ConvertFrom-WkLdAddress {
  # The address line of a schema.org location (a Place, or an address object or string).
  param($Location)
  if ($null -eq $Location) { return $null }
  $address = if ($Location -is [string]) { $Location } elseif ($Location.PSObject.Properties['address']) { $Location.address } else { $Location }
  if ($address -is [array]) { $address = @($address)[0] }
  if ($address -is [string]) { return ConvertFrom-WkAddressText $address }
  if ($null -eq $address -or -not $address.PSObject.Properties['streetAddress']) { return $null }
  $region = "$($address.addressRegion)"
  ConvertTo-WkAddressLine -Street "$($address.streetAddress)" -Town "$($address.addressLocality)" -State $region -Zip "$($address.postalCode)"
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
    $line = ConvertTo-WkAddressLine -Street (ConvertTo-PlainText $street.Groups[1].Value) -Town (& $part 'addressLocality') -State (& $part 'addressRegion') -Zip (& $part 'postalCode')
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
