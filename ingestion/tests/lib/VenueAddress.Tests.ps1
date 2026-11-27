BeforeAll {
  . "$PSScriptRoot/../TestCity.ps1"
  . "$PSScriptRoot/../../scripts/lib/VenueAddress.ps1"

  function New-LdPage([object[]]$Nodes) {
    $json = ConvertTo-Json -InputObject @($Nodes) -Depth 8
    "<html><head><script type=""application/ld+json"">$json</script></head><body><footer>Office: 99 Org Way, Boise, ID 83706</footer></body></html>"
  }

  function New-LdEvent([string]$Name, [string]$Place, [string]$Street, [string]$Town = 'Boise', [string]$Zip = '83702') {
    [ordered]@{
      '@context' = 'https://schema.org'; '@type' = 'Event'; name = $Name
      location   = [ordered]@{
        '@type' = 'Place'; name = $Place
        address = [ordered]@{ '@type' = 'PostalAddress'; streetAddress = $Street; addressLocality = $Town; addressRegion = 'ID'; postalCode = $Zip }
      }
    }
  }
}

Describe 'Test-WkNameMatch' {
  It 'matches names that differ only in case, accents, punctuation, and a leading "the"' {
    Test-WkNameMatch 'The Egyptian Theatre' 'egyptian theatre' | Should -BeTrue
    Test-WkNameMatch 'Café Ole!' 'Cafe Ole' | Should -BeTrue
  }

  It 'matches when every word of the shorter name is in the longer, with at least two words' {
    Test-WkNameMatch 'Eagle Chamber of Commerce' 'Eagle Chamber of Commerce Office' | Should -BeTrue
  }

  It 'does not match on a single shared word' {
    Test-WkNameMatch 'Eagle' 'Eagle Chamber of Commerce' | Should -BeFalse
  }

  It 'does not match different places' {
    Test-WkNameMatch 'Boise Public Library' 'Boise Little Theater' | Should -BeFalse
  }
}

Describe 'Get-WkPageAddress' {
  It 'reads the address of a JSON-LD event whose name is the event''s title' {
    $html = New-LdPage @(New-LdEvent 'Jazz Night' 'Somewhere' '123 Main St')
    Get-WkPageAddress -Html $html -Venue 'Neurolux' -Title 'Jazz Night' | Should -Be '123 Main St, Boise, ID 83702'
  }

  It 'reads the matching event''s address from a listing page with several events' {
    $html = New-LdPage @((New-LdEvent 'Yoga' 'Studio A' '1 First St'), (New-LdEvent 'Jazz Night' 'Club B' '2 Second St'), (New-LdEvent 'Trivia' 'Pub C' '3 Third St'))
    Get-WkPageAddress -Html $html -Venue 'Club B Lounge Bar' -Title 'Jazz Night' | Should -Be '2 Second St, Boise, ID 83702'
  }

  It 'reads a JSON-LD place whose name is the venue''s' {
    $html = New-LdPage @(New-LdEvent 'Some Other Show' 'The Egyptian Theatre' '700 W Main St')
    Get-WkPageAddress -Html $html -Venue 'Egyptian Theatre' -Title 'Film Night' | Should -Be '700 W Main St, Boise, ID 83702'
  }

  It 'takes no JSON-LD address that belongs to neither the event nor the venue' {
    $html = New-LdPage @(New-LdEvent 'Some Other Show' 'Another Hall' '5 Fifth St')
    Get-WkPageAddress -Html $html -Venue 'Egyptian Theatre' -Title 'Film Night' | Should -BeNullOrEmpty
  }

  It 'reads schema.org microdata inside a place named for the venue' {
    $html = '<div itemscope itemtype="https://schema.org/Place"><span itemprop="name">Boise Little Theater</span><div itemprop="address" itemscope itemtype="https://schema.org/PostalAddress"><span itemprop="streetAddress">100 E Fort St</span>, <span itemprop="addressLocality">Boise</span>, <span itemprop="addressRegion">ID</span> <span itemprop="postalCode">83712</span></div></div>'
    Get-WkPageAddress -Html $html -Venue 'Boise Little Theater' -Title 'Play' | Should -Be '100 E Fort St, Boise, ID 83712'
  }

  It 'reads an address written just after the venue''s name' {
    $html = '<p>Join us at <b>Star Chamber of Commerce</b>, 10769 W State St, Star, ID 83669 for coffee.</p>'
    Get-WkPageAddress -Html $html -Venue 'Star Chamber of Commerce' -Title 'Coffee' | Should -Be '10769 W State St, Star, ID 83669'
  }

  It 'reads an address with a unit and a written-out state' {
    $html = '<p>Telaya Wine Co.<br>240 E 32nd St, Suite 100, Garden City, Idaho 83714</p>'
    Get-WkPageAddress -Html $html -Venue 'Telaya Wine Co.' -Title 'Tasting' | Should -Be '240 E 32nd St, Suite 100, Garden City, ID 83714'
  }

  It 'ignores an address with no venue name before it, such as an organizer''s footer' {
    $html = '<p>Coffee with friends.</p><footer>Star Chamber, 10769 W State St, Star, ID 83669</footer>'
    Get-WkPageAddress -Html $html -Venue 'West Idaho Brazilian Jiu-Jitsu' -Title 'Open Mat' | Should -BeNullOrEmpty
  }

  It 'ignores an address more than 200 characters after the venue''s name' {
    $html = "<p>Star Chamber of Commerce $('x ' * 150) 10769 W State St, Star, ID 83669</p>"
    Get-WkPageAddress -Html $html -Venue 'Star Chamber of Commerce' -Title 'Coffee' | Should -BeNullOrEmpty
  }

  It 'skips a broken JSON-LD block' {
    $html = '<script type="application/ld+json">{ not json</script><p>Neurolux, 111 N 11th St, Boise, ID 83702</p>'
    Get-WkPageAddress -Html $html -Venue 'Neurolux' -Title 'Show' | Should -Be '111 N 11th St, Boise, ID 83702'
  }
}

Describe 'Find-WkAddressPoint' {
  BeforeAll {
    # Answers by URL fragment; anything else is an empty answer. Each URL is kept in $script:calls.
    function New-Fetcher([hashtable]$Answers = @{}, [string[]]$Throw = @()) {
      $script:calls = [Collections.Generic.List[string]]::new()
      $list = $script:calls
      {
        param([string]$Url)
        $list.Add($Url)
        foreach ($key in $Throw) { if ($Url -like "*$key*") { throw 'Request failed: timed out' } }
        foreach ($key in $Answers.Keys) { if ($Url -like "*$key*") { return $Answers[$key] } }
        if ($Url -like '*geocoding.geo.census.gov*') { return [pscustomobject]@{ result = [pscustomobject]@{ addressMatches = @() } } }
        , @()
      }.GetNewClosure()
    }
    $script:censusHit = [pscustomobject]@{ result = [pscustomobject]@{ addressMatches = @([pscustomobject]@{ coordinates = [pscustomobject]@{ x = -116.2012; y = 43.6033 } }) } }
    $script:osmHit = , @([pscustomobject]@{ lat = '43.61'; lon = '-116.21'; addresstype = 'building' })
    $script:zipHit = , @([pscustomobject]@{ lat = '43.62'; lon = '-116.22'; addresstype = 'postcode' })
  }

  It 'uses the Census geocoder first' {
    $point = Find-WkAddressPoint -Address '2201 W Cesar Chavez Ln, Boise, ID 83725' -Fetch (New-Fetcher @{ 'geocoding.geo.census.gov' = $censusHit }) -Health @{}
    $point.lat | Should -Be 43.6033
    $point.lon | Should -Be -116.2012
    $point.from | Should -Be 'address'
    $calls.Count | Should -Be 1
    $calls[0] | Should -BeLike 'https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?address=2201%20W%20Cesar*&benchmark=Public_AR_Current&format=json'
  }

  It 'asks Nominatim by address parts when Census has no match' {
    $point = Find-WkAddressPoint -Address '240 E 32nd St, Suite 100, Garden City, ID 83714' -Fetch (New-Fetcher @{ 'street=' = $osmHit }) -Health @{}
    $point.lat | Should -Be 43.61
    $point.from | Should -Be 'address'
    $calls[1] | Should -BeLike 'https://nominatim.openstreetmap.org/search?*street=240%20E%2032nd%20St%2C%20Suite%20100&city=Garden%20City&state=ID&postalcode=83714*'
    $calls[1] | Should -Not -BeLike '*q=*'
  }

  It 'falls back to the ZIP code''s center' {
    $point = Find-WkAddressPoint -Address '9 Nowhere Rd, Boise, ID 83702' -Fetch (New-Fetcher @{ 'postalcode=83702&country' = $zipHit }) -Health @{}
    $point.from | Should -Be 'zip'
    $point.lat | Should -Be 43.62
    $calls.Count | Should -Be 3
  }

  It 'gives nothing when nothing answers' {
    Find-WkAddressPoint -Address '9 Nowhere Rd, Boise, ID 83702' -Fetch (New-Fetcher) -Health @{} | Should -BeNullOrEmpty
  }

  It 'rejects a point far from the city' {
    $far = [pscustomobject]@{ result = [pscustomobject]@{ addressMatches = @([pscustomobject]@{ coordinates = [pscustomobject]@{ x = -111.89; y = 40.76 } }) } }
    (Find-WkAddressPoint -Address '1 Main St, Salt Lake City, UT 84101' -Fetch (New-Fetcher @{ 'geocoding.geo.census.gov' = $far }) -Health @{}) | Should -BeNullOrEmpty
  }

  It 'skips a service after three failures in a row and still asks the others' {
    $health = @{}
    $fetch = New-Fetcher @{ 'street=' = $osmHit } -Throw 'geocoding.geo.census.gov'
    foreach ($i in 1..3) { (Find-WkAddressPoint -Address '1 Main St, Boise, ID 83702' -Fetch $fetch -Health $health 3>$null).from | Should -Be 'address' }
    $calls.Clear()
    (Find-WkAddressPoint -Address '1 Main St, Boise, ID 83702' -Fetch $fetch -Health $health).from | Should -Be 'address'
    @($calls | Where-Object { $_ -like '*census*' }).Count | Should -Be 0
    $health.census | Should -Be 3
  }

  It 'does not count a missing page as a failure' {
    $health = @{}
    $fetch = { param($Url) throw 'HTTP 404 from x' }
    foreach ($i in 1..4) { Find-WkAddressPoint -Address '1 Main St, Boise, ID 83702' -Fetch $fetch -Health $health | Out-Null }
    [int]$health.census | Should -Be 0
  }
}

Describe 'Update-WkVenueAddresses' {
  BeforeAll {
    $script:now = [DateTimeOffset]::Parse('2026-11-29T10:00:00Z')

    function New-Stored([string]$Key, [string]$Venue, [string]$Url, [string]$Title = 'Show') {
      [pscustomobject]@{ title = $Title; venue = $Venue; venueKey = $Key; city = 'Boise'; url = $Url }
    }

    # Pages by URL fragment (HTML text), robots.txt allowing all unless -Robots says otherwise,
    # Census answering one point for any address. Each URL is kept in $script:calls.
    function New-Fetcher([hashtable]$Pages = @{}, [string]$Robots = '', [string[]]$Throw = @()) {
      $script:calls = [Collections.Generic.List[string]]::new()
      $list = $script:calls
      $hit = [pscustomobject]@{ result = [pscustomobject]@{ addressMatches = @([pscustomobject]@{ coordinates = [pscustomobject]@{ x = -116.2; y = 43.6 } }) } }
      {
        param([string]$Url, [switch]$Raw)
        $list.Add($Url)
        foreach ($key in $Throw) { if ($Url -like "*$key*") { throw 'Request failed: timed out' } }
        if ($Url -like '*/robots.txt') { return $Robots }
        if ($Url -like '*geocoding.geo.census.gov*') { return $hit }
        foreach ($key in $Pages.Keys) { if ($Url -like "*$key*") { return $Pages[$key] } }
        throw "HTTP 404 from $Url"
      }.GetNewClosure()
    }

    function Invoke-Locate($Events, $Raw = @(), $State = @{}, $Fetch = (New-Fetcher), [int]$Budget = 600) {
      Update-WkVenueAddresses -Events $Events -RawEvents $Raw -State $State -Now $now -BudgetSeconds $Budget -MinDelaySeconds 0 -Fetch $Fetch
    }

    $script:page = '<p>See you at Neurolux, 111 N 11th St, Boise, ID 83702.</p>'
  }

  It 'finds a venue''s address on its event page' {
    $result = Invoke-Locate @(New-Stored 'neurolux' 'Neurolux' 'https://neurolux.test/e/1') -Fetch (New-Fetcher @{ 'neurolux.test/e/1' = $page })
    $entry = $result.State['neurolux']
    $entry.from | Should -Be 'page'
    $entry.address | Should -Be '111 N 11th St, Boise, ID 83702'
    $entry.lat | Should -Be 43.6
    $entry.checked | Should -Be '2026-11-29'
    $result.Summary.found.page | Should -Be 1
  }

  It 'uses the address a source sent when the pages have none' {
    $raw = @([pscustomobject]@{ venueKey = 'hall'; location = [pscustomobject]@{ address = '1 Main St, Boise, ID 83702' } })
    $entry = (Invoke-Locate @(New-Stored 'hall' 'Hall' 'https://hall.test/e') $raw -Fetch (New-Fetcher @{ 'hall.test/e' = '<p>No address here</p>' })).State['hall']
    $entry.from | Should -Be 'address'
    $entry.address | Should -Be '1 Main St, Boise, ID 83702'
  }

  It 'does not read a page robots.txt disallows' {
    $fetch = New-Fetcher @{ 'neurolux.test/e/1' = $page } -Robots "User-agent: *`nDisallow: /e/"
    $result = Invoke-Locate @(New-Stored 'neurolux' 'Neurolux' 'https://neurolux.test/e/1') -Fetch $fetch
    @($calls | Where-Object { $_ -like '*/e/1' }).Count | Should -Be 0
    $result.State['neurolux'].from | Should -Be 'none'
    $result.Summary.robotsSkipped | Should -Be 1
  }

  It 'skips Google Calendar links' {
    Invoke-Locate @(New-Stored 'lib' 'Library' 'https://www.google.com/calendar/event?eid=x') | Out-Null
    @($calls | Where-Object { $_ -like '*google.com*' }).Count | Should -Be 0
  }

  It 'replaces a name-search entry when it finds an address, and keeps it when it does not' {
    $state = @{
      neurolux = [ordered]@{ lat = 43.5; lon = -116.1; from = 'lookup'; checked = '2026-11-23' }
      other    = [ordered]@{ lat = 43.5; lon = -116.1; from = 'lookup'; checked = '2026-11-23' }
    }
    $events = @((New-Stored 'neurolux' 'Neurolux' 'https://neurolux.test/e/1'), (New-Stored 'other' 'Other Hall' 'https://other.test/e'))
    $after = (Invoke-Locate $events -State $state -Fetch (New-Fetcher @{ 'neurolux.test/e/1' = $page; 'other.test/e' = '<p>nothing</p>' })).State
    $after['neurolux'].from | Should -Be 'page'
    $after['other'].from | Should -Be 'lookup'
    $after['other'].lat | Should -Be 43.5
    $after['other'].checked | Should -Be '2026-11-29'
  }

  It 'rechecks a page entry only after 90 days, and keeps it when the page has gone' {
    $state = @{
      fresh = [ordered]@{ lat = 43.5; lon = -116.1; address = '1 A St, Boise, ID 83702'; from = 'page'; checked = '2026-11-01' }
      old   = [ordered]@{ lat = 43.5; lon = -116.1; address = '1 B St, Boise, ID 83702'; from = 'page'; checked = '2026-08-30' }
    }
    $events = @((New-Stored 'fresh' 'Fresh Hall' 'https://fresh.test/e'), (New-Stored 'old' 'Old Hall' 'https://old.test/e'))
    $after = (Invoke-Locate $events -State $state).State
    @($calls | Where-Object { $_ -like '*fresh.test/e' }).Count | Should -Be 0
    @($calls | Where-Object { $_ -like '*old.test/e' }).Count | Should -Be 1
    $after['old'].from | Should -Be 'page'
    $after['old'].address | Should -Be '1 B St, Boise, ID 83702'
    $after['old'].checked | Should -Be '2026-11-29'
  }

  It 'leaves manual, feed, and placeholder entries alone' {
    $state = @{}
    foreach ($from in 'manual', 'feed') { $state[$from] = [ordered]@{ lat = 43.5; lon = -116.1; from = $from; checked = '2026-01-01' } }
    $state['placeholder'] = [ordered]@{ from = 'placeholder'; checked = '2026-01-01' }
    $events = @('manual', 'feed', 'placeholder' | ForEach-Object { New-Stored $_ "$_ Hall" "https://$_.test/e" })
    $after = (Invoke-Locate $events -State $state).State
    $calls.Count | Should -Be 0
    foreach ($from in 'manual', 'feed', 'placeholder') { $after[$from].checked | Should -Be '2026-01-01' }
  }

  It 'stops when its time is spent' {
    $events = @((New-Stored 'a' 'A Hall' 'https://a.test/1'), (New-Stored 'b' 'B Hall' 'https://b.test/1'))
    $result = Invoke-Locate $events -Budget 0
    $calls.Count | Should -Be 0
    $result.Summary.stoppedEarly | Should -BeTrue
  }

  It 'works on the busiest venue first' {
    $events = @((New-Stored 'a' 'A Hall' 'https://a.test/1'), (New-Stored 'b' 'B Hall' 'https://b.test/1'), (New-Stored 'b' 'B Hall' 'https://b.test/2'))
    Invoke-Locate $events | Out-Null
    @($calls | Where-Object { $_ -notlike '*robots.txt' })[0] | Should -BeLike 'https://b.test/*'
  }

  It 'reads at most three pages for a venue' {
    $events = @(1..5 | ForEach-Object { New-Stored 'v' 'V Hall' "https://v.test/$_" })
    Invoke-Locate $events | Out-Null
    @($calls | Where-Object { $_ -like 'https://v.test/[0-9]' }).Count | Should -Be 3
  }

  It 'takes the address most pages give' {
    $one = '<p>V Hall, 1 A St, Boise, ID 83702</p>'
    $two = '<p>V Hall, 2 B St, Boise, ID 83702</p>'
    $events = @(1..3 | ForEach-Object { New-Stored 'v' 'V Hall' "https://v.test/$_" })
    (Invoke-Locate $events -Fetch (New-Fetcher @{ 'v.test/1' = $one; 'v.test/2' = $two; 'v.test/3' = $two })).State['v'].address | Should -Be '2 B St, Boise, ID 83702'
  }

  It 'skips a host after three failures in a row and goes on with others' {
    $events = @((1..3 | ForEach-Object { New-Stored "d$_" "D$_ Hall" "https://down.test/$_" }) + (New-Stored 'z' 'Neurolux' 'https://neurolux.test/e/1') + (New-Stored 'd4' 'D4 Hall' 'https://down.test/4'))
    $result = Invoke-Locate $events -Fetch (New-Fetcher @{ 'neurolux.test/e/1' = $page } -Throw 'down.test/') 3>$null
    @($calls | Where-Object { $_ -like 'https://down.test/*' }).Count | Should -Be 3
    $result.State['z'].from | Should -Be 'page'
  }
}

Describe 'addresses read from pages are clean' {
  BeforeAll {
    function New-PlacePage($Address) {
      $node = [ordered]@{ '@context' = 'https://schema.org'; '@type' = 'Place'; name = 'Victory Branch Library'; address = $Address }
      "<script type=""application/ld+json"">$(ConvertTo-Json $node -Depth 5)</script>"
    }
  }

  It 'reads a street field that holds the whole address once' {
    $address = [ordered]@{ '@type' = 'PostalAddress'; streetAddress = '10664 W Victory Rd, Boise, ID 83709, USA'; addressLocality = 'Boise, ID'; addressRegion = 'Boise, ID' }
    Get-WkPageAddress -Html (New-PlacePage $address) -Venue 'Victory Branch Library' -Title 'x' | Should -Be '10664 W Victory Rd, Boise, ID 83709'
  }

  It 'drops empty and repeated parts' {
    $address = [ordered]@{ '@type' = 'PostalAddress'; streetAddress = '6427 W Ustick Rd,'; addressLocality = 'Boise, ID'; addressRegion = 'Boise, ID' }
    Get-WkPageAddress -Html (New-PlacePage $address) -Venue 'Victory Branch Library' -Title 'x' | Should -Be '6427 W Ustick Rd, Boise, ID'
  }

  It 'takes no address without a house number' {
    $address = [ordered]@{ '@type' = 'PostalAddress'; streetAddress = ''; addressLocality = 'Boise'; addressRegion = 'ID' }
    Get-WkPageAddress -Html (New-PlacePage $address) -Venue 'Victory Branch Library' -Title 'x' | Should -BeNullOrEmpty
    Get-WkPageAddress -Html (New-PlacePage 'Boise, ID') -Venue 'Victory Branch Library' -Title 'x' | Should -BeNullOrEmpty
  }

  It 'decodes HTML entities' {
    $address = [ordered]@{ '@type' = 'PostalAddress'; streetAddress = '15 Smith &amp; Sons Way'; addressLocality = 'Nampa'; addressRegion = 'ID'; postalCode = '83686' }
    Get-WkPageAddress -Html (New-PlacePage $address) -Venue 'Victory Branch Library' -Title 'x' | Should -Be '15 Smith & Sons Way, Nampa, ID 83686'
  }
}

Describe 'review fixes' {
  BeforeAll {
    function New-LdPage2([object[]]$Nodes) {
      "<script type=""application/ld+json"">$(ConvertTo-Json -InputObject @($Nodes) -Depth 8)</script>"
    }
    function New-LdEvent2([string]$Name, [string]$Place, [string]$Street) {
      [ordered]@{ '@type' = 'Event'; name = $Name; location = [ordered]@{ '@type' = 'Place'; name = $Place; address = [ordered]@{ streetAddress = $Street; addressLocality = 'Boise'; addressRegion = 'ID'; postalCode = '83702' } } }
    }
  }

  It 'takes the same-titled event at this venue, not the first one' {
    $html = New-LdPage2 @((New-LdEvent2 'Adult Craft Night' 'Bar A' '1 A St'), (New-LdEvent2 'Adult Craft Night' 'Bar B' '2 B St'))
    Get-WkPageAddress -Html $html -Venue 'Bar B' -Title 'Adult Craft Night' | Should -Be '2 B St, Boise, ID 83702'
  }

  It 'prefers an exact title over one that only contains it' {
    $html = New-LdPage2 @((New-LdEvent2 'Open Mic' 'Somewhere' '1 A St'), (New-LdEvent2 'Open Mic Night' 'Elsewhere' '2 B St'))
    Get-WkPageAddress -Html $html -Venue 'Club Z' -Title 'Open Mic Night' | Should -Be '2 B St, Boise, ID 83702'
  }

  It 'takes no address from text where another place comes between the venue''s name and it' {
    $html = '<li>Adult Craft Night at Neurolux, Friday 7 pm</li><li>Baby Rhyme Time at Pengilly''s Saloon, 513 W Main St, Boise, ID 83702</li>'
    Get-WkPageAddress -Html $html -Venue 'Neurolux' -Title 'Adult Craft Night' | Should -BeNullOrEmpty
  }

  It 'counts a "too many requests" answer as a failure' {
    $health = @{}
    foreach ($i in 1..3) { Find-WkAddressPoint -Address '1 Main St, Boise, ID 83702' -Fetch { param($Url) throw 'HTTP 429 from x' } -Health $health 3>$null | Out-Null }
    $health.census | Should -Be 3
  }
}
