# Plan: one engine, lean city repos

Agreed with the site owner on 2026-11-14. `extraction.md` records what was copied and why; this
file says where it goes next.

## Goal

This repo holds all shared code: the website, every adapter (including ones written for a single
site), the ingest and refine workflows, and the tests. Each city repo holds only that city's
facts and data. Cities track this repo's `main` branch; there is no version pinning, so an engine
push reaches a city at its next deploy (the nightly refine).

## City repo layout

```
city.json                    city facts (below)
ingestion/sources.json       the city's sources
data/                        events, archive, links, meta (written by the workflows)
data/schema/                 venue-aliases.json, place-cities.json, sizes.json
website/wrangler.jsonc       Cloudflare Worker name, D1 binding, build command
website/static/              favicons and web manifest
website/assets/              the skyline SVG and any other branding
website/content/             only pages whose text the city changes
.github/workflows/           thin callers: ingest.yml, refine.yml, test.yml
```

A city never copies an engine file to change its text. Anything a city needs to vary is a field in
`city.json` or a Hugo override file at the same path as the engine's.

## city.json

One file, read by the PowerShell scripts and mounted into Hugo as `data/city.json`:

- `siteName`, `domain`, `repo` (for the User-Agent contact URL and report links)
- `userAgentToken` (the stable robots.txt product token, such as `WeekendBoise`)
- `timeZone` (IANA name)
- `state` codes and names accepted as local
- `zipTable` (ZIP to city), `cities` and their groupings, `ambiguousNames`, area rules
- `aliases` (search) and `abbreviations` (display)
- `coordinates` (sky theme latitude and longitude)
- `report` sender and subjects, `bot` commit identity
- `about` text fields used by the layouts

## Engine changes

1. **Prefix rename.** `Tv` becomes `Wk` everywhere (`New-WkEvent`, `Invoke-WkRequest`, globals,
   type names). Boise-named functions get neutral names: `ConvertTo-BoiseTime` becomes
   `ConvertTo-LocalTime`, `Get-BoiseTimeZone` becomes `Get-WkTimeZone` (read from `city.json`),
   `Test-BoiseHour.ps1` becomes `Test-LocalHour.ps1`.
2. **City root.** Every script takes `-CityRoot` (default: `$env:WEEKEND_CITY_ROOT`, then the
   current directory) and finds `sources.json`, `data/`, and `city.json` from it instead of from
   `$PSScriptRoot`. A new `lib/City.ps1` loads and checks `city.json`.
3. **Hardcoded city values** listed in `extraction.md` (time zone, `ID` state filters, User-Agent,
   robots token, bot identity, report sender, coordinates, city lists) are read from `city.json`.
4. **Shared vocabulary.** `categories.json`, `tags.json`, and `title-case.json` move into the
   engine as single supersets (local acronyms such as BSU or KTVB are allowed). The three
   city tables stay in each city's `data/schema/`.
5. **Tests** read a fixture city (`ingestion/tests/fixtures/city/`) with its own `city.json`,
   `sources.json` entries (Boulder's fixture approach), and lookup tables, so the engine's tests
   pass with no city repo present.
6. **Website as a Hugo theme.** The engine's `website/` is the theme. The engine's
   `website/site.toml` is every city's site config (title from `city.json`) and mounts the city's data (`../data`, `../ingestion/sources.json`, `../city.json`). City files
   at the same path override the theme's.
7. **Build.** The engine's `website/build.sh` installs Hugo, sets `TZ` from `city.json`, and builds.
   A city's Cloudflare build command clones this repo (`--depth 1`, public, no token) next to the
   site and runs that script; locally it uses the sibling `../weekend` checkout.
8. **Workflows.** `ingest.yml` and `refine.yml` become reusable workflows here
   (`on: workflow_call`). They check out the calling city repo and this repo. Each city's caller
   holds only the cron schedule and passes its secrets.
9. **About page legend** shows only categories with upcoming events, like the home page chips.

## Order of work

Each step is its own commit in the repo it changes. Every push is asked for first.

1. Engine: rename prefix and Boise-named functions.
2. Engine: city root, `lib/City.ps1`, values from `city.json`, shared vocabulary.
3. Engine: fixture city; all tests pass with no city repo.
4. Engine: Hugo theme, build script, reusable workflows, about legend.
5. Boulder (not live, so first): add `city.json`, thin callers, theme config; delete the copied
   engine code. Build and test locally, then deploy.
6. Boise: the same, plus the estate sale readers below. Boise is live, so it moves only after
   Boulder runs cleanly.

## Estate sales (Boise phase)

Both EstateSales.NET and EstateSales.org gave permission, per the site owner. The Python ingester
(`additional/ingest.py` and `ingest-additional.yml`), which used a browser identity and skipped
robots.txt, is replaced by two engine `sales` modes that identify as the city's User-Agent, check
robots.txt, and honor Crawl-delay. Both were probed honestly on 2026-11-14: robots.txt allows the
city pages, no Crawl-delay applies, and the pages served real listings with no bot challenge.

- **`estatesales-net`** reads `/ID/<City>` pages. Each page holds its sales in the
  `script#estatesales-net-state` data block (`NGRX_STATE.ui.sales.saleRows`, keyed by sale id):
  `name`, `orgName`, `cityName`, `postalCodeNumber`, `typeName`, and `dates[]` with local start
  and end per day. Kept types: `EstateSales`, `MovingSales`, `BusinessClosings`.
- **`estatesales-org`** reads `/estate-sales/id/<city>` pages. Each sale is a card with
  `data-auction-id`; the title, company, type, and sale link are on the card. Kept: in-person
  types. Online auctions are dropped (a Boise page also lists online auctions from other states).
- The list of city pages lives in Boise's `sources.json`. Sale pages are never fetched.
- The same sale often appears on both sites under different titles, so duplicate merging is
  tested against these pages.
- EstateSales.org's entry is updated to "permission given 2026-11-09, per the site owner".
