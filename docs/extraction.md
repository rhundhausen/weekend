# Extraction from weekendboise

This repo was populated by copying from weekendboise at commit `8596f40` ("Focus the search box
when the home page loads"). It was a copy, not a move: weekendboise and weekendboulder were not
changed. Every copied file is byte-identical to its blob at that commit (checked with
`git hash-object`). Nothing has been parameterized yet.

## Boise and Boulder compared

weekendboulder (at `5d532b3`) was compared with weekendboise, ignoring `data/`, generated output,
and `sources.json`. Line endings differ (Boise's working tree is CRLF, Boulder's is LF), so the
comparison ignored them. After that, every code difference falls into one of these groups:

- **Renames.** Boulder renamed the `Tv` prefix to `Wb` in every function, script variable, global,
  and type name (`Invoke-TvRequest` to `Invoke-WbRequest`, `$global:TvMeetupRobots` to
  `$global:WbMeetupRobots`, `TvJsRef` to `WbJsRef`), and `ConvertTo-BoiseTime`,
  `Get-BoiseTimeZone`, `Test-BoiseHour.ps1` to their Boulder names.
- **Localization.** `America/Boise` to `America/Denver`; `ID`/`Idaho` to `CO`/`Colorado`; `83xxx`
  ZIPs to `80xxx`; Boulder city lists, ZIP table, ambiguous names, and Gunbarrel rule in place of
  the Treasure Valley ones and Valley County; Boulder skyline SVG; sky-theme coordinates; display
  abbreviations; search aliases; examples in comments, fixtures, and tests.
- **Boise-only code removed.** The `cityofboise` adapter and its tests and fixtures; the scrape
  `calendarapp` mode; the sales `corbett`, `onthewater`, and `file` modes and `Get-TvNextDate`;
  the matching `sources.schema.json` enums and the `path` property; `ingest-additional.yml` and
  `additional/`.
- **Boise is ahead.** Boulder's `website/assets/js/app.js` lacks Boise's newest change, the
  search-box focus on page load.

**No fix in Boulder is missing from Boise, so weekendboise is the source for everything here.**
One Boulder change is worth adopting in the parameterize step, though it was not copied:

- Boulder's adapter tests (`Adapters.Tests.ps1`, `EventbriteSearch.Tests.ps1`,
  `Scrape.Tests.ps1`) read their source entries from `ingestion/tests/fixtures/sources/*.json`
  instead of the live `ingestion/sources.json`. That removes their dependency on a city file, which
  is exactly what the engine's tests need.
- Boulder also reworded two comments generically (the scrape cards default is "the common
  month/day card markup", not "Boise Centre's markup"). Cosmetic only.

## Cross-cutting notes

These affect many files at once, so they are listed here rather than repeated in every row.

- **City in identifier names.** The time zone itself is hardcoded only in `lib/Schema.ps1`
  (`Get-BoiseTimeZone`), but every adapter and several libraries call `ConvertTo-BoiseTime`. Callers
  that only use that name are classified Shared. The `Tv` prefix on every function (`New-TvEvent`,
  `Invoke-TvRequest`, `Resolve-TvCity`, ...) stands for Treasure Valley; Boulder renamed it to `Wb`.
  Neither is behavior, but both are Boise names in engine code and should be renamed before a
  second city adopts the engine.
- **Repo-layout paths.** Scripts and libraries find city files relative to `$PSScriptRoot`:
  `../sources.json`, `../../data/raw-events.json`, `../../data/events.json`, and
  `../../../data/schema/*.json` (`Invoke-Ingest.ps1`, `Invoke-Refine.ps1`, `Send-LocalReminder.ps1`,
  `Test-Schema.ps1`, `Test-Sources.ps1`, `adapters/meetup.ps1`, `lib/Cities.ps1`,
  `lib/Schema.ps1`). That works only while the engine sits inside a city checkout. The workflows
  and `website/hugo.toml` mounts make the same assumption.
- **Mountain-time offsets in tests.** Many tests (Dedupe, Scrape, Store, Adapters, Sales, Ics, and
  others) expect `-06:00`/`-07:00` offsets. They pass for any Mountain-time city and would need a
  configured zone in tests before a city in another zone.
- **Lookup tables in `data/schema/`.** `categories.json`, `tags.json`, and `title-case.json` look
  like engine vocabulary (only one to four Boise mentions each), while `place-cities.json`,
  `venue-aliases.json`, and `sizes.json` (venue capacities) are city knowledge. All six are in
  `data/`, so they are City and were not copied, but `lib/Schema.ps1`, `lib/Cities.ps1`,
  `Test-Schema.ps1`, and `Classify.Tests.ps1` read them.

## Files

Buckets: **Shared** is generic engine code with no city knowledge. **City** belongs in a city
repo. **Mixed** is shared logic with Boise hardcoded in it; the notes list exactly what. Shared
and Mixed files were copied to the same path here unless the "Copied to" column says otherwise.

| Path | Bucket | Copied to | What is hardcoded / notes |
| --- | --- | --- | --- |
| `.gitattributes` | Shared | recreated | Recreated in weekend from Boise's (step 6), not copied verbatim. |
| `.github/workflows/ingest-additional.yml` | Mixed | docs/workflows-source/ingest-additional.yml | Cron `30 5` and `30 6` UTC for 23:30 Boise; `Test-BoiseHour.ps1 -Hour 23`; URL `https://estatesales.org/estate-sales/id/boise?...`; runs `additional/` (City, not copied); commits `data/events-additional.json`. Copied to docs/workflows-source. |
| `.github/workflows/ingest.yml` | Mixed | docs/workflows-source/ingest.yml | Cron lines `0 6` and `0 7` UTC chosen for midnight in Boise (UTC-6/UTC-7); sparse checkout and run of `ingestion/scripts/Test-BoiseHour.ps1 -Hour 0`; step name "Check Boise time"; comments "midnight Boise time", "midnight Sunday, Boise time". Writes city-repo path `data/raw-events.json`. Copied to docs/workflows-source. |
| `.github/workflows/refine.yml` | Mixed | docs/workflows-source/refine.yml | Boise only in comments ("midnight in Boise"). Hardcodes city-repo data paths (`data/raw-events.json` push trigger; `data/events.json`, `data/archive`, `data/links.json`, `data/city-lookup.json`, `data/meta.json` commit list) and the upstream workflow name `ingest`. Copied to docs/workflows-source. |
| `.github/workflows/test.yml` | Shared | .github/workflows/test.yml | No city knowledge. Copied to weekend/.github/workflows. |
| `.gitignore` | Shared | recreated | Recreated in weekend from Boise's (step 6), not copied verbatim. |
| `LICENSE` | Shared | already present | Already in weekend; byte-identical to Boise's. |
| `README.md` | City | not copied | The public page for site owners who see the WeekendBoise bot: user agent, contact, opt-out, Treasure Valley scope. weekend gets its own README. |
| `additional/ingest.py` | City | not copied | Not copied (step 4). Playwright ingester for estate sale sites run with the site's permission; hardcodes `STATE = "ID"`, `America/Boise`, estatesales.org. |
| `additional/test_ingest.py` | City | not copied | Not copied (step 4). Tests for additional/ingest.py. |
| `data/archive/2026-10.json` | City | not copied | Data and city schema files. Not copied. |
| `data/archive/2026-11.json` | City | not copied | Data and city schema files. Not copied. |
| `data/city-lookup.json` | City | not copied | Data and city schema files. Not copied. |
| `data/events-additional.json` | City | not copied | Data and city schema files. Not copied. |
| `data/events.json` | City | not copied | Data and city schema files. Not copied. |
| `data/links.json` | City | not copied | Data and city schema files. Not copied. |
| `data/meta.json` | City | not copied | Data and city schema files. Not copied. |
| `data/raw-events.json` | City | not copied | Data and city schema files. Not copied. |
| `data/schema/categories.json` | City | not copied | Data and city schema files. Not copied. |
| `data/schema/place-cities.json` | City | not copied | Data and city schema files. Not copied. |
| `data/schema/sizes.json` | City | not copied | Data and city schema files. Not copied. |
| `data/schema/tags.json` | City | not copied | Data and city schema files. Not copied. |
| `data/schema/title-case.json` | City | not copied | Data and city schema files. Not copied. |
| `data/schema/venue-aliases.json` | City | not copied | Data and city schema files. Not copied. |
| `docs/cost-tiers.md` | Mixed | same path | Engine reference doc. City text: "WeekendBoise keeps no ticket prices (see the README)". |
| `docs/development.md` | Mixed | same path | Engine developer doc. City text: Treasure Valley scope and city list, "midnight Boise time", Test-BoiseHour, Boise Mom city-lookup examples, City of Boise API. |
| `docs/github-setup.md` | Mixed | same path | Setup runbook. City text: repo `rhundhausen/weekendboise` and its history, sender `WeekendBoise Reports <reports@weekendboise.com>`, "WeekendBoise bot" commit author, "midnight Boise time". |
| `docs/handoff.md` | City | not copied | Boise history (per instructions, not engine rules). |
| `docs/ingest-report.docx` | City | not copied | A Boise run report (2026-11-03). |
| `docs/ingest-report.md` | City | not copied | A Boise run report (2026-11-03). |
| `docs/schema.md` | Mixed | same path | Engine schema doc. City text: "ISO 8601 with the Boise offset", the 15-city enum, Boise venue and title examples (Neurolux, Knitting Factory, Extra Mile Arena), Boise Mom. |
| `docs/source-status.docx` | City | not copied | Boise source status. |
| `docs/source-status.md` | City | not copied | Boise source status. |
| `docs/sources.md` | City | not copied | Boise source catalog. |
| `docs/superpowers/plans/2026-11-05-emmett-links-cost.md` | City | not copied | Plan for a Boise feature (Emmett sources, links, cost). |
| `docs/superpowers/specs/2026-11-05-emmett-links-cost-design.md` | City | not copied | Design for a Boise feature (Emmett sources, links, cost). |
| `ingestion/.env.example.ps1` | Shared | same path | Template naming the API-key env vars the adapters read; no values, no city. (Unsure: you listed .env files as City; this is the example, not a secrets file.) |
| `ingestion/schema/event.schema.json` | Mixed | same path | `$id` URL `github.com/rhundhausen/weekendboise/...`; title "WeekendBoise event"; description "Treasure Valley event"; `city` enum of 15 Treasure Valley names plus Valley County and Other. |
| `ingestion/schema/sources.schema.json` | Mixed | same path | `$id` URL and title "WeekendBoise sources"; `city` enum (Boise ... Valley County); adapter enum includes `cityofboise`; scrapeMode `calendarapp` ("City of Boise calendar pages"); salesMode `corbett`, `onthewater`, `file` with descriptions naming Downs Auction, corbettauctions.com, onthewaterestatesales.com; `path` example `data/events-additional.json`; rss example "Ford Idaho Center Arena"; cards default "Boise Centre markup". |
| `ingestion/scripts/Invoke-Ingest.ps1` | Shared | same path | No city values. Defaults resolve `../../data/raw-events.json` and `../sources.json` relative to the script (see repo-layout note). |
| `ingestion/scripts/Invoke-LocalIngest.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/Invoke-Refine.ps1` | Shared | same path | Boise only in a comment example ("... at Zoo Boise"). Defaults resolve `data/` and `sources.json` relative to the script (see repo-layout note). |
| `ingestion/scripts/Publish-Data.ps1` | Mixed | same path | Git identity `user.name=WeekendBoise bot`, `user.email=weekendboise-bot@noreply.invalid`; commit date suffix taken in Boise time (`ConvertTo-BoiseTime`). |
| `ingestion/scripts/Save-RunLogs.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/Send-LocalReminder.ps1` | Shared | same path | Boise only in help text ("midnight Sunday, Boise time"); the Sunday test itself lives in lib/Report.ps1. |
| `ingestion/scripts/Send-Report.ps1` | Mixed | same path | Temp folder prefix `weekendboise-report-`. Sender and subjects come from lib/Report.ps1 defaults. |
| `ingestion/scripts/Test-BoiseHour.ps1` | Mixed | same path | File name; zone `America/Boise`; help and output text "in Boise". Workflows call it by this name. |
| `ingestion/scripts/Test-IngestRan.ps1` | Shared | same path | Boise only in help text. |
| `ingestion/scripts/Test-Schema.ps1` | Shared | same path | No city values. Reads `data/schema/categories.json`, `data/schema/tags.json`, `data/events.json`, `data/archive`, `sources.json` from repo paths. |
| `ingestion/scripts/Test-Sources.ps1` | Shared | same path | No city values. Defaults to `../sources.json`. |
| `ingestion/scripts/adapters/bandsintown.ps1` | Mixed | same path | Keeps only `venue.region -eq 'ID'`; help text "only Idaho dates". |
| `ingestion/scripts/adapters/cityofboise.ps1` | Mixed | same path | The whole adapter targets one Boise site: the cityofboise.org Umbraco API (`/umbraco/api/events/events`), Boise wall-clock times, "Canceled - " prefix. Adapter name contains the city. (Unsure: may belong in the Boise repo as a city-only adapter.) |
| `ingestion/scripts/adapters/eventastic.ps1` | Shared | same path | Boise area only in a help example ("such as Visit McCall"). |
| `ingestion/scripts/adapters/eventbrite-search.ps1` | Mixed | same path | Keeps only `address.region -eq 'ID'`; fallback zone `'America/Boise'` when an item has no timezone; help example URL `/d/id--emmett/`. |
| `ingestion/scripts/adapters/eventbrite.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/adapters/googlecalendar.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/adapters/ics.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/adapters/meetup.ps1` | Shared | same path | No city values. Default raw path `../../../data/raw-events.json` (see repo-layout note). |
| `ingestion/scripts/adapters/rss.ps1` | Shared | same path | Boise only in a help example ("Ford Idaho Center Arena"). |
| `ingestion/scripts/adapters/sales.ps1` | Mixed | same path | Modes for specific Boise companies: `corbett` (corbettauctions.com Elementor markup), `onthewater` (onthewaterestatesales.com UPCOMING SALES), `file` (EstateSales.NET via `data/events-additional.json`, "Town, ID"); help names Downs Auction and Downs'/Corbett's Real Estate categories. |
| `ingestion/scripts/adapters/scrape.ps1` | Mixed | same path | `calendarapp` mode for City of Boise calendar pages (boiseartsandhistory.org `#calendar-app`); CivicPlus address strip `'s+ID(s+d{5})?$'` (line 107); ChamberMaster address regex `(?:ID|Idaho)` (line 417); comments name Boise Centre (cards default markup) and staridahochamber.com. |
| `ingestion/scripts/adapters/seatgeek.ps1` | Mixed | same path | Keeps only `venue.state -eq 'ID'`; help text "Only Idaho venues". |
| `ingestion/scripts/adapters/songkick.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/adapters/ticketmaster.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/adapters/tribe.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/lib/Cities.ps1` | Mixed | same path | ZIP-to-city table (Idaho 836xx ZIPs; `83701..83799` default to Boise; Valley County ZIPs incl. New Meadows 83654, Riggins 83549); ambiguous names `Star`, `Payette`, `Emmett`, `Middleton`, `Weiser`; state pattern `(ID|Idaho)`; ZIP regex `b83[567]ddb`; reads `data/schema/place-cities.json` from a repo path. |
| `ingestion/scripts/lib/CityLookup.ps1` | Mixed | same path | Page patterns `"City, (ID|Idaho)"` and `(?:ID|Idaho)s+(83d{3})`. Skip-host list is generic. |
| `ingestion/scripts/lib/Cost.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/lib/Dedupe.ps1` | Mixed | same path | Abbreviation map `bsu = 'boise state university'`, `nnu = 'northwest nazarene university'`; placeholder-venue regex `,s*(?:id|idaho)b`; comments with Boise examples. |
| `ingestion/scripts/lib/Http.ps1` | Mixed | same path | User-Agent `WeekendBoise/1.0 (+https://github.com/rhundhausen/weekendboise)`. |
| `ingestion/scripts/lib/Ics.ps1` | Mixed | same path | Unknown-TZID warning text names `America/Boise` (the fallback zone itself is Schema.ps1's default). |
| `ingestion/scripts/lib/Links.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/lib/Raw.ps1` | Shared | same path | No city values. |
| `ingestion/scripts/lib/Report.ps1` | Mixed | same path | Zone `America/Boise` (report times, line 11; Sunday reminder test, line 315); subjects "WeekendBoise Ingest ...", "WeekendBoise Refine ...", "WeekendBoise: run the local ingest ..."; URL `github.com/rhundhausen/weekendboise/actions/workflows/refine.yml`; "your weekendboise folder"; default sender `WeekendBoise Reports <reports@weekendboise.com>`. |
| `ingestion/scripts/lib/Sales.ps1` | Mixed | same path | `Find-TvSaleTown` regex `"Town, (ID|Idaho)"`; help mentions Mountain Home and Valley County. |
| `ingestion/scripts/lib/Schema.ps1` | Mixed | same path | `Get-BoiseTimeZone` returns `America/Boise` (the default for every `ConvertTo-BoiseTime` call); `Resolve-TvCity` list of 15 cities and the Valley County town map (McCall, Cascade, Donnelly, Tamarack, Lake Fork, Yellow Pine, New Meadows, Riggins); venue-part regex `^(ID|Idaho)(s+d{5}...)?$`; reads `data/schema/tags.json`, `venue-aliases.json`, `sizes.json`, `title-case.json` from repo paths. |
| `ingestion/scripts/lib/Scrape.ps1` | Mixed | same path | robots.txt agent token `weekendboise` (Get-TvRobotsGroup). |
| `ingestion/scripts/lib/Store.ps1` | Shared | same path | No city values beyond calling `ConvertTo-BoiseTime`. |
| `ingestion/sources.json` | City | not copied | The Boise source list. |
| `ingestion/tests/adapters/Adapters.Tests.ps1` | Mixed | same path | Reads the repo `sources.json` for its source entries; Boise fixtures; asserts Idaho/ZIP behavior and cityofboise. |
| `ingestion/tests/adapters/ApiAdapters.Tests.ps1` | Mixed | same path | Asserts the `ID` region/state filters (bandsintown, seatgeek, eventbrite) and Boise ZIPs. |
| `ingestion/tests/adapters/EventbriteSearch.Tests.ps1` | Mixed | same path | Reads the `eventbrite-emmett` entry from the repo `sources.json`; asserts Garden City and the Idaho filter. |
| `ingestion/tests/adapters/Meetup.Tests.ps1` | Mixed | same path | Expects Meridian and Eagle to resolve as known cities; `addressRegion = 'ID'`. |
| `ingestion/tests/adapters/Sales.Tests.ps1` | Mixed | same path | Tests the Boise-company modes (corbett, onthewater, file with `data/events-additional.json`) and "Town, ID". |
| `ingestion/tests/adapters/Scrape.Tests.ps1` | Mixed | same path | Reads the repo `sources.json`; calendarapp mode; Boise fixtures; `User-agent: WeekendBoise` robots case. |
| `ingestion/tests/fixtures/bandsintown/example-artist.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/cityofboise/events-page-0.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/cityofboise/events-page-1.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/eventastic/visit-mccall.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/eventbrite-search/emmett.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/eventbrite-search/event-free.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/eventbrite/example-organization.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/googlecalendar/page1.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/googlecalendar/page2.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/ics/boise-state-athletics.ics` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/rss/ford-idaho-center.xml` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/bluebird-social.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/boise-arts-history.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/boise-centre.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/chambermaster-calendar.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/chambermaster-cupcake-wars-emmett-public-library-17178.ics` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/chambermaster-digital-boot-camp-17177.ics` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/chambermaster-line-dancing-11-02-2026-16727.ics` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/chambermaster-shotokan-karate-11-02-2026-16539.ics` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/civicplus.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/indian-creek-plaza-event.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/jump-boise.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/little-gym-boise-west.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/reuseum.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/star-chamber.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/scrape/visit-boise.html` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/seatgeek/example-area.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/songkick/example-metro.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/ticketmaster/ford-idaho-center-arena.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/fixtures/tribe/mike-brown-group.json` | Mixed | same path | Pages and feeds captured from Boise-area sources, used as test input. Copied unchanged. |
| `ingestion/tests/lib/Cities.Tests.ps1` | Mixed | same path | Asserts Idaho ZIPs, Treasure Valley cities, Valley County grouping. |
| `ingestion/tests/lib/CityLookup.Tests.ps1` | Mixed | same path | Asserts "City, ID" and 83xxx ZIP detection. |
| `ingestion/tests/lib/Classify.Tests.ps1` | Mixed | same path | Reads `data/schema/categories.json`, `tags.json`, `sizes.json`, `venue-aliases.json` and the repo `sources.json`. |
| `ingestion/tests/lib/Cost.Tests.ps1` | Shared | same path | Generic; Boise only in sample strings. |
| `ingestion/tests/lib/Dedupe.Tests.ps1` | Mixed | same path | Asserts the BSU/NNU aliases and "Boise, ID 83703" placeholder venues. |
| `ingestion/tests/lib/Http.Tests.ps1` | Mixed | same path | Asserts the WeekendBoise User-Agent string. |
| `ingestion/tests/lib/Ics.Tests.ps1` | Shared | same path | Generic; Boise only in sample strings (expected offsets assume Mountain time, see note). |
| `ingestion/tests/lib/Links.Tests.ps1` | Shared | same path | Generic. |
| `ingestion/tests/lib/Raw.Tests.ps1` | Shared | same path | Generic. |
| `ingestion/tests/lib/Report.Tests.ps1` | Mixed | same path | Asserts "WeekendBoise ..." subjects and the `reports@weekendboise.com` sender. |
| `ingestion/tests/lib/Schema.Tests.ps1` | Mixed | same path | Asserts `ConvertTo-BoiseTime`/`America/Boise`, the city list, Valley County, Idaho venue parsing. |
| `ingestion/tests/lib/Scrape.Tests.ps1` | Mixed | same path | Asserts the `User-agent: WeekendBoise` robots group. |
| `ingestion/tests/lib/Store.Tests.ps1` | Shared | same path | Generic. |
| `ingestion/tests/scripts/Invoke-Ingest.Tests.ps1` | Shared | same path | Generic; writes its own sources file in TestDrive. |
| `ingestion/tests/scripts/Invoke-Refine.Tests.ps1` | Shared | same path | Generic; Treasure Valley names only as sample data (Garden City used as a valid city value). |
| `ingestion/tests/scripts/Publish-Data.Tests.ps1` | Shared | same path | Generic. |
| `ingestion/tests/scripts/Save-RunLogs.Tests.ps1` | Shared | same path | Generic. |
| `ingestion/tests/scripts/Send-Report.Tests.ps1` | Mixed | same path | Asserts "WeekendBoise Ingest/Refine" subjects. |
| `ingestion/tests/scripts/Test-BoiseHour.Tests.ps1` | Mixed | same path | Tests Test-BoiseHour.ps1 against Boise daylight saving. |
| `ingestion/tests/scripts/Test-IngestRan.Tests.ps1` | Shared | same path | Generic. |
| `ingestion/tests/scripts/Test-Sources.Tests.ps1` | Mixed | same path | Validates the repo `sources.json`; accepts `calendarapp`. |
| `website/README.md` | Mixed | same path | D1 database name `weekendboise-log`; mentions the WeekendBoise user agent. |
| `website/assets/css/site.css` | Mixed | same path | Boise skyline SVG in the three `--skyline` variants (day, sunset, night); comments on Boise's sunset. |
| `website/assets/js/app.js` | Mixed | same path | `TZ = 'America/Boise'`; `dropAddress` regex `(ID|Idaho)`; search `ALIASES` (bsu, nnu, cofi); helper `boiseDay`; "last call in Idaho" 2 AM rule in a comment. |
| `website/build.sh` | Mixed | same path | `export TZ=America/Boise`. |
| `website/content/.gitkeep` | Shared | same path | Placeholder. |
| `website/content/about.md` | Mixed | same path | Front matter only; description names WeekendBoise. |
| `website/content/sources.md` | Mixed | same path | Front matter only; description names WeekendBoise. |
| `website/data/.gitkeep` | Shared | same path | Placeholder. |
| `website/data/display.json` | City | not copied | Boise display abbreviations (College of Idaho, BSU, Morrison Center, Broadway in Boise). |
| `website/hugo.toml` | City | not copied | Site title and config. |
| `website/layouts/about.html` | Mixed | same path | Site name; prose listing Treasure Valley cities; author story; "midnight Boise time"; Valley County explanation; repo and issues URLs `github.com/rhundhausen/weekendboise`. |
| `website/layouts/baseof.html` | Mixed | same path | Default meta description (Boise, Meridian, Nampa, Treasure Valley); sky-theme coordinates `LAT = 43.615, LON = -116.202`; comments on Boise's sky. |
| `website/layouts/home.html` | Mixed | same path | `America/Boise` for the as-of time; `Valley County` pinned last in the city list; footer repo URL. |
| `website/layouts/sources.html` | Mixed | same path | Label `"cityofboise" "City of Boise events API"`; "midnight Boise time"; issues URL. |
| `website/scripts/Get-VisitorLog.ps1` | Mixed | same path | D1 database `weekendboise-log`; display zone `America/Boise`. |
| `website/static/_headers` | Shared | same path | Generic cache headers. |
| `website/static/favicon.ico` | City | not copied | Branding. |
| `website/static/icons/day/apple-touch-icon.png` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/day/favicon.ico` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/day/favicon.svg` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/day/icon-192.png` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/day/icon-512.png` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/night/apple-touch-icon.png` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/night/favicon.ico` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/night/favicon.svg` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/night/icon-192.png` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/night/icon-512.png` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/sunset/apple-touch-icon.png` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/sunset/favicon.ico` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/sunset/favicon.svg` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/sunset/icon-192.png` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/icons/sunset/icon-512.png` | City | not copied | Branding (day, sunset, night icon sets). |
| `website/static/site.webmanifest` | City | not copied | Branding: name and short_name "WeekendBoise". |
| `website/worker/index.js` | Shared | same path | Generic. |
| `website/worker/package.json` | Shared | same path | Generic. |
| `website/worker/schema.js` | Shared | same path | Generic; one comment example (Sparklight). |
| `website/worker/test/worker.test.js` | Shared | same path | Generic; weekendboise.com and Boise only as sample request data. |
| `website/worker/visitor.js` | Shared | same path | Generic. |
| `website/wrangler.jsonc` | City | not copied | Worker name and D1 database id. |

## Engine rules documented in weekendboise/docs/handoff.md

Listed only, to be moved into engine docs later. handoff.md is Boise history and is not a rule
source for this repo; these are the parts of it that describe engine behavior. Each was checked
against weekendboise's `README.md`, `docs/development.md`, `docs/schema.md`, `docs/cost-tiers.md`,
`docs/github-setup.md`, `docs/sources.md`, and `website/README.md`.

### Found only in handoff.md

1. **Category chips** are built from the events in the build, and a category's chip shows only
   while it has an upcoming event. Chips sort by category id.
2. **City list** options are built at build time and list only cities with at least one upcoming
   event. This is presentation only: every running source still runs nightly, and a city returns
   once it has an event. (Also stated in Boise's `sources.json` `_comment`, a City file.)
3. **Adding a category** touches `categories.json` (order sets chip order), both schemas'
   category enums, the classification order in `lib/Schema.ps1`, `sizes.json`, `site.css`,
   `tags.json`, and the tag-count limit in the tests.
4. **Silent bot blocks.** The scrape `jsonld` mode warns "no event links on the list page" when a
   list page with an `eventLinkPattern` matches nothing, so a block served with HTTP 200 shows as a
   warning in the report, not as a quiet 0-event success.
5. **City lookup ignores page `<nav>` and `<header>`**, where site menus name a city on every page.
   (development.md says only that the lookup never reads the whole page.)
6. **User-Agent product token stays stable**, so site owners' robots.txt rules keep matching it.
   Only the contact URL after it may change.
7. **Multi-day sales** are one event from the first day's opening to the last day's close, and pass
   `PriceMin 0` so item prices in a listing never set the cost tier.
8. **CivicPlus reading** keeps a source url's query string on every month's page, so a category
   filter (`CID=`) applies to all months.
9. **`Invoke-TvRequest` supports `-Method Post -Form`** (used by the `eventastic` adapter, one
   POST per night).

### In handoff.md and only in a Boise doc

These are written down outside handoff.md, but only in `docs/sources.md` (City), so they still
need an engine home.

10. **Sales rules:** in-person only ("online" anywhere in the title or text, or no place, drops an
    event); only cities the site covers; real estate auctions dropped (a feed's Real Estate
    category or "real estate" in a title); only title, company, city, times, and link stored; no
    link on a listing page is followed (third-party bidding sites such as HiBid are never fetched).
11. **`doNotIngest`**: a top-level list in `sources.json`; a source on it is never run, even by
    name. Also the status lifecycle (`running`, `ready`, `investigating`, `awaiting-reply`,
    `needs-contact`, `declined`, `blocked-by-terms`, `online-only`, `defunct`, `out-of-scope`,
    `ruled-out`) and the fields `type`, `contact`, `outreach`, `lastChecked`, `optOut`.
12. **`localTimeAsUtc`**: tribe and ics honor it for Events Calendar sites set to UTC that list local times.
13. **`excludeTitlePattern`** is honored by tribe; **`yearFromTitle`** is a scrape cards option.
14. **Meetup descriptions** have Markdown stripped.
15. **`sveltekit` scrape mode** parses page data with `ConvertFrom-TvJsLiteral` without running
    any script.

### Already in a doc copied here as Mixed

Your examples are here: they are already written in docs this repo now has, though in
Boise-flavored form, and handoff.md only repeats them. They move with those docs when the docs are
made generic.

- **No stored prices:** adapters compute `priceMin`, `New-TvEvent` derives `costTier` (breakpoints
  $15 and $40 in `lib/Cost.ps1`) and removes any sentence with a price; no guessed tiers.
  (`docs/schema.md`, `docs/cost-tiers.md`)
- **Link check HTTP codes:** 404 and 410 break a link the first night; timeouts, 500, 502, 503,
  504, DNS failures, and refused connections only on two nights in a row; every other 4xx and 5xx
  (TicketWeb's 506 and 530) and odd codes never break one. (`docs/development.md`, Link check)
- **Which workflow owns which file:** ingest writes only `data/raw-events.json`; refine writes
  `data/events.json`, `data/archive/`, `data/links.json`, `data/city-lookup.json`, and
  `data/meta.json`; no file is written by both, and `data/schema/` is hand-edited and committed by
  neither. (`docs/development.md`, File ownership and Nightly workflows)
- **`local: true` sources:** skipped by the nightly ingest with their last fetch kept, run from a
  home connection with `Invoke-LocalIngest.ps1`, whose push starts refine; the scheduled Sunday
  ingest emails a reminder. (`docs/development.md`, Local sources)
- **Ingest and refine split:** a failed source keeps its last entry; a one-source run replaces only
  that entry and keeps `asOf`; only ingest gets source API keys; refine runs whether ingest
  succeeded or failed and fails clearly without a raw file; report jobs run even when the main job
  failed; both share the concurrency group `data`. (`docs/development.md`)
- **Same-day showings:** the id hashes the date, not the time, so two showings of one title at one
  venue on one day merge. (`docs/schema.md`)

## Unsure how to classify

- `ingestion/.env.example.ps1`: you listed .env files as City. This is the template that names the
  API-key environment variables the engine's adapters read, with placeholder values and no city
  content, so it is Shared and was copied. The real `.env.ps1` was not copied.
- `ingestion/scripts/adapters/cityofboise.ps1` (and its tests and fixtures): Mixed as you
  suggested, and copied, but it serves exactly one Boise site. It may belong in the Boise repo as a
  city-only adapter rather than in the engine. The same question applies to the sales modes
  `corbett`, `onthewater`, and `file` and the scrape mode `calendarapp`.
- `docs/development.md`, `docs/schema.md`, `docs/cost-tiers.md`, `docs/github-setup.md`: engine
  reference docs full of Boise detail, so Mixed and copied. `github-setup.md` is the most
  Boise-bound (repo history, domain, sender) and could be City instead.
- `docs/superpowers/` (a plan and a spec for Boise's Emmett sources): City, as Boise feature
  history.
- `website/content/about.md` and `sources.md`: front matter only, but the layouts need the pages
  to exist. Mixed rather than City.
- `website/worker/test/worker.test.js` and several ingestion tests use Boise names only as sample
  data, so they are Shared. Tests that read city files or assert Boise behavior are Mixed.
- `ingestion/tests/fixtures/`: all Mixed, as pages and feeds captured from Boise sources that the
  engine's tests need.
- `data/schema/` tables: see the cross-cutting note above.
- `docs/development.md` says `ingest-additional.yml` runs at 09:00 UTC, but the workflow's crons
  are 05:30 and 06:30 UTC (23:30 Boise). One of them is out of date.
