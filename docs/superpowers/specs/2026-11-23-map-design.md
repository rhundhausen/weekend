# Map view

Status: draft, 2026-11-23, reviewed once.

## Intent

The site's List/Map toggle exists, but Map only shows "Map view is coming soon." A visitor should
be able to switch to a real map of the events the list is showing, find what is near them, and
move around it the way any phone or desktop map works: drag to pan, pinch or scroll to zoom.

The owner's words: put items on the map as far as a best guess goes, based on city or ZIP code;
ask the visitor to share their location and open the map where they are, showing nearby events;
and get ingestion or refine to collect real addresses, not just cities.

## Goals

- Map shows every event that matches the current filters (search, dates, category, city, price,
  and the rest), not just the current page of 25.
- Pan and zoom by touch (drag, pinch, double-tap) and by mouse (drag, wheel, double-click, the
  + and - buttons).
- On first opening Map, the browser asks for the visitor's location. With a yes, the map centers
  on them at neighborhood zoom with a "you are here" dot. With a no, or no answer, or an error,
  it fits all the events shown.
- Each event is placed by the best location known for its venue, in this order (owner's rule):
  1. The address or coordinates the source itself sent. Trusted as correct.
  2. A lookup of the venue by name and town (OpenStreetMap's Nominatim search).
  3. The center of the venue's ZIP code, when one is known, else the center of its town.
- Works for every city site from the core, with no per-city code. A new city adds data only.

## Non-goals

- Directions, distance sorting, or a "near me" filter in the list.
- Showing events whose town is `Other` with no other location. They are left off the map, and the
  map says how many were left off.
- Editing locations from the site.

## Anti-goals (a failure even if it works)

- Making the list slower. The map's code and styles load only when Map is first chosen.
- Sending the visitor's location anywhere. Their coordinates stay in the browser and are never
  logged, stored, or put in a URL. (Builder's note: like any web map, the tiles the browser
  downloads for the area on screen tell the tile server roughly which area is being viewed. That is
  accepted; the site itself never sends the position.)
- Loosening the site's security headers beyond what the map strictly needs.
- Hammering Nominatim. Its policy is at most 1 request per second, a real User-Agent, and caching
  results. Each venue is looked up once, and the answer is kept.

## Constraints found in the code

- `website/static/_headers` sets a strict Content-Security-Policy: only the site's own scripts and
  styles, no CDNs, `connect-src 'self'`, and `Permissions-Policy: geolocation=()`, which blocks the
  location prompt outright.
- Events carry `venue`, `venueKey`, and `city`, never coordinates. Boise has 266 venues. About 320
  events use placeholder venues (`various-treasure-valley`, `mccall-area`) that have no single spot.
- Several adapters already see addresses and throw them away: Ticketmaster, Eventbrite
  (`primary_venue.address`), Meetup and other schema.org pages (`location.address`, `geo`), tribe,
  eventastic. The largest source, boise-mom (1,162 events), and the libraries give only a venue.
- `city.json` has one `coordinates` point for the whole metro, `cities`, `cityAliases`, and
  `zipCodes`. It has no per-town centers.
- The browser gets a slim copy of events.json built in `layouts/_partials/grid.html`, with short keys.
- Refine already keeps a cache of looked-up answers in `data/city-lookup.json` and commits it nightly.

## Approaches considered

1. Look up every venue once by name (Nominatim), cache the answer. Covers every source, but
   ignores better data some sources already send.
2. Only keep what sources send. Accurate where it works; leaves about half the events at town level.
3. Both: source data first, lookup for the rest, town center last. Most accurate, most work.

The owner picked 3, with the order in Goals.

For the map itself: MapLibre GL JS with OpenFreeMap's free vector tiles (no account, no key, no
usage limits for a public site). Leaflet with OpenStreetMap's own tiles was set aside because the
OSM tile servers discourage use by public sites. MapLibre is large (about 220 KB gzipped), which is
why it loads only on first use. Its built-in point clustering does the grouping. It is copied into
the core repo (`website/assets/vendor/maplibre/`, one pinned version, with its license), not loaded
from a CDN, so the CSP keeps `script-src 'self'`.

## Design

### Data: where locations live

A new machine-written file per city repo, `data/venue-locations.json`, keyed by `venueKey`:

```json
{
  "morrison-center-for-the-performing-arts": {
    "lat": 43.6033, "lon": -116.2012,
    "address": "2201 W Cesar Chavez Ln, Boise, ID 83725",
    "from": "feed", "checked": "2026-11-23"
  },
  "star-library": { "lat": 43.69, "lon": -116.49, "from": "lookup", "checked": "2026-11-23" },
  "some-hall": { "from": "none", "checked": "2026-11-23" }
}
```

- `from` is `feed` (the source sent it), `lookup` (Nominatim), `manual`, or `none` (looked up,
  not found).
- Refine never changes a `manual` entry. That is how the owner corrects a wrong pin: edit the
  entry and set `from` to `manual`.
- A `feed` location replaces a `lookup` or `none` one. A `lookup` never replaces a `feed` one.
- A `none` entry is tried again after 30 days. A `lookup` entry is not refreshed on a timer.
- Placeholder venues are never looked up, and each of their events goes to the center of that
  event's own town (or ZIP, when known). A venue is a placeholder when its `venueKey` starts
  `various-` or ends `-area`, or when its events in `events.json` fall in more than one town.
  The second rule catches organizers stored as venues, such as `estatesales-org`,
  `corbett-auctions`, `idaho-wineries`, and `oldspeak`. Estate sales and auctions stay at town or
  ZIP level on purpose: the sales adapter never stores a home's address, and the map doesn't
  either.
- A JSON Schema for the file goes in `ingestion/schema/`, and Test-Schema checks it.

### Ingestion: keep what sources send

`New-WkEvent` gains optional `-Latitude`, `-Longitude`, and `-Address` (one line, "street, town,
ST ZIP"). They are stored on the raw event only (`data/raw-events.json`), not in `data/events.json`.
The adapters that see a location pass it on: Ticketmaster (venue `location` and `address`),
Eventbrite and eventbrite-search (`primary_venue.address`, its `latitude` and `longitude`), Meetup
and other schema.org readers (`location.geo`, `location.address`), tribe (venue address fields and
`geo_lat`/`geo_lng` where present), eventastic. A coordinate pair outside a box around the city's
`coordinates` (about 150 miles) is dropped as bad data.

### Refine: fill the venue file

A new step after dedupe, `Update-WkVenueLocations` in a new `lib/VenueLocations.ps1`:

1. Collect feed locations from the raw events by `venueKey`. When one venue has several, use the
   coordinates reported most often.
2. For each venue in `events.json` with no entry, or a `none` entry older than 30 days, and not a
   placeholder: query Nominatim with the venue name, town, and state (or the feed address when
   there is one with no coordinates), limited to the state and a box around the metro. Accept the
   first result only if it falls inside that box. At most one request per second, with the bot's
   User-Agent. Stop after 300 lookups in one run, so the first run finishes and later runs pick up
   the rest.
3. Write the file sorted by key, so nightly diffs stay small. Refine's commit includes it.

A Nominatim failure warns and leaves the entry as it was. Refine never fails because of it.

### Town and ZIP centers

`city.json` gains `cityCenters`: one `[lat, lon]` per entry in `cities` (Valley County uses
McCall). The schema requires one per city. Boise and Boulder are filled in by hand once.
ZIP centers: when an event's venue has no point but the feed address has a ZIP, refine looks up the
ZIP once with Nominatim's postal code search and caches it in the same file under the key
`zip:83702`.

### The site

The build adds one short key to each event in the browser copy: `l`, the index into a new
`locations` array of `[lat, lon, exact]` (exact is 1 for `feed`, `lookup`, `manual`, 0 for a ZIP
or town center). Events with no location at all get no `l`. An event at a placeholder venue gets its own town's
center, so the lookup in grid.html is by venue for real venues and by the event's town otherwise. The array is built in grid.html from
`venue-locations.json` and `cityCenters`.

Choosing Map:

- Hides the table and pager and shows a map panel in their place, at most of the viewport's
  height. Choosing List brings them back. The filters stay above both and keep working: the map
  redraws when they change.
- The first time, loads MapLibre's script and CSS (fingerprinted Hugo resources) and asks for the
  visitor's location with `navigator.geolocation.getCurrentPosition` (timeout 10 seconds, no
  watching). Yes, and inside the same box around the city used for feed coordinates: center on
  them at about zoom 13, with a dot. Yes, but outside that box (a visitor in Seattle): treat it as
  a no, so they never open on an empty map. No, or an error, or a timeout: fit
  the shown events. The question is asked once per visit.
- Events at the same location are one point. Points cluster when zoomed out, showing a count.
  Tapping a cluster zooms in on it. Tapping a point opens a popup listing that place's events
  (date, time, title linked to the event), soonest first, up to 20 then "and N more", with a
  "near Boise" style note when the point is a town or ZIP center rather than the venue.
- Approximate points (town or ZIP centers) look different from exact ones, such as an outline
  instead of a filled circle.
- A line under the map says how many events are shown and how many have no location.
- The map's colors follow the site's light and dark tokens where MapLibre allows; the tile style is
  OpenFreeMap's "liberty" in light mode and "dark" in dark mode.
- Attribution: OpenFreeMap, OpenMapTiles, and OpenStreetMap contributors, as their licenses require.
- The view note ("coming soon") and its code are removed.

### Headers

In `website/static/_headers`:

- `Permissions-Policy`: `geolocation=(self)`.
- `connect-src`: add `https://tiles.openfreemap.org`.
- `img-src`: add `blob:`.
- `worker-src 'self' blob:`, because MapLibre runs its tile work in a web worker. Use MapLibre's
  CSP build with its worker file served from the site, if that avoids `blob:` for scripts.
- Everything else stays as it is. The header comment is updated to say why.

### Docs and tests

- `docs/schema.md`: the venue file. `docs/development.md`: the refine step, the map, the headers.
  `docs/github-setup.md`: a new city fills in `cityCenters`.
- Pester tests for: the source-first ordering, `manual` never overwritten, placeholders skipped,
  the 30-day retry, the out-of-box rejection, and adapter fields reaching the raw event. Nominatim
  is mocked; tests never call it.
- The site is checked by building locally and opening it in a phone-sized and a desktop-sized
  headless browser: list, map, filters changing the map, a popup, location denied.

## Left to the builder

- The MapLibre version (latest stable, pinned) and the exact tile style URLs.
- Exact colors, point sizes, popup layout, and the map panel's height on phones and desktops.
- Which fields each adapter has, beyond the ones named here, and their exact names.
- How placeholder venues are recognized beyond the two patterns named.
