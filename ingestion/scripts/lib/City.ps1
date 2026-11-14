# The city this run is for. Every city fact the engine uses comes from the city repo's city.json
# (schema: ingestion/schema/city.schema.json), and every city file is found from the city root.

function Get-WkCityRoot {
  <#
  .SYNOPSIS
    The city repo's root folder: $env:WEEKEND_CITY_ROOT, or else the nearest folder at or above the
    current directory that holds a city.json.
  .DESCRIPTION
    Scripts with a -CityRoot parameter pass it to Set-WkCityRoot, which sets the environment
    variable, so adapters and child processes started by the script use the same city.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  # Cached per value of the variable (or per current directory), since this runs for every time conversion.
  $key = if ($env:WEEKEND_CITY_ROOT) { "env|$env:WEEKEND_CITY_ROOT" } else { "pwd|$((Get-Location).Path)" }
  if ($script:WkCityRootKey -eq $key) { return $script:WkCityRoot }
  $script:WkCityRoot = Find-WkCityRoot
  $script:WkCityRootKey = $key
  $script:WkCityRoot
}

function Find-WkCityRoot {
  if ($env:WEEKEND_CITY_ROOT) {
    $root = $env:WEEKEND_CITY_ROOT
    if (-not (Test-Path -LiteralPath (Join-Path $root 'city.json'))) { throw "WEEKEND_CITY_ROOT is '$root', which has no city.json" }
    return (Resolve-Path -LiteralPath $root).Path
  }
  $dir = (Get-Location).Path
  while ($dir) {
    if (Test-Path -LiteralPath (Join-Path $dir 'city.json')) { return $dir }
    $parent = Split-Path -Parent $dir
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
  }
  throw 'No city repo found: run from a city repo (a folder with city.json), or pass -CityRoot or set WEEKEND_CITY_ROOT'
}

function Set-WkCityRoot {
  # Makes Root (when given) the city for this process and its child processes; returns the root in use.
  [CmdletBinding()]
  [OutputType([string])]
  param([AllowEmptyString()][string]$Root)

  if ($Root) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'city.json'))) { throw "'$Root' has no city.json" }
    $env:WEEKEND_CITY_ROOT = (Resolve-Path -LiteralPath $Root).Path
  }
  Get-WkCityRoot
}

function Get-WkCityCached {
  # Loads a city table once per city root: Loader runs the first time CacheKey is asked for under a
  # root. The loader runs in this function's scope, so these names are unusual to stay out of its way.
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string]$WkCacheKey, [Parameter(Mandatory, Position = 1)][scriptblock]$WkLoader)

  if (-not $script:WkCityCache) { $script:WkCityCache = @{} }
  $wkFullKey = "$(Get-WkCityRoot)|$WkCacheKey"
  if (-not $script:WkCityCache.ContainsKey($wkFullKey)) { $script:WkCityCache[$wkFullKey] = , (& $WkLoader) }
  $script:WkCityCache[$wkFullKey][0]
}

function Get-WkCityPath {
  # A path inside the city repo, such as Get-WkCityPath data schema sizes.json.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Parts)

  $path = Get-WkCityRoot
  foreach ($part in $Parts) { $path = Join-Path $path $part }
  $path
}

function Get-WkEnginePath {
  # A path inside this engine's ingestion folder, such as Get-WkEnginePath schema event.schema.json.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Parts)

  $path = Join-Path $PSScriptRoot '..' '..'
  foreach ($part in $Parts) { $path = Join-Path $path $part }
  [IO.Path]::GetFullPath($path)
}

function Get-WkCity {
  <#
  .SYNOPSIS
    The city's city.json, loaded and checked once per city root, with the derived values added.
  .DESCRIPTION
    Derived values: userAgent ("<siteName>/1.0 (+https://github.com/<repo>)"), robotsToken
    (siteName in lowercase), botName and botEmail (the data commit identity), reportFrom (the
    report sender), and issuesUrl.
  #>
  [CmdletBinding()]
  param()

  Get-WkCityCached 'city' { Read-WkCityFile (Join-Path (Get-WkCityRoot) 'city.json') }
}

function Read-WkCityFile {
  # Reads and checks one city.json and adds the derived values (see Get-WkCity).
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string]$Path)

  $text = Get-Content -LiteralPath $Path -Raw
  $schema = Get-Content -LiteralPath (Get-WkEnginePath 'schema' 'city.schema.json') -Raw
  $errors = $null
  if (-not ($text | Test-Json -Schema $schema -ErrorVariable errors -ErrorAction SilentlyContinue)) {
    throw "$Path does not match ingestion/schema/city.schema.json: $(@($errors | ForEach-Object { $_.ToString() }) -join '; ')"
  }
  $city = $text | ConvertFrom-Json -AsHashtable
  $lower = $city.siteName.ToLowerInvariant()
  $city.userAgent = "$($city.siteName)/1.0 (+https://github.com/$($city.repo))"
  $city.robotsToken = $lower
  $city.botName = "$($city.siteName) bot"
  $city.botEmail = "$lower-bot@noreply.invalid"
  $city.reportFrom = "$($city.siteName) Reports <reports@$($city.domain)>"
  $city.issuesUrl = "https://github.com/$($city.repo)/issues/new?"
  foreach ($key in 'cityAliases', 'zipCodes', 'titleAbbreviations', 'searchAliases') {
    if (-not $city[$key]) { $city[$key] = @{} }
  }
  foreach ($key in 'ambiguousCities', 'zipRanges', 'cityListLast') {
    if (-not $city[$key]) { $city[$key] = @() }
  }
  $city
}

function Get-WkStatePattern {
  # A regex alternation of the city's state code and name, such as "ID|Idaho".
  [CmdletBinding()]
  [OutputType([string])]
  param()

  Get-WkCityCached 'statePattern' {
    $state = (Get-WkCity).state
    "$([regex]::Escape($state.code))|$([regex]::Escape($state.name))"
  }
}

function Get-WkVocabulary {
  <#
  .SYNOPSIS
    One of the engine's vocabulary tables (ingestion/vocabulary), with the city's additions from
    data/schema/<Name>.json in the city repo when that file exists.
  .DESCRIPTION
    - tags: the city's keywords for a tag id are added to the engine's; a city tag with a new id
      is added whole.
    - categories: the city's includes for a category id replace the engine's.
    - title-case: the city's keepUpper and smallWords are added, and its forms override.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][ValidateSet('tags', 'categories', 'title-case')][string]$Name)

  $engine = Get-Content -LiteralPath (Get-WkEnginePath 'vocabulary' "$Name.json") -Raw | ConvertFrom-Json -AsHashtable
  $cityPath = Get-WkCityPath 'data' 'schema' "$Name.json"
  if (-not (Test-Path -LiteralPath $cityPath)) { return $engine }
  $local = Get-Content -LiteralPath $cityPath -Raw | ConvertFrom-Json -AsHashtable

  switch ($Name) {
    'tags' {
      $byId = [ordered]@{}
      foreach ($tag in $engine) { $byId[$tag.id] = $tag }
      foreach ($tag in @($local | Where-Object { $_ -is [Collections.IDictionary] -and $_.id })) {
        if ($byId.Contains($tag.id)) {
          $have = @($byId[$tag.id].keywords)
          $byId[$tag.id].keywords = @($have) + @($tag.keywords | Where-Object { $_ -notin $have })
        } else {
          $byId[$tag.id] = $tag
        }
      }
      return @($byId.Values)
    }
    'categories' {
      $includes = @{}
      foreach ($category in @($local | Where-Object { $_ -is [Collections.IDictionary] -and $_.id })) { $includes[$category.id] = $category.includes }
      foreach ($category in $engine) {
        if ($includes.ContainsKey($category.id)) { $category.includes = $includes[$category.id] }
      }
      return $engine
    }
    'title-case' {
      $engine.keepUpper = @(@($engine.keepUpper) + @($local.keepUpper) | Where-Object { $_ } | Select-Object -Unique)
      $engine.smallWords = @(@($engine.smallWords) + @($local.smallWords) | Where-Object { $_ } | Select-Object -Unique)
      if ($local.forms) { foreach ($key in $local.forms.Keys) { $engine.forms[$key] = $local.forms[$key] } }
      return $engine
    }
  }
}

function Get-WkSchemaText {
  <#
  .SYNOPSIS
    An engine JSON schema (event or sources) as text, with the city's city names in its city enum.
  .DESCRIPTION
    The engine's schemas list only "Other" as a city; each city's own list comes from city.json.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory, Position = 0)][ValidateSet('event', 'sources')][string]$Name)

  Get-WkCityCached "schema-$Name" {
    $schema = Get-Content -LiteralPath (Get-WkEnginePath 'schema' "$Name.schema.json") -Raw | ConvertFrom-Json -AsHashtable
    $cities = @(@((Get-WkCity).cities) + 'Other')
    switch ($Name) {
      'event' { $schema.properties.city.enum = $cities }
      'sources' { $schema['$defs'].source.properties.city.enum = $cities }
    }
    $schema | ConvertTo-Json -Depth 40
  }
}
