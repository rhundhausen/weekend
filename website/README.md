# website

The Hugo theme every city site is built with. A city repo holds only its own files: `website/wrangler.jsonc`, `website/static/` (icons and web manifest), `website/data/display.json`, and optionally `website/assets/css/skyline.css`. Any city file at the same path as one here replaces it. The theme config is `hugo.toml` at this repo's root, because Hugo lets a theme mount only folders inside it, and the vocabulary in `ingestion/vocabulary` is mounted as `data/vocabulary`.

`site.toml` here is every city's site config: build.sh passes it to Hugo with the title from `city.json`, and it mounts the city's repo-level `data/` folder (events, archive, meta), `ingestion/sources.json` as `data/sources.json` (the `/sources/` page and header count), and `city.json` as `data/city.json` (site name, repo, time zone, coordinates, search aliases, and About page text). Each city site deploys with Cloudflare Workers Builds on every push to the city repo's `main`.

## Build it

From a city repo's `website/` folder, with this repo checked out next to the city repo (Hugo extended 0.162.1, or the script installs it):

```bash
bash ../../weekend/website/build.sh           # builds to website/public/ (gitignored)
```

Cloudflare runs the city's `wrangler.jsonc` build command, which clones this repo and runs the same script:
`git clone --depth 1 https://github.com/rhundhausen/weekend ../.core && bash ../.core/website/build.sh`.
The script reads the time zone from `city.json`, copies `worker/` into the city's `website/worker/` (wrangler's `main`; build output, not committed), and runs Hugo with this repo as the theme. To preview while editing, run Hugo the same way from the city's `website/` folder: `hugo server --config ../../weekend/website/site.toml --themesDir ../.. --theme weekend` (with `HUGO_TITLE` set to the site name for the right title).

## How it works

- `layouts/_partials/grid.html` (the home page, and each category's and city's page) reads `events.json` and the category and size lookups at build time, and writes a slimmer copy (short keys, only the fields the page shows) to `data/events.<hash>.json`.
- The build also draws the page's first 25 rows, as app.js first shows them, and lists them as schema.org Events (`application/ld+json`), so search engines and readers that run no script see real events. app.js replaces the rows with the same rows when it loads.
- `assets/js/app.js` loads that file and does the rest in the browser: search (all words must match, accents ignored), the date, city, size, and category filters, sorting, and paging. The filters are kept in the URL, so a filtered view can be shared or bookmarked: one chosen category is the path (`/music/`), one city with no single category is the path (`/meridian/`), and the rest are the query.
- `assets/js/period.js` sets the day, sunset, or night look before the page draws, and `countup.js` sets up the header count. Neither is inline: no page has an inline script or style, so the Content-Security-Policy in `static/_headers` allows only the site's own files.
- The List and Map buttons switch views. `assets/js/map.js`, loaded only the first time Map is chosen, draws the events the list would show, on every page, with MapLibre GL JS on OpenFreeMap's tiles. Each event's point (`l`, [lat, lon, exact]) comes from `data/venue-locations.json`, else its town's center in `city.json` `cityCenters` (development.md, "Venue locations"). The visitor's position, when they allow it, stays in the page.
- MapLibre is copied into `assets/vendor/maplibre/` (the version is in `VERSION`), not loaded from a CDN. To update it: `npm pack maplibre-gl@<version>`, then copy `dist/maplibre-gl.mjs`, `dist/maplibre-gl-worker.mjs`, `dist/maplibre-gl.css`, and `LICENSE.txt` over the old files and change `VERSION`. The build publishes the two scripts as `.js` and gives MapLibre the worker's address (`setWorkerUrl`), so the worker is served from the site too.
- `layouts/404.html` is the page for an address the site doesn't have (Cloudflare serves it with status 404).
- `assets/css/site.css` holds the styles. Colors are CSS variables with a dark set for `prefers-color-scheme: dark`. Below 760px wide, each row becomes a card.
- No external scripts, fonts, or CDNs. Event text comes from outside sources, so the script only ever sets it with `textContent`, and the Content-Security-Policy is a second guard. The map's tiles, fonts, and icons are the one outside source of data (`connect-src` allows `tiles.openfreemap.org`); see the comment in `static/_headers`.

## Visitor log

A private log of who uses the site and what they search for. Only the Cloudflare account can read it; nothing serves it over the web.

- **What is logged:** `app.js` posts to `/api/log` when the page opens (a `view`) and each time the filters settle for 2 seconds (a `search`): the query string, the search words, how many events matched, the window width, and on views the referring page. The Worker (`worker/index.js`, which `wrangler.jsonc` runs only for `/api/*`) adds the time, the IP address, Cloudflare's location and network for that address, and the device (phone, tablet, or desktop), browser, and OS from the User-Agent, then stores one row in the `visits` table. Columns are described in `worker/schema.js`.
- **Where:** the city's D1 database (`logDatabase` in `city.json`, such as `weekendboise-log`), bound as `LOG_DB`. The table is created on the first log request. A daily cron (10:00 UTC) deletes rows older than 90 days.
- **Viewing:** `../weekend/website/scripts/Get-VisitorLog.ps1`, run from the city repo (newest 100 rows from the last 7 days; `-Days`, `-Last`, `-Ip`, `-Search`, `-IncludeBots`) or `-Summary` (visits by device, browser, and city, top searches, and searches that found nothing). It runs `wrangler d1 execute` as you, so run `npx wrangler login` once first. The Cloudflare dashboard's D1 console (Storage and databases > D1 > the city's `logDatabase`) runs any SQL, for example `SELECT * FROM visits ORDER BY ts DESC LIMIT 50`.
- **Tests:** `node --test` in `website/worker` (also run by the test workflow).
- **Setting it up:** create the database once with `npx wrangler d1 create <logDatabase>` (or in the dashboard), then add its binding to `wrangler.jsonc`:
  `"d1_databases": [{ "binding": "LOG_DB", "database_name": "<logDatabase>", "database_id": "<id>" }]`.
  Until the binding exists, `/api/log` answers 204 and stores nothing.
