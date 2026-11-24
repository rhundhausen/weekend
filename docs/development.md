# Development

This page is for working on the core or on a city that uses it. If you run a site and found
this through a Weekend bot's User-Agent, see that city repo's README instead (the User-Agent
links to it).

## Core and city repos

This repo holds all shared code: the adapters (including ones written for a single platform), the
ingest and refine scripts, the schemas and vocabulary, the tests, the Hugo theme, and the reusable
workflows. A city repo holds only its own facts and data:

```
city.json                    the city's facts (format: ingestion/schema/city.schema.json)
ingestion/sources.json       the city's sources (format: sources.md)
data/                        events, archive, links, meta, written by the workflows
data/schema/                 the city's lookup tables: venue-aliases, place-cities, sizes, and
                             any additions to the core's categories, tags, or title case
website/wrangler.jsonc       Cloudflare Worker name, D1 binding, build command
website/static/              favicons and web manifest
website/data/display.json    display names
website/assets/css/skyline.css   optional: the city's skyline
.github/workflows/           thin callers: ingest.yml, refine.yml, test.yml
README.md                    the page the bot's User-Agent points site owners to
```

A city never copies a core file to change it. What a city varies is a field in `city.json`, an
entry in its `sources.json` or `data/schema/`, or a website file at the same path as the theme's.
Cities track this repo's `main`, with no version pinning: a core push reaches a city at its
next workflow run or site build.

Values the core derives from `city.json` (`ingestion/scripts/lib/City.ps1`): the User-Agent
`<siteName>/1.0 (+https://github.com/<repo>)`, the robots.txt token (the site name in lowercase), the data
commit identity "`<siteName>` bot", and the report sender `<siteName> Reports <reports@<domain>>`.

## How it works

1. The city's `ingestion/sources.json` lists each source and the adapter that reads it (ICS feed,
   Meetup group feed, The Events Calendar REST API, RSS, a ticketing API, or, for sites with no
   feed, a `robots.txt`-respecting page reader).
2. **Ingest** (`ingestion/scripts/Invoke-Ingest.ps1`, at midnight in the city's time zone) runs
   every adapter, normalizes each event to the common schema, and stores what each source returned
   in `data/raw-events.json`, one entry per source. It does nothing else.
3. **Refine** (`ingestion/scripts/Invoke-Refine.ps1`, started when ingest finishes, even if ingest
   failed) reads the raw file, dedupes across sources, fills in cities, moves old cost fields to
   `costTier`, looks up the city of events still stored as Other by reading their pages, finds
   where each venue is for the map, checks event links, and writes `data/events.json` (upcoming
   only), `data/archive/YYYY-MM.json` (past events), `data/links.json`, `data/city-lookup.json`,
   `data/venue-locations.json`, and `data/meta.json`. It never fetches a source, so it can be rerun
   by hand as often as needed.
4. Each workflow commits only the files it owns. Refine's commit deploys the site.

**File ownership.** No file is written by both stages:

| File | Written by |
| --- | --- |
| `data/raw-events.json` | ingest |
| `data/events.json`, `data/archive/`, `data/links.json`, `data/city-lookup.json`, `data/venue-locations.json`, `data/meta.json` | refine |
| `data/schema/` | people, by hand |

The raw file holds `asOf` (the scheduled midnight, or the time a manual run started) and, per
source, its last good fetch: `{ "asOf": "...", "sources": { "<name>": { "fetchedAt": "...",
"events": [...] } } }`. A source that fails keeps its last good entry, and a one-source run
replaces only that source's entry and keeps `asOf`, so refine always sees every source. Refine
copies `asOf` into `data/meta.json` as `lastIngest`, which is what the site's header shows. Events
in the raw file are already normalized by the adapters (id, category, tags, size, `costTier` from
the price the source gave, and a description with prices removed), because prices must never be
stored; refine does everything after. Cost tier rules: [cost-tiers.md](cost-tiers.md). Event
fields: [schema.md](schema.md).

## Running locally

Requires PowerShell 7.4 or later and Pester 6.0.0. The core's tests run from this repo and need
no city repo (they use the fixture city in `ingestion/tests/fixtures/city`):

```powershell
Invoke-Pester -Path ./ingestion/tests
```

Everything else runs from a city repo, with this repo checked out beside it (`../weekend`). A
script finds the city from `-CityRoot`, else `$env:WEEKEND_CITY_ROOT`, else the nearest folder at
or above the current directory that holds a `city.json`.

```powershell
../weekend/ingestion/scripts/Test-Sources.ps1                     # validate sources.json
../weekend/ingestion/scripts/Test-Schema.ps1                      # validate stored events
../weekend/ingestion/scripts/Invoke-Ingest.ps1 -NoWrite           # fetch and report, don't write the raw file
../weekend/ingestion/scripts/Invoke-Ingest.ps1                    # fetch every source into data/raw-events.json
../weekend/ingestion/scripts/Invoke-Ingest.ps1 -Source <name>     # one source, merged into the raw file
../weekend/ingestion/scripts/Invoke-LocalIngest.ps1               # the local sources only, then commit and push (weekly)
../weekend/ingestion/scripts/Invoke-Refine.ps1 -SkipLinkCheck -SkipCityLookup   # raw file to the site's files, no network at all
../weekend/ingestion/scripts/Invoke-Refine.ps1                    # the same, with the city lookup and link check
../weekend/ingestion/scripts/Invoke-Refine.ps1 -NoWrite           # see refine's counts, write nothing
```

To build or preview the site, see [website/README.md](../website/README.md).

API keys come from environment variables only: set them in the shell before running ingest. The
core's `ingestion/.env.example.ps1` lists them; a copy at the city repo's `ingestion/.env.ps1`
(gitignored, never committed) can be dot-sourced to set them. Sources
whose key is missing fail with a warning and the rest still run. Only ingest needs source keys;
refine uses none, and both use the Resend key only to email their report. Raw per-source output
and `run.json` (ingest) and `refine.json` and `links.json` (refine) go to `out/`, which a city repo
gitignores.

Refine drops events any source titles as canceled, and dedupes across sources (see
`Merge-WkEvents` in `ingestion/scripts/lib/Dedupe.ps1`). It re-cleans every archive month with the
same rules, so rerunning it applies a rule change everywhere without fetching anything; add
`-NoWrite` to see the counts first. Both scripts take `-InputPath`/`-OutputPath` (refine) or
`-RawPath` (ingest) to work on copies outside `data/`.

### City lookup

Some events reach refine with the city Other, mostly from aggregator listings with no venue. After
the text-based fill-in, refine reads their pages to find the city
(`ingestion/scripts/lib/CityLookup.ps1`).

- **How:** it reads the event page and uses its venue block or schema.org location if it has one,
  never the whole page, and never the page's `<nav>` or `<header>`, where site menus name a city on
  every page. Otherwise it follows the page's "Website" link to the organizer's page, then that
  site's home page. It takes a city only when the page names exactly one of the city's cities, as
  "City, ST", "City, State", or a ZIP code after the state (`state` in `city.json`); a page that
  names two leaves the event as Other.
- **What it skips:** social networks and chain stores (Facebook, Instagram, Home Depot, and others
  in `$script:WkCityLookupSkipHosts`) are never requested, because their pages can't say which
  store or place.
- **Politeness:** the same rules as the link check: robots.txt first, a disallowed page is never
  requested, 1 second between requests to a host or its Crawl-delay, and at most
  `-CityBudgetSeconds` (default 180) per run.
- **Memory:** results go in `data/city-lookup.json` by event page, with the organizer link and the
  time checked. A found city is reused for 30 days and a miss is retried after 7, so most nights
  need few requests.
- **Skipping it:** `-SkipCityLookup`, or the "Skip the city lookup" box on a manual refine run,
  makes no requests but still applies the cities already found.

### Venue locations

Refine keeps where each venue is in `data/venue-locations.json`, for the site's map
(`Update-WkVenueLocations` in `ingestion/scripts/lib/VenueLocations.ps1`; the file is described in
[schema.md](schema.md), "Venue locations").

- **Order:** the coordinates a source sent with the event come first and are trusted. Ticketmaster,
  Eventbrite, Meetup, tribe, and eventastic send them or an address (`New-WkEvent -Latitude
  -Longitude -Address`); they ride on the raw events only. Next, OpenStreetMap's Nominatim search,
  by the source's address or by "venue, town, state", and only an answer within 150 miles of the
  city counts. Last, the center of the address's ZIP code. The site puts any other event at its
  town's center (`cityCenters` in `city.json`).
- **Placeholders:** a venue that isn't one place is never looked up: a `various-` or `-area` key, or
  a venue whose events are in more than one town, such as an auction company. Each of its events
  goes to its own town's center, so estate sales never point at a home. A point a source sent
  wins over the town rule, since sources disagree about towns more than about points, and a venue
  whose events settle in one town again is looked up.
- **Street addresses:** a venue named only by a street address ("7497 W Whisper Rdg Dr") is most
  often a home, so it is a placeholder too, even when a source sent its point, and its address is
  not kept.
- **Politeness:** 1 second between Nominatim requests, the bot's User-Agent, at most
  `-VenueLookups` (default 200) requests and `-VenueBudgetSeconds` (default 300) per run, and a
  stop after three failed requests in a row, so a first fill may take two nights and a slow
  service never costs the night's refine. A venue not found is tried again after 30 days; a found
  one is kept. An answer that is a whole town, county, or ZIP code doesn't count, so "Downtown
  Boise" isn't placed as if it were one spot.
- **Skipping it:** `-SkipVenueLookup` makes no requests but still records what sources sent.

### Link check

After the merge, refine checks the event links that are due (`ingestion/scripts/lib/Links.ps1`),
so nobody clicks through to a page that's gone.

- **What breaks a link:** 404 and 410 break it the first night. Timeouts, 500, 502, 503, 504, a
  host that doesn't resolve, and refused connections break it only on 2 nights in a row. Every
  other 4xx (401, 403, 406, 429 and so on), every other 5xx (TicketWeb answers scripts with 506 or
  530 while the page works in a browser), odd codes like 999, and errors that can't be placed
  never do, because they're a site turning away scripts (Ticketmaster answers 401), not a missing
  page. A host that is down is caught even though its robots.txt request fails first. Redirects
  are followed the way a browser follows them, including from https to http.
- **When links are checked:** a link is checked the first night it appears, again 7 days after it
  last worked, and every night while it's failing, so a page that comes back gets its link back.
  Soonest events go first, within `-LinkBudgetSeconds` (default 900). Links left over count as
  working until a later night reaches them.
- **Politeness:** requests use the city's User-Agent and follow each host's robots.txt; a
  disallowed path is never requested. Requests to one host are at least 1 second apart, or the
  host's Crawl-delay.
- **What a visitor sees:** an event whose link is broken first tries its other sources' links that
  are known to work. If none does, it gets `linkBroken: true`, and the site shows the title as
  plain text with the hover text "Information not available".
- **Where to look:** each refine lists every link it checked in `out/links.json` and adds counts to
  `out/refine.json`. The refine run's GitHub Actions summary has a "Broken links" section grouped
  by source, new breaks first. The state is `data/links.json`, committed by refine.
- **Limits:** `-NoWrite` and `-SkipLinkCheck` make no link requests but still apply what
  `data/links.json` already knows.

## Nightly workflows

The work is in this repo's reusable workflows, `.github/workflows/ingest.yml` and `refine.yml`
(`on: workflow_call`). Each checks out the calling city repo and this repo (into `.core/`). A
city's own `ingest.yml` holds only the cron lines and passes its secrets with `secrets: inherit`;
its `refine.yml` holds only the triggers; its `test.yml` calls `city-test.yml`, which validates the
city's files against the core's schemas and builds the site. This repo's own `test.yml` runs the
Pester tests and the Worker's tests on every push and pull request.

- **When:** a city's ingest runs at midnight in its time zone. Cron is UTC and daylight saving
  moves the offset, so the caller schedules both candidate UTC hours and the core's first job,
  `Test-LocalHour.ps1`, skips the one that isn't midnight in the city that day. Refine has no
  cron: it starts with `workflow_run` each time the scheduled ingest run on `main` completes,
  **whether ingest succeeded or failed**, so past events still move to the archive and
  links still get checked when every source is down. Its first job, `Test-IngestRan.ps1`, reads the
  ingest run's jobs through the GitHub API and skips the run whose ingest job was skipped, so
  refine runs once a night. Both share the concurrency group `data`, so a manual refine waits for a
  running ingest rather than racing it.
- **The header time:** GitHub often starts scheduled runs late, so a scheduled ingest passes
  `-AsOf` with the scheduled midnight and the site's header reads 12:00 AM; a manual full ingest
  records the time it ran, and a one-source ingest keeps the time already there. Refine copies it
  unchanged.
- **Ingest** fetches, uploads `out/` as the `out` artifact, then `Publish-Data.ps1` commits
  `data/raw-events.json` alone, with `[skip ci]` so Cloudflare doesn't deploy a commit the site
  doesn't read. Run it by hand from the city repo's Actions > ingest > Run workflow, with an
  optional `source` input to fetch one source. A manual ingest does not start refine, so run
  refine by hand after it when the site should pick up its events.
- **Refine** checks out the head of `main`, so it sees the raw file ingest just committed, logs the
  raw file's `asOf` and source count, and fails with a clear message if there is no raw file. It
  uploads `out/` as the `refine-out` artifact, then commits `data/events.json`, `data/archive/`,
  `data/links.json`, `data/city-lookup.json`, `data/venue-locations.json`, and `data/meta.json`
  without `[skip ci]`, which
  deploys the site. **To rerun it by hand** (after changing a merge or city rule): Actions > refine
  > Run workflow, optionally ticking "Skip the link check" or "Skip the city lookup". No source is
  fetched.
- **Commits** are made as the city's bot and pushed to the branch the run started on. If someone
  pushed during the run (refine takes 15 minutes or more), the push is rejected as out of date;
  `Publish-Data.ps1` then replays its commit on top of the new branch head and pushes again, up to
  3 tries. That is safe because each workflow commits only its own data files. If someone changed
  those same files, it stops with a clear error instead of overwriting them. The test workflow
  doesn't run on those commits, because GitHub never starts workflows from a push made with the
  workflow's `GITHUB_TOKEN`.
- **Deploying:** Cloudflare Workers Builds is connected to each city repo, with `website/` as its
  root. The city's `wrangler.jsonc` build command clones this repo's `main` and runs
  `website/build.sh`, and the build output in `website/public` is deployed. Every push to the city's
  `main` deploys, including refine's data commit. A core push that changes `website/`,
  `hugo.toml`, or `ingestion/vocabulary/` runs the core's deploy-sites workflow, which uses
  Cloudflare's API to start a build of `main` for every Worker connected to a city repo, so every
  site rebuilds with it a few minutes later (Actions > deploy-sites > Run workflow does the same by
  hand). A new city's Worker is found by itself once it is connected to its repo. Other core
  changes reach the site at the city's next build. Cloudflare skips any commit whose message contains `[skip ci]`, so leave it out of
  commits that should reach the site.
- **Local sources:** some sites turn away or time out on GitHub's servers (which run in Azure) but
  load from a home connection. Their entries in `sources.json` have `local: true`. The nightly
  ingest skips them and keeps their last fetch in the raw file, so their events stay on the site.
  `Invoke-LocalIngest.ps1`, run from the city repo on a PC about once a week, pulls, runs
  `Invoke-Ingest.ps1 -Local` (only those sources; the raw file's `asOf` is kept), commits
  `data/raw-events.json`, pushes, and starts refine by hand with `gh workflow run` (no workflow
  starts on a push; without `gh`, the events wait for the next nightly refine). The commit has no
  `[skip ci]`, so the city's test workflow checks it. The nightly email after the
  scheduled ingest at midnight Sunday includes a reminder listing each local source's last fetch
  and the command to run.
- **Report emails:** each workflow ends with a `report` job that runs after the main job, even when
  it failed. It is a separate job because GitHub serves a job's log only once that job has
  finished. It downloads the main job's artifact, saves the finished jobs' logs with
  `Save-RunLogs.ps1` (needs `actions: read`), and `Send-Report.ps1` builds a summary and sends it
  with the Resend API to `REPORT_EMAIL`.
  - **One email a night:** after the scheduled midnight ingest, ingest's `report` job doesn't run.
    The refine that follows it downloads that ingest run's `out` artifact and saves its job logs
    too, and sends one "Nightly" email (`Send-Report.ps1 -Kind nightly`) with every section of
    both reports, titled "Ingest: ..." and "Refine: ...", the two run summaries first. On Sunday
    it also carries the local ingest reminder. A manual ingest or a manual refine emails its own
    report as below.
  - **Ingest's email:** start, finish, and duration; sources that failed, with their page and
    error (such as `HTTP 405`); warnings; events per source, most first; the sources not running
    yet (ready, investigating, ideas); and the ruled-out sources with the reason for each.
  - **Refine's email:** the same basics, the raw file totals, upcoming and archived counts, cities
    filled in, link check counts, broken links grouped by source (new ones marked), and events by
    category and source.
  - **Attachments:** each email attaches the run's `out/` folder and the logs of the run's finished
    jobs as zips; the nightly email attaches both runs' (`out.zip`, `ingest-logs.zip`,
    `refine-out.zip`, `refine-logs.zip`). Together they stay under 28 MB; a zip that doesn't fit is left off and the email
    says so.
  - **Resend:** the city's domain must be verified in Resend, and `RESEND_API_KEY` must be allowed
    to send from it: a key scoped to that domain, or one for all domains. A key scoped to another
    city's domain fails with HTTP 403, "This API key is not authorized to send emails from ...".
    The emails come from the city's `reportFrom`, with `reply_to` set to `REPORT_EMAIL`, so a reply
    reaches a person rather than the unmonitored reports@ address. A failed send fails the step.
  - **Previewing locally:** `../weekend/ingestion/scripts/Send-Report.ps1 -Kind ingest -PreviewPath
    ./out/report` writes `out/report.txt` and `.html`, and sends nothing unless both secrets are
    set as environment variables. `-Kind nightly` previews the combined email from `ingest-out/`
    (ingest's `out/`) and `out/` (refine's). `Send-LocalReminder.ps1 -Force -PreviewPath
    ./out/reminder` previews the reminder on its own; no workflow sends it separately any more.

Each city repo needs these secrets (Settings > Secrets and variables > Actions). An unset secret
reaches the scripts as empty. Only the ingest step gets the API keys; both workflows' email steps
get `RESEND_API_KEY` and `REPORT_EMAIL`, which is kept as a secret so the address stays out of the
public repo.

| Secret | Used by |
| --- | --- |
| `TICKETMASTER_KEY` | Ticketmaster |
| `GOOGLE_CALENDAR_API_KEY` | Google Calendar sources: a Google Cloud API key with the Calendar API enabled, restricted to that API |
| `BANDSINTOWN_APP_ID` | Bandsintown (needs an approved app id) |
| `EVENTBRITE_TOKEN` | Eventbrite (disabled) |
| `SEATGEEK_CLIENT_ID` | SeatGeek (disabled) |
| `SONGKICK_API_KEY` | Songkick (disabled) |
| `RESEND_API_KEY` | The report emails, both workflows |
| `REPORT_EMAIL` | Where the report emails go, both workflows |

Setting up a new city: [github-setup.md](github-setup.md).

## Changing things

- **Adding a source:** add an entry to the city's `ingestion/sources.json`. An idea needs only a
  `displayName`; a source ingest runs needs a `name`, its adapter's fields, and `status: running`.
  If an existing adapter fits (most WordPress event calendars and ICS feeds do), that's all. See
  [sources.md](sources.md) for each adapter's fields and how to find a feed. Otherwise add a script
  under `ingestion/scripts/adapters/` here that emits events in the [common schema](schema.md),
  plus a fixture under `ingestion/tests/fixtures/`. Prefer official APIs and published feeds over
  page reading.
- **Adding a category** touches `ingestion/vocabulary/categories.json` (its order sets the chip
  order), the category enums in both schemas, the classification order in `lib/Schema.ps1`,
  `site.css`, `tags.json`, the tag-count limit in the tests, and each city's `sizes.json`.
- **The site's lists:** the category chips and the city list are built from the events in each
  build, so a category or city shows only while it has an upcoming event. Every running source
  still runs nightly, and a city returns once it has an event.
- **The User-Agent's product token stays stable** (the city's site name), so site owners' robots.txt
  rules keep matching it. Only the contact URL after it may change.
- **Silent bot blocks:** the scrape `jsonld` mode warns "no event links on the list page" when a
  list page with an `eventLinkPattern` matches nothing, so a block served with HTTP 200 shows as a
  warning in the report, not as a quiet 0-event success.

## Status

Ingestion, the nightly workflows, the report emails, and the website are built and run for every
city.

## Built with

Designed and built with [Claude Code](https://claude.com/claude-code) and
[Claude](https://claude.ai). The source list, architecture, and adapters were developed
collaboratively; mistakes are mine.

## License

[Unlicense](../LICENSE). Event data belongs to the venues and organizers who publish it.
