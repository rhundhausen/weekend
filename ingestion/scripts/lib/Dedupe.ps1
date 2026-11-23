# Cross-source deduplication.

. "$PSScriptRoot/Schema.ps1"

function Get-JaroWinkler {
  [CmdletBinding()]
  [OutputType([double])]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$First,
    [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Second
  )

  if ($First -ceq $Second) { return [double]1 }
  if (-not $First -or -not $Second) { return [double]0 }

  $window = [Math]::Max([Math]::Max($First.Length, $Second.Length) / 2 - 1, 0)
  $window = [Math]::Floor($window)
  $firstMatched = [bool[]]::new($First.Length)
  $secondMatched = [bool[]]::new($Second.Length)

  $matchCount = 0
  for ($i = 0; $i -lt $First.Length; $i++) {
    $from = [Math]::Max($i - $window, 0)
    $to = [Math]::Min($i + $window, $Second.Length - 1)
    for ($j = $from; $j -le $to; $j++) {
      if (-not $secondMatched[$j] -and $First[$i] -ceq $Second[$j]) {
        $firstMatched[$i] = $true
        $secondMatched[$j] = $true
        $matchCount++
        break
      }
    }
  }
  if ($matchCount -eq 0) { return [double]0 }

  $transpositions = 0
  $k = 0
  for ($i = 0; $i -lt $First.Length; $i++) {
    if (-not $firstMatched[$i]) { continue }
    while (-not $secondMatched[$k]) { $k++ }
    if ($First[$i] -cne $Second[$k]) { $transpositions++ }
    $k++
  }

  $m = [double]$matchCount
  $jaro = ($m / $First.Length + $m / $Second.Length + ($m - [Math]::Floor($transpositions / 2)) / $m) / 3

  $prefix = 0
  $limit = [Math]::Min(4, [Math]::Min($First.Length, $Second.Length))
  while ($prefix -lt $limit -and $First[$prefix] -ceq $Second[$prefix]) { $prefix++ }

  [double]($jaro + $prefix * 0.1 * (1 - $jaro))
}

$script:CanceledPattern = '(?i)\b(cancell?ed)\b'

# Words that say nothing about which event it is, and short forms that sources spell both ways.
$script:TitleStopWords = [Collections.Generic.HashSet[string]]::new([string[]]@(
    'a', 'an', 'and', 'at', 'by', 'event', 'feat', 'featuring', 'for', 'ft', 'game', 'in', 'live', 'night', 'of',
    'on', 'presents', 'show', 'the', 'to', 'tour', 'v', 'vs', 'w', 'with'
  ))
# Short forms are the city's titleAbbreviations in city.json, such as bsu for boise state university.

function Test-WkCanceledTitle {
  # True for titles like "CANCELED - Play and Learn" or "CANCELLED Ping-Pong Club".
  [CmdletBinding()]
  [OutputType([bool])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Title)

  $Title -match $script:CanceledPattern
}

function Get-WkMatchTitle {
  # The normalized title with any "canceled" marker removed, so a cancellation still matches its listing.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Title)

  ((Get-NormalizedTitle $Title) -replace '\bcancell?ed\b', ' ' -replace '\s+', ' ').Trim()
}

function Get-WkTitleWords {
  # The distinct words that identify an event, from a title already passed through Get-WkMatchTitle.
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$MatchTitle)

  $words = [Collections.Generic.HashSet[string]]::new()
  $expansions = (Get-WkCity).titleAbbreviations
  foreach ($word in ($MatchTitle -split ' ')) {
    if (-not $word) { continue }
    $parts = if ($expansions.ContainsKey($word)) { $expansions[$word] -split ' ' } else { @($word) }
    foreach ($part in $parts) {
      if (-not $script:TitleStopWords.Contains($part)) { $null = $words.Add($part) }
    }
  }
  , $words
}

function Get-WkTitleCore {
  <#
  .SYNOPSIS
    The part of a title that names the work: without a presenter ("Ballet Idaho presents The
    Nutcracker" to "The Nutcracker") or a subtitle after a colon or spaced dash ("The Nutcracker:
    With Live Music by the Boise Phil" to "The Nutcracker"). The whole title if nothing is left.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Title)

  $core = $Title -replace '(?i)^.*?\bpresents\b[:\s]*', ''
  $core = ($core -split "\s*:\s+|\s+[-$([char]0x2013)$([char]0x2014)|]\s+", 2)[0].Trim()
  if ($core) { $core } else { $Title }
}

function Test-WkSameTitleWords {
  <#
  .SYNOPSIS
    True when two titles name the same event in different words.
  .DESCRIPTION
    Either the shorter title's words all appear in the longer one, or they share at least two words
    and those cover at least 60% of the shorter title. "Jo Koy" matches "Jo Koy (12 and Over)";
    "Family Storytime" does not match "Toddler Storytime".
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$First,
    [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$Second
  )

  $shorter = [Math]::Min($First.Count, $Second.Count)
  if ($shorter -eq 0) { return $false }
  $shared = 0
  foreach ($word in $First) { if ($Second.Contains($word)) { $shared++ } }
  if ($shared -eq $shorter) { return $true }
  ($shared -ge 2) -and ($shared / $shorter -ge 0.6)
}

function Get-WkEventRank {
  # The best (lowest) priority among the sources that reported the event.
  param(
    [object]$Event,
    [hashtable]$Priorities
  )

  $ranks = @($Event.sources | ForEach-Object {
      if ($Priorities.ContainsKey($_.name)) { $Priorities[$_.name] } else { 50 }
    })
  if ($ranks.Count -eq 0) { return 50 }
  ($ranks | Measure-Object -Minimum).Minimum
}

function Test-WkPlaceholderVenue {
  # True for a venue that names no place: the bare city, a city with state or ZIP ("Boise, ID
  # 83703"), or a stand-in such as "Various Treasure Valley locations", "TBA", or "TBD".
  param([AllowEmptyString()][string]$Venue, [AllowEmptyString()][string]$City)

  $v = "$Venue".Trim()
  if (-not $v) { return $true }
  if ($City -and $v -eq $City) { return $true }
  $v -match '(?i)^(?:various\b.*|tba|tbd|to be announced|to be determined)$' -or
  $v -match "(?i)^[a-z .']+,\s*(?:$(Get-WkStatePattern))\b[\s\d-]*$"
}

$script:PaidTiers = @('$', '$$', '$$$')

function Get-WkEventDay {
  # The YYYY-MM-DD part of a start or end, in the event's own offset.
  param([AllowEmptyString()][string]$Value)
  if ($Value.Length -ge 10) { $Value.Substring(0, 10) } else { '' }
}

function Set-WkPaidTier {
  # Gives a free or unpriced event the paid tier, as a copy, so the caller's event is untouched.
  param([object]$Event, [string]$Tier)
  $copy = $Event | Select-Object *
  $copy.sources = @($Event.sources)
  $copy | Add-Member -NotePropertyName costTier -NotePropertyValue $Tier -Force
  $copy
}

function Remove-WkCoveredSpans {
  <#
  .SYNOPSIS
    Drops a multi-day listing when single-day listings of the same show cover it.
  .DESCRIPTION
    A multi-day event is dropped when the same known city (not Other) has single-day events with a
    similar title (Jaro-Winkler above 0.9, ignoring a year) at the same venueKey, or with either venue
    a placeholder, on both its first and its last day. A placeholder range with no city yet (Other)
    can be covered by nights in any one known city. Sources list a run both ways ("TRICA's Snow Globe" from
    Dec 4 to Dec 13, and each of its six nights), and the nights are the accurate version: the range
    hides that it skips Monday to Thursday. A range covered only in the middle, such as two special
    nights of a month-long light show, is kept. The dropped range's price tier goes to nights that
    have none, or that say free when the range is paid.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events)

  # Single-day events in known cities by the first four letters of the title, to keep comparisons
  # few. A year in the title is ignored, so "2026 Festival of Trees" covers "Festival of Trees".
  $singles = @{}
  $index = 0
  $infos = foreach ($event in $Events) {
    $title = ((Get-WkMatchTitle $event.title) -replace '\b(?:19|20)\d\d\b', ' ' -replace '\s+', ' ').Trim()
    $startDay = Get-WkEventDay $event.start
    $endDay = Get-WkEventDay $event.end
    $info = [pscustomobject]@{ Index = $index++; Event = $event; Title = $title; StartDay = $startDay; EndDay = $endDay; Multi = ($endDay -and $endDay -gt $startDay) }
    if (-not $info.Multi -and $event.city -and $event.city -ne 'Other' -and $title) {
      $key = $title.Substring(0, [Math]::Min(4, $title.Length))
      if (-not $singles.ContainsKey($key)) { $singles[$key] = [Collections.Generic.List[object]]::new() }
      $singles[$key].Add($info)
    }
    $info
  }

  $dropped = [Collections.Generic.HashSet[int]]::new()
  $tiers = @{}
  foreach ($span in @($infos | Where-Object { $_.Multi -and $_.Event.city -and $_.Title })) {
    $event = $span.Event
    $spanPlaceholder = Test-WkPlaceholderVenue $event.venue $event.city
    # A placeholder listing ("Various Treasure Valley locations") often has no city yet: it can
    # match nights in any one known city. Otherwise the city must be known and the same.
    $anyCity = $event.city -eq 'Other'
    if ($anyCity -and -not $spanPlaceholder) { continue }
    $covered = @($singles[$span.Title.Substring(0, [Math]::Min(4, $span.Title.Length))] | Where-Object {
        $_ -and ($anyCity -or $_.Event.city -eq $event.city) -and
        $_.StartDay -ge $span.StartDay -and $_.StartDay -le $span.EndDay -and
        ($_.Event.venueKey -eq $event.venueKey -or $spanPlaceholder -or (Test-WkPlaceholderVenue $_.Event.venue $_.Event.city)) -and
        (Get-JaroWinkler $span.Title $_.Title) -gt 0.9
      })
    if (@($covered.Event.city | Select-Object -Unique).Count -gt 1) { continue }
    $days = @($covered.StartDay)
    if (-not ($days -contains $span.StartDay -and $days -contains $span.EndDay)) { continue }
    Write-Verbose "Dropped '$($event.title)' $($span.StartDay) to $($span.EndDay) at $($event.venue): its $(@($days | Select-Object -Unique).Count) days are listed one by one"
    $null = $dropped.Add($span.Index)
    if ($event.costTier) {
      foreach ($single in $covered) {
        if (-not $single.Event.costTier -or ($single.Event.costTier -eq 'free' -and $event.costTier -ne 'free')) {
          $tiers[$single.Index] = $event.costTier
        }
      }
    }
  }

  foreach ($info in $infos) {
    if ($dropped.Contains($info.Index)) { continue }
    if ($tiers.ContainsKey($info.Index)) { Set-WkPaidTier $info.Event $tiers[$info.Index] } else { $info.Event }
  }
}

function Sync-WkSeriesTiers {
  <#
  .SYNOPSIS
    Keeps one show from reading free on some dates and paid on others.
  .DESCRIPTION
    Events with the same normalized title, venueKey, and city form a series. When some say free and
    others give a paid tier, the free ones take the lowest paid tier: "Free" usually comes from the
    low end of a range like "Free - $20" that only covers small children. Changes the events in place
    (Merge-WkEvents passes its own copies).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][object[]]$Events)

  foreach ($series in ($Events | Group-Object { "$($_.city)|$($_.venueKey)|$(Get-WkMatchTitle $_.title)" })) {
    $paid = @($series.Group.costTier | Where-Object { $_ -in $script:PaidTiers } | Sort-Object { $script:PaidTiers.IndexOf($_) })
    if (-not $paid -or -not @($series.Group | Where-Object costTier -eq 'free')) { continue }
    Write-Verbose "Priced '$($series.Group[0].title)' at $($series.Group[0].venue) $($paid[0]) on every date, not free on some"
    foreach ($event in @($series.Group | Where-Object costTier -eq 'free')) {
      $event | Add-Member -NotePropertyName costTier -NotePropertyValue $paid[0] -Force
    }
  }
}

function Merge-WkEvents {
  <#
  .SYNOPSIS
    Collapses events that describe the same thing.
  .DESCRIPTION
    Two events at the same venueKey are the same if:
    - their ids match, or
    - their normalized titles have Jaro-Winkler similarity above 0.9 and they start within 30 minutes, or
    - they start at the same minute, no source reported both, and their titles share their
      identifying words (Test-WkSameTitleWords). This catches "Jo Koy" against
      "Jo Koy - Koy Meets World Tour", and "BSU Women's Basketball Game" against
      "Boise State University Women's Basketball vs Portland State". Each title's core (Get-WkTitleCore,
      without a presenter or subtitle) is compared as well.
    Two multi-day events (ending on a later day than they start) are also the same, at any venueKey
    and start time, if they have the same normalized title, the same known city (not Other), the same
    start day, and no source reported both. Sources disagree on a festival's opening time and
    building more than on a show's ("Festival of Trees" at 6:30 AM in the Horse Park and at noon
    in the Arena), and the title, city, and dates are enough to tell multi-day events apart.
    Two events are also the same, at any venueKey, if they have the same normalized title, start at
    the same minute, are in the same known city (not Other), and no source reported both. Sources
    disagree on the building more often than two different events share a title and start minute
    in one city ("Taryn Smith & Christine Turpin" at 6 PM, at the Morrison Center by one source and
    the Special Events Center by two others). One source listing both, such as one library's
    calendar with the same storytime at two branches, keeps them apart.
    The best-priority event's venue is kept, unless it is a placeholder (the bare city, "Boise, ID
    83703", or "Various ..."), when the other event's venue replaces it.
    A "canceled" marker in a title is ignored for matching, so a cancellation finds its listing.
    Before matching, a multi-day listing whose first and last days are also listed one by one is
    dropped (Remove-WkCoveredSpans). After it, one show at one venue never reads free on some dates
    and paid on others (Sync-WkSeriesTiers).

    The event from the best-priority source supplies the url and other fields (between sources
    of equal priority, the one earlier in the input; refine passes them in sources.json order), the longest
    description wins, tags are unioned, and sources are unioned by name. When two reports from one source
    disagree on fetchedAt, the earliest is kept so a re-run doesn't change stored data.
  .PARAMETER Priorities
    Source name to priority. Lower is better, and sources not listed count as 50.
  .PARAMETER DropCanceled
    Leave out every merged event that any source reported as canceled.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)]
    [AllowEmptyCollection()]
    [object[]]$Events,

    [hashtable]$Priorities = @{},

    [switch]$DropCanceled
  )

  $ordered = @(Remove-WkCoveredSpans $Events) |
    Select-Object @{ n = 'Event'; e = { $_ } }, @{ n = 'Rank'; e = { Get-WkEventRank $_ $Priorities } }, @{ n = 'Instant'; e = { Get-WkEventInstant $_.start } } |
    Sort-Object Rank, Instant, @{ e = { $_.Event.id } } -Stable

  $kept = [System.Collections.Generic.List[object]]::new()
  $byId = @{}
  $bySlot = @{}
  $slotTicks = [TimeSpan]::FromMinutes(30).Ticks
  # Multi-day events by "city|start day|title", for the multi-day rule.
  $byDays = @{}
  # Timed events by "city|start minute|title", for the cross-venue rule.
  $byMinute = @{}

  foreach ($entry in $ordered) {
    $event = $entry.Event
    $title = Get-WkMatchTitle $event.title
    $words = Get-WkTitleWords $title
    # The title's core (no presenter or subtitle) is matched too, so "Ballet Idaho presents The
    # Nutcracker" and "The Nutcracker: With Live Music by the Boise Phil" at one minute are one show.
    $core = Get-WkTitleWords (Get-WkMatchTitle (Get-WkTitleCore $event.title))
    $canceled = Test-WkCanceledTitle $event.title
    $sourceNames = @($event.sources | ForEach-Object name)
    $slot = [Math]::Floor($entry.Instant.UtcTicks / $slotTicks)

    $match = $byId[$event.id]
    if (-not $match) {
      # Anything within 30 minutes lands in this slot or a neighbor, so a busy venue stays cheap.
      $sameMinute = $null
      :search foreach ($neighbor in ($slot - 1), $slot, ($slot + 1)) {
        foreach ($candidate in @($bySlot["$($event.venueKey)|$neighbor"])) {
          if (-not $candidate) { continue }
          $gap = [Math]::Abs(($candidate.Instant - $entry.Instant).TotalMinutes)
          if ($gap -le 30 -and (Get-JaroWinkler $title $candidate.Title) -gt 0.9) {
            $match = $candidate
            break search
          }
          # One source listing two things at the same minute means two things, so only cross-source.
          if (-not $sameMinute -and $gap -lt 1 -and
            -not @($candidate.Event.sources | Where-Object { $_.name -in $sourceNames }) -and
            @($candidate.WordSets | Where-Object { (Test-WkSameTitleWords $words $_) -or (Test-WkSameTitleWords $core $_) })) {
            $sameMinute = $candidate
          }
        }
      }
      if (-not $match) { $match = $sameMinute }
    }

    $daysKey = $null
    if ($event.city -and $event.city -ne 'Other' -and $event.end -and
      $event.end.Substring(0, 10) -gt $event.start.Substring(0, 10)) {
      $daysKey = "$($event.city)|$($event.start.Substring(0, 10))|$title"
      if (-not $match) {
        $match = @($byDays[$daysKey]) | Where-Object {
          $_ -and -not @($_.Event.sources | Where-Object { $_.name -in $sourceNames })
        } | Select-Object -First 1
      }
    }

    $minuteKey = $null
    if ($event.city -and $event.city -ne 'Other' -and -not $event.allDay -and $title) {
      $minuteKey = "$($event.city)|$($entry.Instant.UtcTicks)|$title"
      if (-not $match) {
        $match = @($byMinute[$minuteKey]) | Where-Object {
          $_ -and -not @($_.Event.sources | Where-Object { $_.name -in $sourceNames })
        } | Select-Object -First 1
        if ($match -and $match.Event.venueKey -ne $event.venueKey) {
          Write-Verbose "Merged across venues: '$($event.title)' at $($event.start) in $($event.city), $($match.Event.venue) and $($event.venue)"
          if ((Test-WkPlaceholderVenue $match.Event.venue $match.Event.city) -and -not (Test-WkPlaceholderVenue $event.venue $event.city)) {
            $match.Event.venue = $event.venue
            $match.Event.venueKey = $event.venueKey
          }
        }
      }
    }

    if ($match) {
      if ($canceled) { $match.Canceled = $true }
      $match.WordSets.Add($words)
      if (-not $core.SetEquals($words)) { $match.WordSets.Add($core) }
      $target = $match.Event
      if ("$($event.description)".Length -gt "$($target.description)".Length) {
        $target | Add-Member -NotePropertyName description -NotePropertyValue $event.description -Force
      }
      # Real price data from any duplicate beats none. The best source's own tier stays.
      if ($event.costTier -and -not $target.costTier) {
        $target | Add-Member -NotePropertyName costTier -NotePropertyValue $event.costTier -Force
      }
      # A timed end doesn't fit an all-day event, or the other way around.
      if ($event.end -and -not $target.end -and $event.allDay -eq $target.allDay) {
        $target | Add-Member -NotePropertyName end -NotePropertyValue $event.end -Force
      }

      [string[]]$tags = @(@($target.tags) + @($event.tags) | Where-Object { $_ } | Select-Object -Unique)
      [Array]::Sort($tags, [StringComparer]::Ordinal)
      $target.tags = $tags

      $union = @{}
      foreach ($source in (@($target.sources) + @($event.sources))) {
        $seen = $union[$source.name]
        if (-not $seen -or [string]$source.fetchedAt -lt [string]$seen.fetchedAt) {
          $union[$source.name] = $source
        }
      }
      $target.sources = @($union.Keys | Sort-Object | ForEach-Object { $union[$_] })
      $byId[$event.id] = $match
      continue
    }

    $copy = $event | Select-Object *
    $copy.sources = @($event.sources)
    $wordSets = [Collections.Generic.List[object]]::new(@(, $words))
    if (-not $core.SetEquals($words)) { $wordSets.Add($core) }
    $record = [pscustomobject]@{ Event = $copy; Title = $title; WordSets = $wordSets; Instant = $entry.Instant; Canceled = $canceled }
    $kept.Add($record)
    $byId[$event.id] = $record
    $slotKey = "$($event.venueKey)|$slot"
    if (-not $bySlot.ContainsKey($slotKey)) {
      $bySlot[$slotKey] = [System.Collections.Generic.List[object]]::new()
    }
    $bySlot[$slotKey].Add($record)
    if ($minuteKey) {
      if (-not $byMinute.ContainsKey($minuteKey)) {
        $byMinute[$minuteKey] = [System.Collections.Generic.List[object]]::new()
      }
      $byMinute[$minuteKey].Add($record)
    }
    if ($daysKey) {
      if (-not $byDays.ContainsKey($daysKey)) {
        $byDays[$daysKey] = [System.Collections.Generic.List[object]]::new()
      }
      $byDays[$daysKey].Add($record)
    }
  }

  $events = @($kept | Where-Object { -not ($DropCanceled -and $_.Canceled) } | ForEach-Object { $_.Event })
  Sync-WkSeriesTiers $events
  $events
}
