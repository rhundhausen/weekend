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
