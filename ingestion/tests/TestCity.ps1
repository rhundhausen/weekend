# Points the engine at the test fixture city (fixtures/city, a copy of WeekendBoise's city files), so
# the tests run with no city repo present. Every test file dot-sources this first in its BeforeAll.
$env:WEEKEND_CITY_ROOT = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'fixtures' 'city')).Path
$script:FixtureCity = $env:WEEKEND_CITY_ROOT
