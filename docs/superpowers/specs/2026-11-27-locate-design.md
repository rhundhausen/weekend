# Locate: a weekly job that finds venue addresses

## Intent

The map puts each event at its venue when it knows where the venue is, and at its town's center
otherwise. Today refine guesses venues' places by searching OpenStreetMap (Nominatim) for
"venue, town, state". The owner doesn't trust name searches ("some map api that may or may not be
accurate") and wants addresses that the event's own web page states, found by plain rules in
PowerShell, with no AI calls. The work moves out of refine into its own workflow, `locate`, so
refine stays short and the address hunt can take its time.

## Goals

- A new reusable workflow, `locate`, in the core, and a small trigger file in each city repo. It
  runs weekly and by hand (Actions > locate > Run workflow, or `gh workflow run locate`).
- For each venue without a known place, find a street address in this order and turn it into a
  point:
  1. A manual entry (never changed).
  2. The address on the event's own page: schema.org JSON-LD (`Event.location` as a `Place` with a
     `PostalAddress`, or a `Place` alone), then schema.org microdata (`itemprop="streetAddress"`
     and its siblings), then a US street address written in the page's text next to the venue's
     name.
  3. The address the source sent in its feed (raw event `location.address`) with no point.
  4. The center of that address's ZIP code.
  5. Otherwise nothing: the site keeps the event at its town's center.
- An address becomes a point through the US Census Bureau geocoder (free, no key, official street
  records). If Census finds no match, Nominatim's structured address search (street, city, state,
  ZIP; never a name) is tried before the ZIP center.
- Refine no longer makes any lookup requests. It still records the points sources send (`feed`)
  and marks venues that aren't one place (`placeholder`), since both need no network.

## Non-goals

- Searching by venue name, anywhere (Nominatim, Overpass, Google, or anything else). A venue whose
  address can't be found stays at its town's center until the owner adds it by hand.
- Google: its search results can't be scraped under its terms, and its geocoding and places data
  may not be shown on a non-Google map, which this site's OpenStreetMap map is.
- Reading a venue's own website (the site isn't known from the event data), or any page other than
  the events' own `url`.
- A nightly run. Weekly is the decision; changing the schedule is a one-line edit later.

## Anti-goals (a failure even if it works)

- A pin at a wrong place stated with confidence. An address taken from a page must be the event's
  venue, not the organizer's office in the page footer; when that can't be told, take nothing.
- Ignoring robots.txt, or fetching faster than ingest does. Pages are fetched with the same
  User-Agent and robots check as ingest (`Test-WkRobotsAllowed`), at least 1 second apart per host.
- Writing a home's address: the street-address placeholder rule stays (a venue named only by a
  street address is kept at its town's center and no address is saved).
- Overwriting a `manual` entry, ever.

## Constraints found in the code

- `ingestion/scripts/lib/VenueLocations.ps1` holds `Update-WkVenueLocations`, which today does feed
  points, placeholders, and the Nominatim and ZIP lookups in one pass, with `-MaxLookups`,
  `-BudgetSeconds`, a stop after 3 failures, and a `-Fetch` script block for tests.
- `data/venue-locations.json` (city repo) entries: `lat`, `lon`, `address`, `from`, `checked`.
  `from` is `feed`, `lookup`, `zip`, `manual`, `none`, or `placeholder`. Schema:
  `ingestion/schema/venue-locations.schema.json` (requires lat and lon for feed, lookup, zip,
  manual).
- `website/layouts/_partials/grid.html` gives an event `l: [lat, lon, exact]` from that file when
  `from` is one of feed, lookup, manual, zip (exact 0 only for zip).
- `ingestion/scripts/lib/Scrape.ps1` has `Get-WkRobotsGroup`, `Test-WkRobotsAllowed`, and
  `Get-WkJsonLdEvent` (handles one object, arrays, and `@graph`). `Http.ps1` has
  `Invoke-WkRequest` with the bot's User-Agent.
- Workflows: the core holds reusable `ingest.yml` and `refine.yml`; each city repo's own
  `ingest.yml` and `refine.yml` hold only triggers and secrets and call them. Both use
  `concurrency: group: data, cancel-in-progress: false`, so data writers never overlap. A push to a
  city repo's main rebuilds that city's site.
- `data/events.json` (refined, committed) has each event's `venue`, `venueKey`, `city`, and `url`.
  `data/raw-events.json` (committed) has each source's raw events with `location`.
- Many venues come from Google Calendar feeds whose `url` is a google.com calendar link (the Ada
  library branches); those pages carry no address, so those venues will mostly need manual
  entries.

## Approaches considered

- **A. Weekly job owns every lookup (chosen).** Refine keeps only network-free work; `locate` runs
  Sundays and by hand with a generous budget. A new venue waits up to a week at its town center.
- **B. Nightly quick pass plus weekly deep pass.** New venues placed the next morning, at the cost
  of two schedules and two budgets in one job. Not chosen: the owner picked weekly.
- **C. Keep a small name lookup in refine for new venues.** Dropped: it is the name search the
  owner asked to remove.

## Design

### Refine

- `Update-WkVenueLocations` loses its lookups. It keeps: manual untouched; feed points (most
  reported, ties to first); placeholder marking (named `various-`/`-area`, street-address names,
  multi-town venues without a feed point). Adding a `{ from = 'none', checked }` entry is not its
  job any more. A venue refine doesn't place is left without an entry (or with the entry it had)
  for `locate` to handle.
- (Builder's call, from the builder check) A feed point wins over a `page` or `address` entry:
  the owner's rule is that a source's own location is taken as correct. Refine never touches
  `page`, `address`, `zip`, `none`, or `lookup` entries otherwise.
- (Builder's call) A `placeholder` entry whose venue is no longer a placeholder is removed by
  refine, so `locate` sees the venue as new and works on it.
- Remove `-SkipVenueLookup`, `-VenueLookups`, `-VenueBudgetSeconds`, and the Nominatim request
  code from refine. refine.json's `venueLookup` block becomes `venueLocations` with the feed count.

### Locate script

`ingestion/scripts/Invoke-Locate.ps1`, run from the city repo like the others. Parameters include
`-BudgetMinutes` (default 45), `-MaxPagesPerVenue` (default 3), `-NoWrite`, `-OutDir`, `-Now`, and
a `-Fetch` script block for tests.

1. Read `data/events.json`, `data/raw-events.json`, and `data/venue-locations.json`.
2. Which venues to work on, busiest first (most upcoming events): every venue in events.json whose
   entry is missing, `none`, `zip`, or `lookup` (see "Existing lookup entries"), and isn't
   `manual`, `feed`, or `placeholder`. `page` and `address` entries (below) are rechecked only
   when their `checked` date is 90 days old or more.
3. For each venue, the candidate pages are the distinct `url`s of its upcoming events, at most
   `MaxPagesPerVenue`, skipping hosts whose robots.txt disallows the path and hosts known to carry
   no addresses (google.com calendar links).
4. From each page, the first address found by: JSON-LD, then microdata, then the text rule. Every
   method must tie the address to this venue (builder's call, from the builder check), because
   listing pages carry many events and footers carry the organizer's address:
   - JSON-LD and microdata: take a `Place`'s address only when the place's name matches the
     venue, or when the `Event` that holds it has a name matching the event's title.
   - Text rule: a US street address (house number, street, optional unit, town, state, ZIP) only
     when the venue's name appears within 200 characters before it in the page text.
   - "Matches" means equal after normalizing both sides: lowercase, accents and punctuation
     removed, a leading "the" dropped, spaces collapsed; or one side's words all appear in the
     other's, with at least two words. So "Eagle Chamber of Commerce" matches "Eagle Chamber of
     Commerce Office" but "Eagle" alone matches nothing.
   An address on two pages that disagree: take the one most pages give, ties to the first page.
5. With no page address, use the source's feed address (raw `location.address`) if any.
6. Geocode the address: Census one-line address geocoder first; with no match, Nominatim's
   structured address search; with no match, the ZIP center. Any point must pass
   `Test-WkNearCity` (150 miles).
7. (Builder's call) On a recheck of a `page` or `address` entry, a different address found
   replaces it; finding nothing keeps the old entry and only updates `checked`, so pins don't
   vanish when old event pages go away.
8. Write the entry: `from = 'page'` (address from a page), `'address'` (from the feed address),
   `'zip'`, or `'none'`, with `address` and `checked`.
9. Stop when the time budget is spent. (Builder's call) A failure is a timeout, a connection
   error, or a 5xx answer; a 404 or a page with no address is not a failure. After 3 failures in a
   row, that service (Census, Nominatim) or that page host is skipped for the rest of the run and
   the run goes on to the next step; it is reported in the summary. Requests to any one host are
   at least 1 second apart.
10. Write `data/venue-locations.json` (sorted, LF, as now) and a summary `out/locate.json`: venues
   tried, pages read, robots skips, addresses found by method, geocoder answers by service, and
   duration.

### Existing lookup entries

The 135 Boise and 37 Boulder entries with `from = 'lookup'` came from the name search.
The owner's decision: keep them on the map until `locate` finds a page or feed address to
replace them. `locate` works on them first among equals (they are in its queue from the first
run), and a page or feed address found replaces the entry. Finding nothing keeps the `lookup`
entry. No new `lookup` entries are ever written.

### Workflow

- Core: `.github/workflows/locate.yml`, `on: workflow_call`, checks out the core into `.core/` as
  refine does, runs `Invoke-Locate.ps1`, validates the file (`Test-WkVenueLocationFile`), and
  commits only `data/venue-locations.json` with the bot identity ("data: locate YYYY-MM-DD"),
  pushing with the same rebase-and-retry as refine. The commit rebuilds the site.
- Each city repo: `.github/workflows/locate.yml` with `schedule` (Sundays, 10:00 UTC, which is
  the early morning in both cities) and `workflow_dispatch`, and `concurrency: group: data`.
- Job timeout 60 minutes.

### Schema, site, docs

- `venue-locations.schema.json`: add `page` and `address` to `from`, both requiring lat and lon.
- `grid.html`: treat `page` and `address` as exact (1). `lookup` stays exact while it exists.
- About page: the map section says locations come from the event's page or the source, never a
  name search.
- docs/development.md "Venue locations" and docs/schema.md updated; docs/github-setup.md lists the
  new city workflow file.

## Left to the builder

- The exact Census endpoint parameters (benchmark) and the Nominatim structured-query fields.
- The street-address text pattern (street types, unit forms) and how page text is extracted from
  HTML.
- The list of hosts known to carry no addresses, beyond google.com calendar links.
- The names of new helper functions and how the existing lookup code is split between refine and
  locate.
