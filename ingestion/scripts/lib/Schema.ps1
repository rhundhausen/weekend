# Event schema helpers. See schema/event.schema.json and docs/schema.md.

. "$PSScriptRoot/City.ps1"
. "$PSScriptRoot/Cost.ps1"

function Get-WkTimeZone {
  # The city's zone, from city.json.
  Get-WkCityCached 'timeZone' { [TimeZoneInfo]::FindSystemTimeZoneById((Get-WkCity).timeZone) }
}

function ConvertTo-LocalTime {
  <#
  .SYNOPSIS
    Converts a DateTime, DateTimeOffset, or string to ISO 8601 with the city's offset.
  .DESCRIPTION
    A value with no zone information of its own (an unspecified DateTime, or a string with no
    offset) is read as SourceTimeZone, which defaults to the city's time zone (city.json).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory, Position = 0)]
    [object]$Value,

    [Parameter(Position = 1)]
    [string]$SourceTimeZone
  )

  $local = Get-WkTimeZone
  $sourceZone = if ($SourceTimeZone) { [TimeZoneInfo]::FindSystemTimeZoneById($SourceTimeZone) } else { $local }
  $invariant = [Globalization.CultureInfo]::InvariantCulture

  if ($Value -is [string]) {
    if ($Value -match '(Z|[+-]\d{2}:?\d{2})$') {
      $Value = [DateTimeOffset]::Parse($Value, $invariant)
    } else {
      $Value = [DateTime]::SpecifyKind([DateTime]::Parse($Value, $invariant), [DateTimeKind]::Unspecified)
    }
  }

  $instant = switch ($Value) {
    { $_ -is [DateTimeOffset] } { $_; break }
    { $_ -is [DateTime] -and $_.Kind -ne [DateTimeKind]::Unspecified } { [DateTimeOffset]::new($_); break }
    { $_ -is [DateTime] } { [DateTimeOffset]::new($_, $sourceZone.GetUtcOffset($_)); break }
    default { throw "Cannot convert value of type $($Value.GetType().Name) to a local time" }
  }

  [TimeZoneInfo]::ConvertTime($instant, $local).ToString('yyyy-MM-ddTHH:mm:sszzz', $invariant)
}

function Get-WkEventInstant {
  # Date-only values count as midnight in the city.
  [CmdletBinding()]
  [OutputType([DateTimeOffset])]
  param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Value
  )

  if ($Value.Length -eq 10) {
    $Value = ConvertTo-LocalTime "$Value 00:00:00"
  }
  [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Remove-Diacritics {
  param([string]$Text)

  $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
  ($decomposed -replace '\p{Mn}', '').Normalize([Text.NormalizationForm]::FormC)
}

function Get-NormalizedTitle {
  # Lowercase words separated by single spaces, so punctuation differences don't split an event.
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory, Position = 0)]
    [AllowEmptyString()]
    [string]$Title
  )

  $text = (Remove-Diacritics $Title).ToLowerInvariant() -replace "['‘’]", ''
  ($text -replace '[^\p{L}\p{Nd}]+', ' ').Trim()
}

function Get-VenueKey {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory, Position = 0)]
    [AllowEmptyString()]
    [string]$Name
  )

  $text = (Remove-Diacritics $Name).ToLowerInvariant() -replace "['‘’]", '' -replace '&', ' and '
  ($text -replace '[^a-z0-9]+', '-').Trim('-')
}

function ConvertTo-PlainText {
  # Strips markup and decodes entities. Publishers send HTML in titles and descriptions.
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Position = 0)]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Text
  )

  if (-not $Text) { return '' }
  $stripped = $Text -replace '(?is)<(script|style)\b.*?</\1>', ' ' -replace '<[^>]+>', ' '
  ([System.Net.WebUtility]::HtmlDecode($stripped) -replace '\s+', ' ').Trim()
}

function Resolve-WkCity {
  # Maps a free-form city name to the schema enum, or returns $null when it isn't one.
  [CmdletBinding()]
  param(
    [Parameter(Position = 0)]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Name
  )

  # The city's cities, and its cityAliases: other place names that count as one of them.
  $names = Get-WkCityCached 'resolveCity' {
    $city = Get-WkCity
    $map = @{}
    foreach ($alias in $city.cityAliases.Keys) { $map[$alias.ToLowerInvariant()] = $city.cityAliases[$alias] }
    foreach ($name in $city.cities) { $map[$name.ToLowerInvariant()] = $name }
    $map
  }
  if (-not $Name) { return $null }
  $names[$Name.Trim().ToLowerInvariant()]
}

function ConvertFrom-WkLocation {
  <#
  .SYNOPSIS
    Splits a free-form location into venue, venueKey, and city, using the source's fallbacks.
  .DESCRIPTION
    Feeds disagree on order ("Boise, Idaho, ExtraMile Arena" and "Idaho Central Arena, Boise, Idaho"),
    so known cities and the state are removed and the first remaining part is the venue. A room
    or building code after the venue name is dropped so the key matches other sources.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Position = 0)]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Location,

    [Parameter(Mandatory)]
    [pscustomobject]$Source
  )

  $city = $null
  $remaining = [System.Collections.Generic.List[string]]::new()
  foreach ($part in ($Location -split ',')) {
    $part = $part.Trim()
    if (-not $part -or $part -match "^($(Get-WkStatePattern))(\s+\d{5}(-\d{4})?)?$" -or $part -match '^\d{5}(-\d{4})?$') { continue }
    $known = Resolve-WkCity $part
    if ($known) {
      if (-not $city) { $city = $known }
    } else {
      $remaining.Add($part)
    }
  }

  $venue = if ($remaining.Count -gt 0) { $remaining[0] -replace '\s*\([A-Z0-9]{2,6}\)$', '' }
  [pscustomobject]@{
    Venue    = if ($venue) { $venue } else { $Source.venue }
    VenueKey = if ($venue) { Get-VenueKey $venue } else { $Source.venueKey }
    City     = if ($city) { $city } else { $Source.city }
  }
}

function Get-WkTagRules {
  # Loads the tags (ingestion/vocabulary/tags.json plus the city's data/schema/tags.json) once and
  # compiles one regex per tag. A tag with no keywords matches only its sourceLabels.
  Get-WkCityCached 'tagRules' {
    @(Get-WkVocabulary tags | ForEach-Object {
        $keywords = @($_.keywords | Where-Object { $_ })
        $pattern = if ($keywords) { '\b(' + (($keywords | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b' } else { '(?!)' }
        [pscustomobject]@{
          Id       = $_.id
          Category = $_.category
          Regex    = [regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::Compiled)
          Labels   = @($_.sourceLabels)
          Fallback = [bool]$_.fallback
        }
      })
  }
}

function Get-WkClassification {
  <#
  .SYNOPSIS
    Finds an event's tags from keywords, and the category those tags point to.
  .DESCRIPTION
    Text is compared after Get-NormalizedTitle, so keywords in tags.json are lowercase with no
    punctuation. A tag with a category needs a match in the title or the publisher's labels,
    because descriptions mention too many unrelated things. A tag with no category, like
    kids, can also match the description.

    A category from a title match beats one from a label. Within those, the list below
    decides, because a Christmas concert is a holiday event first. A tag marked fallback in
    tags.json, like library-program, sets the category only when no other tag did at the same
    level: in "Teen Club: Dungeons and Dragons | Cole & Ustick Library!" the library is the venue.
  .PARAMETER Labels
    The publisher's own categories or genres, such as "Arts & Music". Each is tested against
    the keywords and against sourceLabels in tags.json.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Title,

    [Parameter(Position = 1)]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Description,

    [AllowEmptyCollection()]
    [string[]]$Labels = @()
  )

  $order = 'holiday-seasonal', 'festivals', 'sports', 'auctions-estate-sales', 'markets-shopping', 'food-drink', 'performing-arts', 'music',
  'arts-culture', 'outdoors-recreation', 'learning-business', 'nightlife-social', 'community-civic'

  $titleText = Get-NormalizedTitle $Title
  $bodyText = Get-NormalizedTitle (ConvertTo-PlainText $Description)
  $labelTexts = @($Labels | Where-Object { $_ } | ForEach-Object { Get-NormalizedTitle (ConvertTo-PlainText $_) })
  $tags = [System.Collections.Generic.List[string]]::new()
  $titleCategories = [System.Collections.Generic.HashSet[string]]::new()
  $labelCategories = [System.Collections.Generic.HashSet[string]]::new()
  $titleFallbacks = [System.Collections.Generic.HashSet[string]]::new()
  $labelFallbacks = [System.Collections.Generic.HashSet[string]]::new()

  foreach ($rule in (Get-WkTagRules)) {
    $inTitle = $rule.Regex.IsMatch($titleText)
    $inLabels = @($labelTexts | Where-Object { $rule.Regex.IsMatch($_) -or $rule.Labels -contains $_ }).Count -gt 0

    if ($rule.Category) {
      if ($inTitle) { $null = ($rule.Fallback ? $titleFallbacks : $titleCategories).Add($rule.Category) }
      if ($inLabels) { $null = ($rule.Fallback ? $labelFallbacks : $labelCategories).Add($rule.Category) }
      if ($inTitle -or $inLabels) { $tags.Add($rule.Id) }
    } elseif ($inTitle -or $inLabels -or $rule.Regex.IsMatch($bodyText)) {
      $tags.Add($rule.Id)
    }
  }

  $category = $null
  foreach ($set in $titleCategories, $titleFallbacks, $labelCategories, $labelFallbacks) {
    $category = $order | Where-Object { $set.Contains($_) } | Select-Object -First 1
    if ($category) { break }
  }
  [pscustomobject]@{ Category = $category; Tags = @($tags) }
}

function Get-WkEventId {
  # The first 12 hex digits of SHA-1 over "normalized title|start date|venueKey".
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory, Position = 0)][string]$Title,
    [Parameter(Mandatory, Position = 1)][string]$Start,
    [Parameter(Mandatory, Position = 2)][string]$VenueKey
  )

  $seed = ('{0}|{1}|{2}' -f (Get-NormalizedTitle $Title), $Start.Substring(0, [Math]::Min(10, $Start.Length)), $VenueKey).ToLowerInvariant()
  $hash = [Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($seed))
  [Convert]::ToHexString($hash).Substring(0, 12).ToLowerInvariant()
}

function Resolve-WkVenueAlias {
  # Returns the canonical venue for a key in data/schema/venue-aliases.json, or $null.
  param([string]$VenueKey)

  $aliases = Get-WkCityCached 'venueAliases' {
    (Get-Content -LiteralPath (Get-WkCityPath 'data' 'schema' 'venue-aliases.json') -Raw | ConvertFrom-Json -AsHashtable).aliases
  }
  $aliases[$VenueKey]
}

function Get-WkEventSize {
  <#
  .SYNOPSIS
    Guesses an event's crowd size: S, M, L, or XL. See data/schema/sizes.json.
  .DESCRIPTION
    The first rule that applies wins:
    1. A small-format tag, because a workshop stays small even at a big venue.
    2. The venue's usual crowd.
    3. The largest size among the event's tags.
    4. The category's usual size.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$VenueKey,

    [Parameter(Mandatory)]
    [string]$Category,

    [AllowEmptyCollection()]
    [string[]]$Tags = @()
  )

  $rules = Get-WkCityCached 'sizeRules' {
    Get-Content -LiteralPath (Get-WkCityPath 'data' 'schema' 'sizes.json') -Raw | ConvertFrom-Json -AsHashtable
  }

  if (@($Tags | Where-Object { $_ -in $rules.smallTags }).Count -gt 0) { return 'S' }
  if ($rules.venues.ContainsKey($VenueKey)) { return $rules.venues[$VenueKey] }

  $tagSizes = @($Tags | Where-Object { $rules.tags.ContainsKey($_) } | ForEach-Object { $rules.tags[$_] })
  foreach ($size in 'XL', 'L', 'M', 'S') {
    if ($size -in $tagSizes) { return $size }
  }
  $rules.categories[$Category]
}

function Test-WkEvent {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [object]$Event
  )

  begin {
    $schema = Get-WkSchemaText event
  }
  process {
    $Event | ConvertTo-Json -Depth 6 | Test-Json -Schema $schema -ErrorAction SilentlyContinue
  }
}

function ConvertTo-WkTitleCase {
  <#
  .SYNOPSIS
    Changes an all-caps or all-lowercase title of two or more words to title case ("OLD BOISE
    MODEL RAILROAD" or "idaho art gallery" to "Old Boise Model Railroad", "Idaho Art Gallery").
    Acronyms stay capitalized; see data/schema/title-case.json. A title with both cases, or of one
    word (often a band's own styling), is left alone. Used for venues too.
  .DESCRIPTION
    All-lowercase text is read as if it were all caps, except that keepUpper is not applied: in
    lowercase, "us", "id", and "steam" are ordinary words. Words with no vowels (dj, bbq) still
    become capitals, and forms still apply (st to St).
  #>
  param([string]$Title)

  if (-not $Title) { return $Title }
  $fromLower = $Title -cnotmatch '\p{Lu}'
  if (-not $fromLower -and $Title -cmatch '\p{Ll}') { return $Title }
  # Simple case mapping keeps the length, so positions in the uppercased text match the original.
  $original = $Title
  if ($fromLower) { $Title = $Title.ToUpperInvariant() }
  $words = [regex]::Matches($Title, "\p{Lu}+(?:['$([char]0x2019)]\p{Lu}+)*")
  if ($words.Count -lt 2) { return $original }

  $rules = Get-WkCityCached 'titleCase' {
    $table = Get-WkVocabulary title-case
    @{
      KeepUpper  = [Collections.Generic.HashSet[string]]::new([string[]]$table.keepUpper)
      Forms      = $table.forms
      SmallWords = [Collections.Generic.HashSet[string]]::new([string[]]$table.smallWords)
    }
  }

  $out = [Text.StringBuilder]::new()
  $last = 0
  foreach ($word in $words) {
    $between = $Title.Substring($last, $word.Index - $last)
    $null = $out.Append($between)
    $text = $word.Value
    # First word, or the first after a colon, dash, or opening bracket, is capitalized.
    $starts = $last -eq 0 -or $between -match '[:(\[]\s*$|\s[-|]\s*$'
    $lower = $text.ToLowerInvariant()
    $cased = if ($rules.Forms.ContainsKey($text)) {
      $rules.Forms[$text]
    } elseif ((-not $fromLower -and $rules.KeepUpper.Contains($text)) -or $text -notmatch '[AEIOUY]' -or $text -match '^(?:II|III|IV|VI|VII|VIII|IX|XI|XII)$') {
      $text
    } elseif (-not $starts -and $rules.SmallWords.Contains($lower)) {
      $lower
    } else {
      [string]$text[0] + $lower.Substring(1)
    }
    $null = $out.Append($cased)
    $last = $word.Index + $word.Length
  }
  $null = $out.Append($Title.Substring($last))
  $out.ToString()
}

function ConvertTo-WkCoordinate {
  # A latitude or longitude from a feed, often written as text. $null when blank, not a number,
  # or 0 (feeds use 0 for "not set").
  [CmdletBinding()]
  param([Parameter(Position = 0)][AllowNull()][object]$Value)

  $number = 0.0
  if ($null -eq $Value -or -not [double]::TryParse("$Value", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
  if ($number -eq 0) { return $null }
  $number
}

function ConvertTo-WkAddressLine {
  <#
  .SYNOPSIS
    A venue address as one line, "street, town, ST ZIP", from the parts a feed gives. $null
    without a street, since a town alone says no more than the event's city. A state written
    out as the city's state name becomes its code.
  #>
  [CmdletBinding()]
  param([string]$Street, [string]$Town, [string]$State, [string]$Zip)

  $Street = ($Street -replace '\s+', ' ').Trim()
  if (-not $Street) { return $null }
  $stateInfo = (Get-WkCity).state
  $State = "$State".Trim()
  if ($State -eq $stateInfo.name) { $State = $stateInfo.code }
  $tail = (@($State, "$Zip".Trim()) | Where-Object { $_ }) -join ' '
  (@($Street, "$Town".Trim(), $tail) | Where-Object { $_ }) -join ', '
}

function Test-WkNearCity {
  <#
  .SYNOPSIS
    True when a point is within 150 miles of the city's coordinates (city.json), the box that
    source coordinates, venue lookups, and the map's visitor position must fall in.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][double]$Latitude,
    [Parameter(Mandatory)][double]$Longitude
  )

  $center = (Get-WkCity).coordinates
  $rad = [Math]::PI / 180
  $dLat = ($Latitude - $center.lat) * $rad
  $dLon = ($Longitude - $center.lon) * $rad
  $a = [Math]::Pow([Math]::Sin($dLat / 2), 2) +
    [Math]::Cos($center.lat * $rad) * [Math]::Cos($Latitude * $rad) * [Math]::Pow([Math]::Sin($dLon / 2), 2)
  $miles = 2 * 3958.8 * [Math]::Asin([Math]::Min([double]1, [Math]::Sqrt($a)))
  $miles -le 150
}

function New-WkEvent {
  <#
  .SYNOPSIS
    Builds a validated event object and computes its id.
  .PARAMETER Start
    ISO 8601 with offset from ConvertTo-LocalTime, or YYYY-MM-DD with -AllDay.
  .PARAMETER Category
    The event's category. With -InferCategory, this is the fallback.
  .PARAMETER InferCategory
    Use the category its tags point to, for sources that mix many kinds of event.
  .PARAMETER Labels
    The publisher's own categories or genres. See Get-WkClassification.
  .PARAMETER Sources
    Objects with name, url, and fetchedAt.
  .PARAMETER PriceMin
    The cheapest adult ticket from the source's own price data, in dollars (docs/cost-tiers.md).
    Without it, a free-admission tag means 0, and otherwise the description's price text is read.
    costTier is derived from it with Get-CostTier; the price itself is never stored.
  .PARAMETER Latitude
    The venue's coordinates as the source reports them, with -Longitude. Kept as location.lat and
    location.lon only when both are given and the point is near the city (Test-WkNearCity).
    Refine moves them to data/venue-locations.json; data/events.json never has them.
  .PARAMETER Address
    The venue's address as one line, "street, town, ST ZIP". Kept as location.address.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Start,
    [string]$End,
    [switch]$AllDay,
    [Parameter(Mandatory)][string]$Venue,
    [string]$VenueKey,
    [string]$City = 'Other',
    [Parameter(Mandatory)][string]$Category,
    [switch]$InferCategory,
    [string[]]$Labels = @(),
    [Parameter(Mandatory)][string]$Url,
    [string]$Description,
    [object[]]$Sources = @(),
    [AllowNull()][Nullable[decimal]]$PriceMin,
    [AllowNull()][Nullable[double]]$Latitude,
    [AllowNull()][Nullable[double]]$Longitude,
    [string]$Address
  )

  $cleanTitle = ConvertTo-WkTitleCase (($Title -replace '\s+', ' ').Trim())
  # A venue in all caps or all lowercase ("idaho art gallery") gets the same title case.
  $Venue = ConvertTo-WkTitleCase $Venue.Trim()
  $givenVenue = $Venue
  $key = if ($VenueKey) { $VenueKey } else { Get-VenueKey $Venue }
  $alias = Resolve-WkVenueAlias $key
  if ($alias) {
    $key = $alias.key
    $Venue = $alias.name
  }

  # The venue is shown beside the title, so a title ending in it ("Music & Movement | Garden City
  # Public Library", "Karaoke Friday @ Helina Marie's") drops it. Only after "|", "@", or a spaced
  # dash: "Winter Skate at The Village" reads as a title and stays.
  $separator = "\s*[|@]\s*|\s+(?:-|$([char]0x2013)|$([char]0x2014))\s+"
  foreach ($name in @($givenVenue, $Venue) | Where-Object { $_ } | Select-Object -Unique) {
    $match = [regex]::Match($cleanTitle, "^(?<rest>.+?)(?:$separator)$([regex]::Escape($name.Trim()))\s*[!.]?$", 'IgnoreCase')
    if ($match.Success -and $match.Groups['rest'].Value.Trim().Length -ge 3) {
      $cleanTitle = $match.Groups['rest'].Value.Trim()
      break
    }
  }
  $event = [ordered]@{
    id    = Get-WkEventId $cleanTitle $Start $key
    title = $cleanTitle
    start = $Start
  }
  if ($End) { $event.end = $End }
  $event.allDay = [bool]$AllDay
  $event.venue = $Venue
  $event.venueKey = $key
  $event.city = $City

  $classification = Get-WkClassification $cleanTitle $Description -Labels $Labels
  $event.category = if ($InferCategory -and $classification.Category) { $classification.Category } else { $Category }
  $event.tags = $classification.Tags
  $event.size = Get-WkEventSize -VenueKey $key -Category $event.category -Tags $classification.Tags

  # Read before the description loses its dollar amounts below. Only the tier is kept.
  if ($null -eq $PriceMin) {
    $PriceMin = if ('free-admission' -in $classification.Tags) { [decimal]0 } else {
      ConvertFrom-WkPriceText (ConvertTo-PlainText $Description) -Prose
    }
  }
  $tier = Get-CostTier -PriceMin $PriceMin
  if ($tier) { $event.costTier = $tier }

  $event.url = $Url

  # Ticket prices don't belong in stored data, so drop any sentence with a dollar amount.
  $text = (ConvertTo-PlainText $Description) -replace '[^.!?]*\$\d[\d,]*(\.\d+)?[^.!?]*[.!?]?', ''
  $text = ($text -replace '\s+', ' ').Trim()
  if ($text.Length -gt 300) {
    # Don't end on the first half of an emoji or other two-part character: half of one is not valid text.
    $cut = [char]::IsHighSurrogate($text[296]) ? 296 : 297
    $text = $text.Substring(0, $cut).TrimEnd() + '...'
  }
  if ($text) { $event.description = $text }

  $location = [ordered]@{}
  if ($null -ne $Latitude -and $null -ne $Longitude -and (Test-WkNearCity -Latitude $Latitude -Longitude $Longitude)) {
    $location.lat = $Latitude
    $location.lon = $Longitude
  }
  $Address = ($Address -replace '\s+', ' ').Trim()
  if ($Address -and $Address.Length -le 200) { $location.address = $Address }
  if ($location.Count) { $event.location = $location }

  $event.sources = @($Sources | ForEach-Object {
      [pscustomobject][ordered]@{ name = $_.name; url = $_.url; fetchedAt = $_.fetchedAt }
    })

  $result = [pscustomobject]$event
  if (-not (Test-WkEvent $result)) {
    throw "Event does not match the schema: '$cleanTitle' at $Start"
  }
  $result
}
