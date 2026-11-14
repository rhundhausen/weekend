# weekend

The shared engine behind the Weekend city event sites. It reads public event calendars, feeds,
and APIs, normalizes events to one schema, merges duplicates, checks links, and builds a static
Hugo site from the result.

## Engine and city repos

This repo holds only code every city shares:

- `ingestion/scripts`: PowerShell 7 adapters, libraries, and the ingest, refine, publish, and
  report scripts.
- `ingestion/schema`: the event and source JSON schemas.
- `ingestion/tests`: Pester tests and their fixtures.
- `website`: Hugo layouts, assets, and the Cloudflare Worker.

Each city has its own repo (such as weekendboise) holding everything specific to that city:
`ingestion/sources.json`, `data/`, `website/hugo.toml`, `website/wrangler.jsonc`, favicons and
branding, and the city's docs. City names, sources, domains, and branding never live here.

## Status

The code was copied from weekendboise and is not yet parameterized: some files still have Boise
hardcoded in them. `docs/extraction.md` lists every file, which bucket it is in, and what is
hardcoded. The ingest and refine workflows are kept in `docs/workflows-source/` until they become
reusable workflows, so their schedules cannot fire from this repo.

## Tests

```powershell
Invoke-Pester -Path ./ingestion/tests
```

Tests that need city files (`sources.json`, `data/schema/`) fail here until those dependencies are
replaced with fixtures.
