BeforeAll {
  . "$PSScriptRoot/../TestCity.ps1"
  . "$PSScriptRoot/../../scripts/lib/Report.ps1"

  $script:sources = @(
    [pscustomobject]@{ name = 'good'; displayName = 'Good Venue'; status = 'running'; adapter = 'ics'; url = 'https://good.test/cal.ics' }
    [pscustomobject]@{ name = 'blocked'; displayName = 'Blocked Site'; status = 'running'; adapter = 'scrape'; url = 'https://blocked.test/events/' }
    [pscustomobject]@{ name = 'empty'; displayName = 'Empty Site'; status = 'running'; adapter = 'scrape'; url = 'https://empty.test/' }
    [pscustomobject]@{ name = 'waiting'; displayName = 'Waiting Venue'; status = 'ready'; adapter = 'tribe'; url = 'https://waiting.test/' }
    [pscustomobject]@{ displayName = 'Puzzling Site'; status = 'investigating'; url = 'https://puzzle.test/'; notes = 'Loads with JavaScript' }
    [pscustomobject]@{ displayName = 'Someday Club'; url = 'https://someday.test/' }
    [pscustomobject]@{ displayName = 'Never Again'; status = 'ruled-out'; reason = 'HTTP 403' }
  )
  $script:run = [pscustomobject]@{
    startedAt       = '2026-11-07T07:00:05Z'
    finishedAt      = '2026-11-07T07:05:32Z'
    fetchedAt       = '2026-11-07T07:00:05Z'
    asOf            = '2026-11-07T07:00:00Z'
    noWrite         = $false
    rawSources      = 3
    rawEvents       = 120
    sources         = @(
      [pscustomobject]@{ name = 'good'; status = 'ok'; fetched = 120; duration = '1.5s'; error = $null; warnings = @('good: skipping one event: no date') }
      [pscustomobject]@{ name = 'blocked'; status = 'failed'; fetched = 0; duration = '0.3s'; error = 'HTTP 405 from https://blocked.test/events/'; warnings = @() }
      [pscustomobject]@{ name = 'empty'; status = 'ok'; fetched = 0; duration = '0.9s'; error = $null; warnings = @() }
    )
  }
  $script:context = @{ Outcome = 'success'; RunUrl = 'https://github.test/runs/1'; Trigger = 'schedule' }
}

Describe 'New-WkIngestReport' {
  BeforeAll {
    $report = New-WkIngestReport -Run $run -Sources $sources -Context $context
  }

  It 'sums up the run in the subject' {
    $report.Subject | Should -BeExactly 'WeekendBoise Ingest: 2 of 3 sources ok, 120 events, 1 failed'
  }

  It 'shows start, finish, and duration in Boise time' {
    $report.Text | Should -Match 'Started: +Nov 7, 2026 12:00:05 AM MST'
    $report.Text | Should -Match 'Finished: +Nov 7, 2026 12:05:32 AM MST'
    $report.Text | Should -Match 'Duration: +5m 27s'
  }

  It 'lists a failed source with its page and the HTTP error' {
    $report.Text | Should -Match '(?s)Failed.*Blocked Site \(blocked\).*https://blocked\.test/events/.*HTTP 405'
  }

  It 'lists a source that succeeded with no events under Succeeded, with 0 events, and has no No events section' {
    $report.Text | Should -Match '(?s)== Succeeded \(2\) ==.*Empty Site \(empty\) +\| +0 events'
    $report.Text | Should -Not -Match '== No events'
  }

  It 'sums up the Meetup groups' {
    $withMeetup = $sources + @(
      [pscustomobject]@{ name = 'meetup-a'; displayName = 'Group A (Meetup)'; status = 'running'; adapter = 'meetup'; url = 'https://m.test/a' }
      [pscustomobject]@{ name = 'meetup-b'; displayName = 'Group B (Meetup)'; status = 'running'; adapter = 'meetup'; url = 'https://m.test/b' }
    )
    $runMeetup = $run | Select-Object *
    $runMeetup.sources = @($run.sources) + @(
      [pscustomobject]@{ name = 'meetup-a'; status = 'ok'; fetched = 0; duration = '1s'; warnings = @() }
      [pscustomobject]@{ name = 'meetup-b'; status = 'ok'; fetched = 4; duration = '1s'; warnings = @() }
    )
    $text = (New-WkIngestReport -Run $runMeetup -Sources $withMeetup -Context $context).Text
    $text | Should -Match 'Meetup groups: +2 ok, 1 with events, 4 events'
  }

  It 'lists warnings by source' {
    $report.Text | Should -Match '(?s)Warnings.*good: skipping one event: no date'
  }

  It 'lists the sources that are not running yet, by status' {
    $report.Text | Should -Match '(?s)Ready.*Waiting Venue'
    $report.Text | Should -Match '(?s)Investigating.*Puzzling Site.*Loads with JavaScript'
    $report.Text | Should -Match '(?s)Ideas.*Someday Club'
    $report.Text | Should -Match '(?s)Ruled out \(1\).*Never Again.*HTTP 403'
  }

  It 'explains each status under its heading' {
    $report.Text | Should -Match 'Ready \(1\): built and tested'
    $report.Text | Should -Match 'Investigating \(1\): looked at'
    $report.Text | Should -Match 'Ideas \(1\): suggested'
    $report.Text | Should -Match 'Ruled out \(1\): will not be used'
  }

  It 'links each succeeded source to its page' {
    $report.Html | Should -Match '<a href="https://good\.test/cal\.ics">Good Venue \(good\)</a>'
  }

  It 'links the workflow run' {
    $report.Html | Should -Match 'href="https://github\.test/runs/1"'
  }

  It 'escapes HTML in source text' {
    $odd = $run | Select-Object *
    $odd.sources = @([pscustomobject]@{ name = 'good'; status = 'failed'; fetched = 0; duration = '1s'; error = '<b>bad</b> & worse'; warnings = @() })
    (New-WkIngestReport -Run $odd -Sources $sources -Context $context).Html | Should -Match '&lt;b&gt;bad&lt;/b&gt; &amp; worse'
  }

  It 'says so in the subject when the job failed' {
    $failed = @{ Outcome = 'failure'; RunUrl = 'https://github.test/runs/1'; Trigger = 'schedule' }
    (New-WkIngestReport -Run $run -Sources $sources -Context $failed).Subject | Should -BeLikeExactly 'WeekendBoise Ingest FAILED:*'
  }

  It 'still reports when there is no run file' {
    $report = New-WkIngestReport -Run $null -Sources $sources -Context @{ Outcome = 'failure'; RunUrl = 'https://github.test/runs/2' }
    $report.Subject | Should -BeExactly 'WeekendBoise Ingest FAILED: no run.json'
    $report.Text | Should -Match 'https://github\.test/runs/2'
  }
}

Describe 'New-WkRefineReport' {
  BeforeAll {
    $refine = [pscustomobject]@{
      startedAt = '2026-11-07T07:06:00Z'; finishedAt = '2026-11-07T07:22:30Z'; asOf = '2026-11-07T07:00:00Z'
      rawSources = 40; rawEvents = 4997; upcoming = 2745; past = 31; cityFixes = 4
      costTiers = [pscustomobject]@{ free = 700; '$' = 300; '$$' = 250; '$$$' = 95; unknown = 1400 }
      archiveMonths = 2; skipLinkCheck = $false
      cityLookup = [pscustomobject]@{ skipped = $false; others = 72; pages = 40; requests = 61; found = 27; errors = @('https://x.test/e : HTTP 404 from https://x.test/e') }
      categories = [pscustomobject]@{ music = 900; sports = 300 }
      links = [pscustomobject]@{ checked = 812; broken = 3; newBroken = 1 }
      sources = [pscustomobject]@{ good = 100; blocked = 0 }
    }
    $links = [pscustomobject]@{
      checked = @()
      broken  = @(
        [pscustomobject]@{ title = 'Gone Show'; start = '2026-11-20T19:00:00-07:00'; url = 'https://good.test/gone'; reason = 'HTTP 404'; brokenSince = '2026-11-07T07:10:00Z'; new = $true; sources = 'good' }
        [pscustomobject]@{ title = 'Old Gone'; start = '2026-11-21T19:00:00-07:00'; url = 'https://good.test/old'; reason = 'HTTP 410'; brokenSince = '2026-11-01T07:10:00Z'; new = $false; sources = 'good' }
        [pscustomobject]@{ title = 'Down Host'; start = '2026-11-22T19:00:00-07:00'; url = 'https://down.test/x'; reason = 'timeout on 2 nights'; brokenSince = '2026-11-05T07:10:00Z'; new = $false; sources = 'blocked' }
      )
    }
    $report = New-WkRefineReport -Refine $refine -Links $links -Sources $sources -Context $context
  }

  It 'sums up the run in the subject' {
    $report.Subject | Should -BeExactly 'WeekendBoise Refine: 2745 upcoming, 3 broken links (1 new)'
  }

  It 'shows the basics' {
    $report.Text | Should -Match 'Duration: +16m 30s'
    $report.Text | Should -Match 'Raw file: +40 sources, 4997 events, as of Nov 7, 2026 12:00:00 AM MST'
    $report.Text | Should -Match 'Cities filled in: +4'
    $report.Text | Should -Match 'Cost tiers: +Free 700, \$ 300, \$\$ 250, \$\$\$ 95, unknown 1400'
    $report.Text | Should -Match 'City lookup: +27 of 72 Other events placed, 40 pages read'
    $report.Text | Should -Match '(?s)City lookup errors.*HTTP 404 from https://x\.test/e'
    $report.Text | Should -Match 'Links checked: +812'
  }

  It 'groups broken links by source, new ones first and marked' {
    $report.Text | Should -Match '(?s)Good Venue \(good\): 2.*NEW Gone Show.*HTTP 404.*Old Gone'
    $report.Text | Should -Match '(?s)Blocked Site \(blocked\): 1.*Down Host'
  }

  It 'lists published events by source' {
    $report.Text | Should -Match 'Good Venue \(good\) +100'
  }

  It 'says when the link check was skipped' {
    $skipped = $refine | Select-Object *
    $skipped.skipLinkCheck = $true
    (New-WkRefineReport -Refine $skipped -Links $links -Sources $sources -Context $context).Text | Should -Match 'Link check skipped'
  }

  It 'still reports when there is no refine file' {
    (New-WkRefineReport -Refine $null -Links $null -Sources $sources -Context @{ Outcome = 'failure'; RunUrl = 'u' }).Subject | Should -BeExactly 'WeekendBoise Refine FAILED: no refine.json'
  }
}

Describe 'Send-WkReport attachments' {
  It 'sends a file as a base64 attachment' {
    $file = Join-Path $TestDrive 'out.zip'
    [IO.File]::WriteAllBytes($file, [byte[]](1, 2, 3, 250))
    Mock Invoke-RestMethod { [pscustomobject]@{ id = 'abc' } }
    $null = Send-WkReport -Report @{ Subject = 'S'; Html = 'H'; Text = 'T' } -To 'me@test.example' -ApiKey 'k' -Attachment $file
    Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
      $body = $Body | ConvertFrom-Json
      $body.attachments[0].filename -eq 'out.zip' -and
      ([Convert]::FromBase64String($body.attachments[0].content) -join ',') -eq '1,2,3,250'
    }
  }

  It 'sends several files as separate attachments' {
    $out = Join-Path $TestDrive 'out.zip'
    $logs = Join-Path $TestDrive 'ingest-logs.zip'
    [IO.File]::WriteAllBytes($out, [byte[]](1))
    [IO.File]::WriteAllBytes($logs, [byte[]](2))
    Mock Invoke-RestMethod { [pscustomobject]@{ id = 'abc' } }
    $null = Send-WkReport -Report @{ Subject = 'S'; Html = 'H'; Text = 'T' } -To 'me@test.example' -ApiKey 'k' -Attachment $out, $logs
    Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
      $body = $Body | ConvertFrom-Json
      ($body.attachments.filename -join ',') -eq 'out.zip,ingest-logs.zip'
    }
  }

  It 'names the attachment in the report' {
    $report = New-WkIngestReport -Run $run -Sources $sources -Context ($context + @{ Attachment = 'out.zip (415 KB)' })
    $report.Text | Should -Match 'Attached: +out\.zip \(415 KB\)'
  }
}

Describe 'Send-WkReport' {
  It 'posts the report to Resend' {
    Mock Invoke-RestMethod { [pscustomobject]@{ id = 'abc' } }
    $null = Send-WkReport -Report @{ Subject = 'S'; Html = '<p>H</p>'; Text = 'T' } -To 'me@test.example' -ApiKey 'key123'
    Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
      $body = $Body | ConvertFrom-Json
      $Uri -eq 'https://api.resend.com/emails' -and $Method -eq 'Post' -and $Headers.Authorization -eq 'Bearer key123' -and
      $body.to[0] -eq 'me@test.example' -and $body.subject -eq 'S' -and $body.html -eq '<p>H</p>' -and $body.text -eq 'T' -and
      $body.from -eq 'WeekendBoise Reports <reports@weekendboise.com>' -and
      $body.reply_to[0] -eq 'me@test.example'
    }
  }
}

Describe 'Test-WkReminderDay' {
  It 'is true for the scheduled run at midnight Sunday in Boise' {
    # 2026-11-08 07:00 UTC is Sunday 12:00 AM MST.
    Test-WkReminderDay '2026-11-08T07:00:00Z' | Should -BeTrue
  }

  It 'is false on other days, including late Saturday night in Boise' {
    Test-WkReminderDay '2026-11-07T07:00:00Z' | Should -BeFalse
    Test-WkReminderDay '2026-11-08T06:00:00Z' | Should -BeFalse
  }
}

Describe 'New-WkLocalReminder' {
  BeforeAll {
    $script:localSources = @(
      [pscustomobject]@{ name = 'good'; displayName = 'Good Venue'; status = 'running'; url = 'https://good.test/' }
      [pscustomobject]@{ name = 'home'; displayName = 'Home Only Hall'; status = 'running'; local = $true; url = 'https://home.test/events/' }
      [pscustomobject]@{ name = 'paused'; displayName = 'Paused Hall'; status = 'investigating'; local = $true; url = 'https://paused.test/' }
    )
    $script:raw = [pscustomobject]@{
      asOf    = '2026-11-08T07:00:00Z'
      sources = [pscustomobject]@{
        good = [pscustomobject]@{ fetchedAt = '2026-11-08T07:00:05Z'; events = @(1, 2) }
        home = [pscustomobject]@{ fetchedAt = '2026-11-01T18:30:00Z'; events = @(1, 2, 3) }
      }
    }
    $script:reminder = New-WkLocalReminder -Sources $localSources -Raw $raw -RunUrl 'https://github.test/runs/1'
  }

  It 'has a subject that says what to do' {
    $reminder.Subject | Should -BeExactly 'WeekendBoise: run the local ingest this week (1 source)'
  }

  It 'says what the local run is for' {
    $reminder.Text | Should -Match "GitHub's servers"
    $reminder.Text | Should -Match 'home connection'
  }

  It 'lists each running local source with its last fetch and event count, and leaves out paused ones' {
    $reminder.Text | Should -Match 'Home Only Hall \(home\).*Nov 1, 2026 11:30:00 AM MST.*3 events'
    $reminder.Text | Should -Not -Match 'Paused Hall'
    $reminder.Text | Should -Not -Match 'Good Venue'
  }

  It 'says the source was never fetched when the raw file has no entry for it' {
    $text = (New-WkLocalReminder -Sources $localSources -Raw ([pscustomobject]@{ sources = [pscustomobject]@{} })).Text
    $text | Should -Match 'Home Only Hall \(home\).*never'
  }

  It 'gives the command to run' {
    $reminder.Text | Should -Match '\./ingestion/scripts/Invoke-LocalIngest\.ps1'
  }
}

Describe 'New-WkNightlyReport' {
  BeforeAll {
    $script:nightlyRefine = [pscustomobject]@{
      startedAt = '2026-11-07T07:06:00Z'; finishedAt = '2026-11-07T07:22:30Z'; asOf = '2026-11-07T07:00:00Z'
      rawSources = 3; rawEvents = 120; upcoming = 100; past = 5; cityFixes = 1
      skipLinkCheck = $false
      categories = [pscustomobject]@{ music = 60 }
      links = [pscustomobject]@{ checked = 80; broken = 1; newBroken = 1 }
      sources = [pscustomobject]@{ good = 100 }
    }
    $script:nightlyLinks = [pscustomobject]@{
      broken = @([pscustomobject]@{ title = 'Gone Show'; start = '2026-11-20T19:00:00-07:00'; url = 'https://good.test/gone'; reason = 'HTTP 404'; new = $true; sources = 'good' })
    }
    $script:ingestPart = New-WkIngestReport -Run $run -Sources $sources -Context @{ Outcome = 'success'; RunUrl = 'https://github.test/runs/1'; Trigger = 'schedule' }
    $script:refinePart = New-WkRefineReport -Refine $nightlyRefine -Links $nightlyLinks -Sources $sources -Context @{ Outcome = 'success'; RunUrl = 'https://github.test/runs/2'; Trigger = 'workflow_run'; Attachment = 'out.zip (1 KB); refine-out.zip (2 KB)' }
    $script:nightly = New-WkNightlyReport -Ingest $ingestPart -Refine $refinePart
  }

  It 'sums up both runs in the subject' {
    $nightly.Subject | Should -BeExactly 'WeekendBoise Nightly: ingest 2 of 3 sources ok, 120 events, 1 failed; refine 100 upcoming, 1 broken links (1 new)'
  }

  It 'has every section of both reports, the two run summaries first and the sources not running last' {
    $titles = @($nightly.Sections.Title)
    $titles[0] | Should -BeExactly 'Ingest: Run'
    $titles[1] | Should -BeExactly 'Refine: Run'
    $titles | Should -Contain 'Ingest: Failed (1)'
    $titles | Should -Contain 'Ingest: Succeeded (2)'
    $titles | Should -Contain 'Refine: Broken links (1)'
    $titles | Should -Contain 'Refine: Upcoming events by source'
    $titles[-1] | Should -BeLike 'Not running:*'
    $titles.Count | Should -Be ($ingestPart.Sections.Count + $refinePart.Sections.Count)
  }

  It 'links both workflow runs and keeps the details of each' {
    $nightly.Text | Should -Match 'https://github\.test/runs/1'
    $nightly.Text | Should -Match 'https://github\.test/runs/2'
    $nightly.Text | Should -Match 'HTTP 405 from https://blocked\.test/events/'
    $nightly.Text | Should -Match 'NEW Gone Show'
    $nightly.Html | Should -Match '<h2[^>]*>Refine: Broken links \(1\)</h2>'
  }

  It 'says FAILED next to the run that failed' {
    $failedRefine = New-WkRefineReport -Refine $null -Links $null -Sources $sources -Context @{ Outcome = 'failure'; RunUrl = 'u' }
    (New-WkNightlyReport -Ingest $ingestPart -Refine $failedRefine).Subject |
      Should -BeExactly 'WeekendBoise Nightly FAILED: ingest 2 of 3 sources ok, 120 events, 1 failed; refine FAILED, no refine.json'
  }

  It 'carries the Sunday local ingest reminder after the run summaries' {
    $localSources = @([pscustomobject]@{ name = 'home'; displayName = 'Home Only Hall'; status = 'running'; local = $true; url = 'https://home.test/' })
    $reminder = New-WkLocalReminder -Sources $localSources -Raw ([pscustomobject]@{ sources = [pscustomobject]@{} })
    $report = New-WkNightlyReport -Ingest $ingestPart -Refine $refinePart -Reminder $reminder
    $report.Subject | Should -BeLike '*; run the local ingest this week'
    $report.Sections[2].Title | Should -BeExactly 'Local ingest reminder: What this is for'
    $report.Text | Should -Match '\./ingestion/scripts/Invoke-LocalIngest\.ps1'
  }
}
