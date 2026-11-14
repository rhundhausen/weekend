#Requires -Version 7.4
<#
.SYNOPSIS
  Shows the visitor log: who opened the site, from where, on what, and what they searched for.
.DESCRIPTION
  Reads the city's private visitor log D1 database (logDatabase in city.json, such as
  weekendboise-log) with wrangler, signed in as you. Nothing about the log is public: the site only
  writes to it, and reading it needs your Cloudflare login (run "npx wrangler login" once). Run
  from anywhere in the city repo; times are shown in the city's time zone.
.PARAMETER Days
  How far back to look. Rows are kept 90 days.
.PARAMETER Last
  The most rows to show, newest first.
.PARAMETER Ip
  Only this IP address.
.PARAMETER Search
  Only rows whose search words contain this text.
.PARAMETER Summary
  Counts instead of rows: visits by device, browser, and city, the top searches, and searches
  that matched nothing.
.PARAMETER IncludeBots
  Keep rows from crawlers, which are left out by default.
.PARAMETER CityRoot
  The city repo. Defaults to $env:WEEKEND_CITY_ROOT, else the nearest folder at or above the
  current directory with a city.json.
.EXAMPLE
  ../weekend/website/scripts/Get-VisitorLog.ps1 -Days 1
.EXAMPLE
  ../weekend/website/scripts/Get-VisitorLog.ps1 -Summary -Days 30
#>
[CmdletBinding()]
param(
  [int]$Days = 7,
  [int]$Last = 100,
  [string]$Ip,
  [string]$Search,
  [switch]$Summary,
  [switch]$IncludeBots,
  [string]$CityRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' '..' 'ingestion' 'scripts' 'lib' 'City.ps1')
$null = Set-WkCityRoot $CityRoot
$city = Get-WkCity
# wrangler reads the city's website/wrangler.jsonc, which binds the database.
$website = Get-WkCityPath 'website'

function Invoke-LogQuery([string]$Sql) {
  Push-Location $website
  try {
    $out = & npx --yes wrangler d1 execute $city.logDatabase --remote --json --command $Sql 2>&1
    if ($LASTEXITCODE) { throw "wrangler failed: $($out -join "`n")" }
  } finally {
    Pop-Location
  }
  $json = ($out | Where-Object { $_ -is [string] }) -join "`n"
  @(($json | ConvertFrom-Json -DateKind String)[0].results)
}

function Format-Sql([string]$Text) { "'" + ($Text -replace "'", "''") + "'" }

$since = [DateTimeOffset]::UtcNow.AddDays(-$Days).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$where = @("ts >= $(Format-Sql $since)")
if (-not $IncludeBots) { $where += 'bot = 0' }
if ($Ip) { $where += "ip = $(Format-Sql $Ip)" }
if ($Search) { $where += "q LIKE $(Format-Sql "%$Search%")" }
$filter = $where -join ' AND '

if ($Summary) {
  $queries = [ordered]@{
    'Visits by device'           = "SELECT device, COUNT(*) AS views, COUNT(DISTINCT ip) AS people FROM visits WHERE $filter AND kind = 'view' GROUP BY device ORDER BY views DESC"
    'Visits by browser'          = "SELECT browser, os, COUNT(*) AS views FROM visits WHERE $filter AND kind = 'view' GROUP BY browser, os ORDER BY views DESC LIMIT 15"
    'Visits by city'             = "SELECT city, region, COUNT(*) AS views, COUNT(DISTINCT ip) AS people FROM visits WHERE $filter AND kind = 'view' GROUP BY city, region ORDER BY views DESC LIMIT 15"
    'Top searches'               = "SELECT q AS search, COUNT(*) AS times, COUNT(DISTINCT ip) AS people FROM visits WHERE $filter AND q IS NOT NULL GROUP BY lower(q) ORDER BY times DESC LIMIT 25"
    'Searches that found nothing' = "SELECT q AS search, qs AS filters, COUNT(*) AS times FROM visits WHERE $filter AND results = 0 GROUP BY qs ORDER BY times DESC LIMIT 25"
  }
  foreach ($title in $queries.Keys) {
    Write-Host "`n$title, last $Days days" -ForegroundColor Cyan
    Invoke-LogQuery $queries[$title] | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
  }
  return
}

$local = [TimeZoneInfo]::FindSystemTimeZoneById($city.timeZone)
Invoke-LogQuery "SELECT ts, kind, ip, city, region, device, browser, os, q, qs, results, referrer FROM visits WHERE $filter ORDER BY ts DESC LIMIT $Last" |
  ForEach-Object {
    [pscustomobject]@{
      When     = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse($_.ts), $local).ToString('MMM d h:mm tt')
      Kind     = $_.kind
      IP       = $_.ip
      Where    = (@($_.city, $_.region) | Where-Object { $_ }) -join ', '
      Device   = $_.device
      Browser  = "$($_.browser) on $($_.os)"
      Search   = $_.q
      Filters  = $_.qs
      Results  = $_.results
      Referrer = $_.referrer
    }
  } | Format-Table -AutoSize -Wrap | Out-String -Width 260
