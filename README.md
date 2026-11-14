# weekend

The shared engine and code behind the Weekend city event sites. It reads public event calendars, feeds,
and APIs, normalizes events to one schema, merges duplicates, checks links, and builds a static
Hugo site from the result.

## Engine and city repos

This repo holds only code every city shares:

- `ingestion/scripts`: PowerShell adapters, libraries, and the ingest, refine, publish, and
  report scripts.
- `ingestion/schema`: the event and source JSON schemas.
- `ingestion/tests`: Pester tests and their fixtures.
- `ingestion/vocabulary`: categories, tags, and title case, which a city adds to.
- `website`: the Hugo theme (layouts, assets, and the Cloudflare Worker) and its build script.
  The theme config is `hugo.toml` at the repo root.
- `.github/workflows`: the engine's own tests (`test.yml`) and the reusable workflows every city
  calls: `ingest.yml`, `refine.yml`, and `city-test.yml`.

Each city has its own repo (such as weekendboise) holding everything specific to that city:
`city.json`, `ingestion/sources.json`, `data/`, `website/hugo.toml`, `website/wrangler.jsonc`,
favicons and branding, thin workflows that call the engine's, and the city's docs. City facts
never live here; adapters written for one site may (`docs/plan.md`).

## Status

The code was copied from weekendboise (`docs/extraction.md` records that copy) and now reads every
city fact from the city repo. `docs/plan.md` has the plan and the order of work. Cities track this
repo's `main`: an engine push reaches a city at its next build or workflow run.

## Tests

```powershell
Invoke-Pester -Path ./ingestion/tests
```

The tests run against a fixture city in `ingestion/tests/fixtures/city` (a copy of WeekendBoise's
`city.json`, the source entries the tests read, and its lookup tables), so they need no city repo.
Every test file loads `ingestion/tests/TestCity.ps1` first, which points `WEEKEND_CITY_ROOT` there.

## How scripts find the city

Every script takes `-CityRoot`. Without it, the city is `$env:WEEKEND_CITY_ROOT`, or else the
nearest folder at or above the current directory that holds a `city.json`. City facts come from
`city.json` (format: `ingestion/schema/city.schema.json`); the engine's vocabulary
(`ingestion/vocabulary`: categories, tags, title case) is merged with any additions in the city's
`data/schema/` files of the same names.
