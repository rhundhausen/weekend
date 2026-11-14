BeforeAll {
  . "$PSScriptRoot/../../scripts/lib/Scrape.ps1"
}

Describe 'Test-WkRobotsAllowed' {
  It 'allows everything with no robots.txt' {
    Test-WkRobotsAllowed '' '/events/' | Should -BeTrue
  }

  It 'treats an empty Disallow as allowing everything' {
    Test-WkRobotsAllowed "User-agent: *`nDisallow:" '/events/' | Should -BeTrue
  }

  It 'blocks a matching prefix' {
    $robots = "User-agent: *`nDisallow: /private/"
    Test-WkRobotsAllowed $robots '/private/page' | Should -BeFalse
    Test-WkRobotsAllowed $robots '/events/' | Should -BeTrue
  }

  It 'blocks the whole site with /' {
    Test-WkRobotsAllowed "User-agent: *`nDisallow: /" '/events/' | Should -BeFalse
  }

  It 'keeps a wildcard from blocking everything' {
    $robots = "User-agent: *`nDisallow: /*?format=json`nDisallow: /*?format=ical"
    Test-WkRobotsAllowed $robots '/calendar' | Should -BeTrue
    Test-WkRobotsAllowed $robots '/calendar?format=ical' | Should -BeFalse
    Test-WkRobotsAllowed $robots '/calendar?format=json' | Should -BeFalse
  }

  It 'honors an end anchor' {
    $robots = "User-agent: *`nDisallow: /*.pdf$"
    Test-WkRobotsAllowed $robots '/a.pdf' | Should -BeFalse
    Test-WkRobotsAllowed $robots '/a.pdf?x=1' | Should -BeTrue
  }

  It 'lets the longest rule win' {
    $robots = "User-agent: *`nDisallow: /events/`nAllow: /events/public/"
    Test-WkRobotsAllowed $robots '/events/public/a' | Should -BeTrue
    Test-WkRobotsAllowed $robots '/events/private/a' | Should -BeFalse
  }

  It 'lets Allow win a tie' {
    Test-WkRobotsAllowed "User-agent: *`nDisallow: /a`nAllow: /a" '/a' | Should -BeTrue
  }

  It 'ignores groups for other agents' {
    Test-WkRobotsAllowed "User-agent: Googlebot`nDisallow: /" '/events/' | Should -BeTrue
  }

  It 'prefers a group naming us over *' {
    $robots = "User-agent: *`nDisallow: /`n`nUser-agent: WeekendBoise`nDisallow: /private/"
    Test-WkRobotsAllowed $robots '/events/' | Should -BeTrue
  }

  It 'obeys a group naming us' {
    $robots = "User-agent: *`nDisallow:`n`nUser-agent: WeekendBoise`nDisallow: /"
    Test-WkRobotsAllowed $robots '/events/' | Should -BeFalse
  }

  It 'applies shared rules to agents listed together' {
    $robots = "User-agent: Googlebot`nUser-agent: *`nDisallow: /x/"
    Test-WkRobotsAllowed $robots '/x/a' | Should -BeFalse
  }

  It 'ignores comments' {
    Test-WkRobotsAllowed "User-agent: * # all`nDisallow: /x/ # hidden" '/x/a' | Should -BeFalse
  }
}

Describe 'Get-WkRobotsGroup' {
  It 'reads Crawl-delay from our group' {
    (Get-WkRobotsGroup "User-agent: *`nCrawl-delay: 10`n`nUser-agent: Siteimprove`nCrawl-delay: 20").Delay | Should -Be 10
  }
}

Describe 'Get-WkJsonLdEvent' {
  It 'finds a single event' {
    $html = '<script type="application/ld+json">{"@type":"Event","name":"Show"}</script>'
    (Get-WkJsonLdEvent $html).name | Should -Be 'Show'
  }

  It 'finds events in an array and in @graph' {
    $html = '<script type="application/ld+json">[{"@type":"Event","name":"A"},{"@type":"Thing"}]</script>' +
    '<script type="application/ld+json">{"@graph":[{"@type":"MusicEvent","name":"B"}]}</script>'
    (Get-WkJsonLdEvent $html).name | Should -Be @('A', 'B')
  }

  It 'ignores other types' {
    @(Get-WkJsonLdEvent '<script type="application/ld+json">{"@type":"Organization"}</script>').Count | Should -Be 0
  }

  It 'skips a broken block and keeps reading' {
    $html = '<script type="application/ld+json">{broken</script><script type="application/ld+json">{"@type":"Event","name":"Good"}</script>'
    (Get-WkJsonLdEvent $html).name | Should -Be 'Good'
  }

  It 'returns nothing for a page with no data' {
    @(Get-WkJsonLdEvent '<html></html>').Count | Should -Be 0
  }
}

Describe 'ConvertFrom-WkJsLiteral' {
  It 'reads objects with bare and quoted keys, arrays, strings, numbers, and constants' {
    $v = ConvertFrom-WkJsLiteral '{Id:214,"Name":"Lunch \"Out\"",Score:-1.5e2,Tags:[true,false,null],Gone:void 0}'
    $v.Id | Should -Be 214
    $v.Name | Should -BeExactly 'Lunch "Out"'
    $v.Score | Should -Be -150
    $v.Tags.Count | Should -Be 3
    $v.Tags[0] | Should -BeTrue
    $v.Tags[2] | Should -BeNullOrEmpty
    $v.PSObject.Properties.Name | Should -Contain 'Gone'
  }

  It 'decodes JavaScript string escapes' {
    (ConvertFrom-WkJsLiteral '"<b>A\r\n\\B\/\x41\''"') | Should -BeExactly "<b>A`r`n\B/A'"
  }

  It 'fills in the arguments of a SvelteKit payload function' {
    $v = ConvertFrom-WkJsLiteral '(function(a,b,$c){return {type:"data",data:{events:[{Name:a,Description:b},{Name:a,Tags:[$c]}]}}}("Story Time",null,7))'
    $v.data.events[0].Name | Should -Be 'Story Time'
    $v.data.events[1].Name | Should -Be 'Story Time'
    $v.data.events[0].Description | Should -BeNullOrEmpty
    $v.data.events[1].Tags[0] | Should -Be 7
  }

  It 'reads a payload function inside an array, as SvelteKit lists one per page node' {
    $v = ConvertFrom-WkJsLiteral '[null,(function(a){return {data:{events:[{Name:a}]}}}("Story Time")),null]'
    $v.Count | Should -Be 3
    $v[1].data.events[0].Name | Should -Be 'Story Time'
  }

  It 'keeps an empty array an array' {
    $v = ConvertFrom-WkJsLiteral '{MainPhotos:[]}'
    , $v.MainPhotos | Should -BeOfType [object[]]
    $v.MainPhotos.Count | Should -Be 0
  }

  It 'fails on code it does not read' {
    { ConvertFrom-WkJsLiteral '{When:new Date(0)}' } | Should -Throw '*unexpected*'
    { ConvertFrom-WkJsLiteral '{Name:z}' } | Should -Throw '*unknown name*'
  }
}
