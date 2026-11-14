#Requires -Version 7.4
<#
.SYNOPSIS
  Reads auctions and estate sales, for the Auctions and Estate Sales category.
.DESCRIPTION
  One request a night per source page (plus robots.txt once per site), checked against robots.txt
  and spaced by its Crawl-delay, at least 1 second apart. No link on a page is followed. Every mode
  applies the same rules (lib/Sales.ps1):

  - In-person only. Anything whose title or text says "online", and anything with no street
    address or place, is dropped (the in-person rule).
  - No real estate: auctions of a house or land are dropped (Downs' Real Estate category,
    Corbett's Real Estate cards, or "real estate" in a title), unless the source sets
    keepRealEstate for live real estate auctions held at the property.
  - Only the cities the site already covers are kept (the city filter).
  - Only the title, the company (as the venue), the city, start and end, and the link to the
    event on the company's site are stored. No address, photos, description, contact details,
    or price.

  How many events each rule dropped is written with Write-Verbose.

  salesMode:
  - ics: an Events Calendar iCal export (Downs Auction). The start time comes from the description
    ("at 2 pm"), since the feed gives dates only. Its real estate auctions are titled by street
    address, and are dropped by the real estate rule unless the source sets keepRealEstate.
  - corbett: the upcoming auctions on corbettauctions.com's home page (an Elementor loop grid
    after id="upcoming"). Only cards marked live onsite whose link stays on the company's site are
    kept; online lots, which link to HiBid or another bidding site, are dropped without following.
  - onthewater: the UPCOMING SALES lines on onthewaterestatesales.com/estatesales ("Ballance Living
    Estate Sale November 21-22 Boise"), dates without a year read as their next occurrence. A sale
    runs from the first day's opening to the last day's close when the page lists hours for those
    days ("Saturday, November 21 | 9:00 AM - 2:00 PM"), and is all-day otherwise. Its link is the
    sales page, which is all the site has.
  - estatesales-net: EstateSales.NET city pages (/ID/<City>), one per entry in the source's pages,
    read with the site's permission. Each page holds its sales in its server-rendered state
    (script#estatesales-net-state, NGRX_STATE.ui.sales.saleRows, keyed by sale id), with each day's
    UTC start and end. A sale runs from its first day's start to its last day's end. Estate sales,
    moving sales, and business closings are kept; other kinds, and sales with an online auction
    link, are not. Its link is the sale's page (/<ST>/<City>/<ZIP>/<id>), which is not fetched.
  - estatesales-org: EstateSales.org city pages (/estate-sales/id/<city>), one per entry in the
    source's pages, read with the site's permission. Each sale is a card (div.card with
    data-auction-id) with its title, type, "City, ID ZIP", and one time: "Sale starts Fri. Nov 20,
    2026 at 9:00 AM MST" for a sale yet to open, read as a timed event at that start, or "Sale ends
    Sun. Nov 15, 2026 at 4:00 PM MST" for one already open, read as an all-day event on its last
    day. The hours of each day are only on the sale page, which is not fetched. Only in-person
    types are kept: the pages also list online auctions from other states.
  A sale near several cities is on each of their pages, so the page modes read each sale id once.
  Their titles lose Markdown emphasis ("**MOVING SALE**") and any part with a price ("Everything $1
  Each!"), since no prices are stored.
.PARAMETER Source
  One entry from sources.json.
.PARAMETER FetchedAt
  UTC timestamp recorded on each event.
.PARAMETER Response
  The feed or page to parse instead of fetching. Used by tests.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][pscustomobject]$Source,
  [Parameter(Mandatory)][string]$FetchedAt,
  [string[]]$Response
)

. "$PSScriptRoot/../lib/Schema.ps1"
. "$PSScriptRoot/../lib/Http.ps1"
. "$PSScriptRoot/../lib/Scrape.ps1"
. "$PSScriptRoot/../lib/Ics.ps1"
. "$PSScriptRoot/../lib/Sales.ps1"

$today = [datetime]::ParseExact((ConvertTo-LocalTime $FetchedAt).Substring(0, 10), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$months = 'Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?'
$clock = '\d{1,2}(?::\d{2})?\s*[AaPp]\.?\s*[Mm]\b\.?'
$dropped = @{ 'in-person' = 0; 'real-estate' = 0; city = 0 }
$kept = 0

function Get-SalesText {
  # The source's page, after checking robots.txt and waiting out its Crawl-delay.
  if ($Response) { return $Response[0] }


  $uri = [uri]$Source.url
  $robots = try { Invoke-WkRequest "$($uri.GetLeftPart('Authority'))/robots.txt" -Raw } catch {
    # No robots.txt means no restrictions. Any other failure means we can't tell, so stop.
    if ("$_" -match 'HTTP 404') { '' } else { throw }
  }
  if (-not (Test-WkRobotsAllowed $robots $uri.PathAndQuery)) { throw "$($Source.name): robots.txt disallows $($uri.PathAndQuery)" }
  $delay = [Math]::Max(1, [int](Get-WkRobotsGroup $robots).Delay)
  if ($delay -gt 60) { throw "$($Source.name): robots.txt asks for $delay seconds between requests" }
  Start-Sleep -Seconds $delay
  Invoke-WkRequest $uri.AbsoluteUri -Raw
}

function Get-SalesPages {
  # The source's listing pages (pages, each resolved against url), for the page modes. robots.txt
  # is read once per site; each page is checked against it and waits out its Crawl-delay (at least
  # 1 second). A page that fails is a warning; the source fails only when every page does.
  if ($Response) { return @($Response) }
  $pages = @($Source.pages | Where-Object { $_ })
  if (-not $pages) { throw "$($Source.name): no pages to read" }

  $robotsBySite = @{}
  $texts = [Collections.Generic.List[string]]::new()
  $failures = 0
  foreach ($page in $pages) {
    try {
      $uri = [uri]::new([uri]$Source.url, $page)
      $site = $uri.GetLeftPart('Authority')
      if (-not $robotsBySite.ContainsKey($site)) {
        $robotsBySite[$site] = try { Invoke-WkRequest "$site/robots.txt" -Raw } catch {
          # No robots.txt means no restrictions. Any other failure means we can't tell, so stop.
          if ("$_" -match 'HTTP 404') { '' } else { throw }
        }
      }
      $robots = $robotsBySite[$site]
      if (-not (Test-WkRobotsAllowed $robots $uri.PathAndQuery)) { throw "robots.txt disallows $($uri.PathAndQuery)" }
      $delay = [Math]::Max(1, [int](Get-WkRobotsGroup $robots).Delay)
      if ($delay -gt 60) { throw "robots.txt asks for $delay seconds between requests" }
      Start-Sleep -Seconds $delay
      $texts.Add((Invoke-WkRequest $uri.AbsoluteUri -Raw))
    } catch {
      $failures++
      Write-Warning "$($Source.name): skipping page $($page): $_"
    }
  }
  if ($texts.Count -eq 0) { throw "$($Source.name): all $failures pages failed" }
  , $texts.ToArray()
}

function ConvertTo-SaleTitle {
  # A listing's title without Markdown emphasis ("**MOVING SALE**") or a part with a price
  # ("Moving Sale - Everything $1 Each!" to "Moving Sale"), since no prices are stored.
  param([AllowEmptyString()][string]$Title)

  $title = ((ConvertTo-PlainText $Title) -replace '\*\*|__|(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w)', '' -replace '\s+', ' ').Trim()
  if ($title -match '\$\s?\d') {
    $dash = "\s+[-$([char]0x2013)$([char]0x2014)]\s+|\s*[|:]\s*"
    $parts = @($title -split $dash | Where-Object { $_ -and $_ -notmatch '\$\s?\d' })
    $title = if ($parts) { $parts -join ' - ' } else { ($title -replace '[^.!?]*\$\s?\d[^.!?]*[.!?]?', '').Trim() }
  }
  $title
}

function Add-Sale {
  # Applies the in-person rule, the real estate rule, and the city filter, then emits the event or
  # counts the drop.
  param([string]$Title, [string]$Text, [string]$Town, [hashtable]$Event, [switch]$RealEstate)

  $city = if ($Town) { Resolve-WkCity $Town }
  $verdict = Get-WkSaleVerdict -Title $Title -Text $Text -HasPlace ([bool]$Town) -City $city -RealEstate ([bool]$RealEstate -and -not $Source.keepRealEstate)
  if ($verdict -ne 'keep') {
    $script:dropped[$verdict]++
    $why = switch ($verdict) { 'city' { "the city filter ($Town)" } 'real-estate' { 'the real estate rule' } default { 'the in-person rule' } }
    Write-Verbose "$($Source.name): '$Title' dropped by $why"
    return
  }
  try {
    New-WkSaleEvent -Source $Source -FetchedAt $FetchedAt -City $city @Event
    $script:kept++
  } catch {
    Write-Warning "$($Source.name): skipping '$Title': $_"
  }
}

function Read-IcsSales {
  param([string]$Text)

  if ($Text -notmatch 'BEGIN:VCALENDAR') { throw "$($Source.name): response is not an iCalendar feed" }
  foreach ($item in (ConvertFrom-Ics $Text)) {
    if ($item.Status -eq 'CANCELLED') { continue }
    $title = ConvertTo-PlainText $item.Summary
    $lines = @($item.Description -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $locationLine = ($lines | Where-Object { $_ -match '^LOCATION:\s*(.+)$' } | Select-Object -First 1) -replace '^LOCATION:\s*', ''
    $town = Find-WkSaleTown (@($item.Location, $locationLine, $title, $lines[0]) -join "`n")

    $event = @{ Url = if ($item.Url) { $item.Url } else { $Source.url } }
    $at = [regex]::Match($item.Description, "(?i)\bat\s+(?<t>$clock)")
    $start = if ($item.AllDay -and $at.Success) { ConvertTo-WkSaleTime $item.Start $at.Groups['t'].Value }
    if ($start) {
      $event.Start = $start
    } else {
      $event.Start = $item.Start
      if ($item.End) { $event.End = $item.End }
      $event.AllDay = [bool]$item.AllDay
    }

    # A title that is a street address is a real estate listing, which the real estate rule drops.
    $event.Title = $title
    Add-Sale -Title $title -Text "$($item.Description)`n$($item.Categories)" -Town $town -Event $event `
      -RealEstate:($item.Categories -match '(?i)\breal estate\b' -or $title -match '^\d+\s+\S')
  }
}

function Read-CorbettSales {
  param([string]$Text)

  $at = $Text.IndexOf('id="upcoming"')
  if ($at -lt 0) { throw "$($Source.name): no upcoming auctions section (id=""upcoming"") on the page" }
  $siteHost = ([uri]$Source.url).Host -replace '^www\.', ''

  foreach ($card in ($Text.Substring($at) -split '<div role="listitem"' | Select-Object -Skip 1)) {
    $href = [regex]::Match($card, 'href="([^"]+)"').Groups[1].Value
    $parts = @([regex]::Matches($card, '(?s)<(?<tag>span|h3|p|div)\b[^>]*class="elementor-heading-title[^"]*"[^>]*>(?<body>.*?)</\k<tag>>') | ForEach-Object {
        [pscustomobject]@{ Tag = $_.Groups['tag'].Value; Text = ConvertTo-PlainText $_.Groups['body'].Value }
      })
    $texts = @($parts.Text)
    $monthAt = [Array]::FindIndex([string[]]$texts, [Predicate[string]] { param($t) $t -match "^(?:$months)\.?$" })
    if ($monthAt -lt 0 -or $monthAt + 1 -ge $texts.Count -or $texts[$monthAt + 1] -notmatch '^\d{1,2}$') { continue }

    # The title is the card's h3. After it come the description lines, and last the place
    # ("Nampa, ID", or "Address to be posted" before the address is public).
    $titleAt = [Array]::FindIndex([object[]]$parts, [Predicate[object]] { param($p) $p.Tag -eq 'h3' })
    if ($titleAt -lt 0 -or $titleAt + 1 -ge $parts.Count) { continue }
    $title = $parts[$titleAt].Text
    $after = @($texts | Select-Object -Skip ($titleAt + 1))
    $place = $after[-1]
    $details = @($after | Select-Object -SkipLast 1)
    $town = Find-WkSaleTown $place

    $linkHost = if ($href -match '^https?://([^/:?#]+)') { $Matches[1].ToLowerInvariant() -replace '^www\.', '' }
    $onsite = $texts -match '(?i)^(live\s+)?on-?site$'
    if (-not $onsite -or $linkHost -ne $siteHost) {
      # Online bidding, or a lot on HiBid or another bidding site: never followed.
      $script:dropped['in-person']++
      Write-Verbose "$($Source.name): '$title' dropped by the in-person rule (not live onsite)"
      continue
    }

    $date = Get-WkNextDate -Month $texts[$monthAt] -Day ([int]$texts[$monthAt + 1]) -Today $today
    $time = $texts | Where-Object { $_ -match "^\w+day,\s*(?<t>$clock)$" } | Select-Object -First 1
    $start = if ($time) { ConvertTo-WkSaleTime $date ($time -replace '^\w+day,\s*', '') }
    $event = @{ Title = $title; Url = $href; Start = $start ?? $date; AllDay = -not $start }
    # The card's type label ("Estate", "Real Estate") comes before the title.
    $realEstate = @($texts | Select-Object -First $titleAt) -contains 'Real Estate' -or $card -match 'auction_type-real-estate'
    Add-Sale -Title $title -Text ($details -join "`n") -Town $town -Event $event -RealEstate:$realEstate
  }
}

function Read-OnTheWaterSales {
  param([string]$Text)

  $blocks = @(($Text -split '(?i)</p>|<br\s*/?>|</h\d>|</li>') | ForEach-Object { ConvertTo-PlainText $_ } | Where-Object { $_ })
  $heading = [Array]::FindIndex([string[]]$blocks, [Predicate[string]] { param($b) $b -match '^(?i)upcoming sales$' })
  if ($heading -lt 0) { throw "$($Source.name): no UPCOMING SALES heading on the page" }

  # Opening and closing times by date, from lines such as "Saturday, November 21 | 9:00 AM - 2:00 PM".
  $hours = @{}
  # A hyphen, an en dash (0x2013), an em dash (0x2014), or "to".
  $dash = "(?:-|$([char]0x2013)|$([char]0x2014)|to)"
  foreach ($match in [regex]::Matches(($blocks -join "`n"), "(?i)\b(?:mon|tues|wednes|thurs|fri|satur|sun)day,?\s+(?<m>$months)\.?\s+(?<d>\d{1,2})(?:st|nd|rd|th)?\s*[|:,]?\s*(?<open>$clock)\s*$dash\s*(?<close>$clock)")) {
    $day = Get-WkNextDate -Month $match.Groups['m'].Value -Day ([int]$match.Groups['d'].Value) -Today $today
    $hours[$day] = @{ Open = $match.Groups['open'].Value; Close = $match.Groups['close'].Value }
  }

  $salePattern = "^(?<title>.+?)\s+(?<m1>$months)\.?\s+(?<d1>\d{1,2})(?:st|nd|rd|th)?(?:\s*(?:$dash|&|and)\s*(?:(?<m2>$months)\.?\s+)?(?<d2>\d{1,2})(?:st|nd|rd|th)?)?,?\s+(?:in\s+)?(?<place>[A-Z][A-Za-z .']*?)\s*$"
  foreach ($line in ($blocks | Select-Object -Skip ($heading + 1))) {
    $sale = [regex]::Match($line, $salePattern)
    if (-not $sale.Success) { break }

    $first = Get-WkNextDate -Month $sale.Groups['m1'].Value -Day ([int]$sale.Groups['d1'].Value) -Today $today
    $last = $first
    if ($sale.Groups['d2'].Success) {
      $month2 = if ($sale.Groups['m2'].Success) { $sale.Groups['m2'].Value } else { $sale.Groups['m1'].Value }
      $last = Get-WkNextDate -Month $month2 -Day ([int]$sale.Groups['d2'].Value) -Today $today
      if ($last -lt $first) { $last = ([datetime]$last).AddYears(1).ToString('yyyy-MM-dd') }
    }

    $title = $sale.Groups['title'].Value.Trim()
    $event = @{ Title = $title; Url = $Source.url }
    if ($hours[$first]) {
      $event.Start = ConvertTo-WkSaleTime $first $hours[$first].Open
      $closing = $hours[$last] ?? ($last -eq $first ? $hours[$first] : $null)
      if ($closing) { $event.End = ConvertTo-WkSaleTime $last $closing.Close }
    } else {
      $event.Start = $first
      $event.AllDay = $true
      if ($last -ne $first) { $event.End = $last }
    }
    Add-Sale -Title $title -Text $line -Town $sale.Groups['place'].Value.Trim() -Event $event
  }
}

function Read-EstateSalesNetSales {
  param([string[]]$Pages)

  $kinds = @('EstateSales', 'MovingSales', 'BusinessClosings')
  $state = (Get-WkCity).state.code
  $site = ([uri]$Source.url).GetLeftPart('Authority')
  $seen = [Collections.Generic.HashSet[string]]::new()
  foreach ($html in $Pages) {
    $match = [regex]::Match($html, '(?s)<script id="estatesales-net-state"[^>]*>(?<json>.*?)</script>')
    if (-not $match.Success) {
      Write-Warning "$($Source.name): a page has no estatesales-net-state data, so it lists no sales"
      continue
    }
    # The page's transfer state escapes these characters as &q; and the like; &a; (&) goes last.
    $json = $match.Groups['json'].Value -replace '&q;', '"' -replace '&s;', "'" -replace '&l;', '<' -replace '&g;', '>' -replace '&a;', '&'
    $rows = (ConvertFrom-Json $json -AsHashtable -Depth 100).NGRX_STATE.ui.sales.saleRows
    if (-not $rows) { continue }

    foreach ($row in $rows.Values) {
      if (-not $seen.Add("$($row.id)")) { continue }
      $title = ConvertTo-SaleTitle "$($row.name)"
      if ("$($row.typeName)" -notin $kinds) {
        $script:dropped['in-person']++
        Write-Verbose "$($Source.name): '$title' dropped by the in-person rule (a $($row.typeName) listing)"
        continue
      }
      if ("$($row.stateCode)" -ne $state) {
        $script:dropped.city++
        Write-Verbose "$($Source.name): '$title' dropped by the city filter ($($row.cityName), $($row.stateCode))"
        continue
      }
      $days = @($row.dates | Where-Object { $_.utcStartDate._value } | Sort-Object { [DateTimeOffset]"$($_.utcStartDate._value)" })
      if (-not $title -or -not $days) {
        Write-Warning "$($Source.name): skipping sale $($row.id), which has no title or no dates"
        continue
      }
      $start = ConvertTo-LocalTime $days[0].utcStartDate._value
      $end = if ($days[-1].utcEndDate._value) { ConvertTo-LocalTime $days[-1].utcEndDate._value }
      $url = '{0}/{1}/{2}/{3}/{4}' -f $site, $row.stateCode, ("$($row.cityName)".Trim() -replace '\s+', '-'), $row.postalCodeNumber, $row.id
      $event = @{ Title = $title; Start = $start; Url = $url }
      if ($end -and [DateTimeOffset]$end -gt [DateTimeOffset]$start) { $event.End = $end }
      # A listing that links an online auction is bidding, not a sale to go to.
      $text = if ($row.auctionUrl) { 'online auction' } else { '' }
      Add-Sale -Title $title -Text $text -Town "$($row.cityName)" -Event $event
    }
  }
}

function Read-EstateSalesOrgSales {
  param([string[]]$Pages)

  $site = ([uri]$Source.url).GetLeftPart('Authority')
  $seen = [Collections.Generic.HashSet[string]]::new()
  foreach ($html in $Pages) {
    foreach ($card in ([regex]::Split($html, 'data-auction-id="') | Select-Object -Skip 1)) {
      $id = ($card -split '"', 2)[0]
      if (-not $seen.Add($id)) { continue }

      $titleMatch = [regex]::Match($card, '(?s)class="card__title[^"]*"[^>]*>(?<body>.*?)</h3>')
      $title = ConvertTo-SaleTitle $titleMatch.Groups['body'].Value
      $href = [regex]::Match($titleMatch.Groups['body'].Value, 'href="(?<h>[^"]+)"').Groups['h'].Value
      $type = ConvertTo-PlainText ([regex]::Match($card, '(?s)class="card__type[^"]*"[^>]*>(?<body>.*?)</div>').Groups['body'].Value)
      $location = ConvertTo-PlainText ([regex]::Match($card, '(?s)class="card__location[^"]*"[^>]*>(?<body>.*?)</div>').Groups['body'].Value)
      $at = $card.IndexOf('class="card__dates"')
      $dateText = if ($at -ge 0) { ConvertTo-PlainText ($card.Substring($at) -replace '(?s)<svg\b.*?</svg>', ' ' -replace '(?s)<!--.*?-->', ' ') } else { '' }

      if (-not $title) { continue }
      if ($type -notmatch '(?i)\bin-person\b') {
        $script:dropped['in-person']++
        Write-Verbose "$($Source.name): '$title' dropped by the in-person rule ($type)"
        continue
      }
      $when = [regex]::Match($dateText, "(?i)\bsale\s+(?<kind>starts|ends)\s+\w+\.?\s+(?<m>$months)\.?\s+(?<d>\d{1,2}),?\s+(?:(?<y>\d{4})\s+)?at\s+(?<t>$clock)")
      if (-not $when.Success) {
        Write-Warning "$($Source.name): skipping '$title', whose card gives no sale time"
        continue
      }
      $date = Get-WkNextDate -Month $when.Groups['m'].Value -Day ([int]$when.Groups['d'].Value) -Today $today
      if ($when.Groups['y'].Success) { $date = $when.Groups['y'].Value + $date.Substring(4) }
      $url = if ($href) { [uri]::new([uri]$site, [Net.WebUtility]::HtmlDecode($href)).AbsoluteUri } else { $Source.url }
      $event = @{ Title = $title; Url = $url }
      if ($when.Groups['kind'].Value -ieq 'starts') {
        $event.Start = ConvertTo-WkSaleTime $date $when.Groups['t'].Value
      } else {
        # Already open: only its closing time is on the card, so it lists as all-day on its last day.
        $event.Start = $date
        $event.AllDay = $true
      }
      if (-not $event.Start) {
        Write-Warning "$($Source.name): skipping '$title', whose sale time '$($when.Groups['t'].Value)' can't be read"
        continue
      }
      Add-Sale -Title $title -Text $type -Town (Find-WkSaleTown $location) -Event $event
    }
  }
}

switch ($Source.salesMode) {
  'ics' { Read-IcsSales (Get-SalesText) }
  'corbett' { Read-CorbettSales (Get-SalesText) }
  'onthewater' { Read-OnTheWaterSales (Get-SalesText) }
  'estatesales-net' { Read-EstateSalesNetSales (Get-SalesPages) }
  'estatesales-org' { Read-EstateSalesOrgSales (Get-SalesPages) }
  default { throw "$($Source.name): unknown salesMode '$($Source.salesMode)'" }
}
Write-Verbose "$($Source.name): kept $kept, $($dropped['in-person']) dropped by the in-person rule, $($dropped['real-estate']) dropped as real estate, $($dropped.city) dropped by the city filter"
