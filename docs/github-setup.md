# Setting up a city

The steps to start a new city site on the engine. Do them in order. How the parts work once they
run: [development.md](development.md).

## 1. The repository

Create a public repo for the city (such as `rhundhausen/weekend<city>`), with `main` as its default
branch: the nightly schedule only runs on the default branch. Add the city's own files
(development.md, "Engine and city repos"):

- `city.json`, checked by `ingestion/schema/city.schema.json`. `siteName`, `domain`, and `repo`
  set the bot's User-Agent, the data commit identity, and the report sender.
- `ingestion/sources.json` ([sources.md](sources.md)).
- `data/schema/` with the city's `venue-aliases.json`, `place-cities.json`, and `sizes.json`.
- `website/wrangler.jsonc`, `website/static/`, `website/data/display.json`, and optionally
  `website/assets/css/skyline.css`.
- `.github/workflows/ingest.yml`, `refine.yml`, and `test.yml`, each a short caller of this repo's
  reusable workflow. Copy them from an existing city and change only the cron hours in
  `ingest.yml` (the two UTC hours midnight falls on in the city's time zone).
- `README.md` for site owners: who the bot is, how it behaves, and how to opt out. The User-Agent
  links to it.
- `.gitignore`, `.gitattributes`, and `LICENSE`, copied from an existing city. The `.gitignore`
  keeps out the engine checkout (`.engine/`), `out/`, and the build output in `website/`.

Validate locally with the engine checked out beside the repo:
`../weekend/ingestion/scripts/Test-Sources.ps1`, then build the site
([website/README.md](../website/README.md)).

## 2. Actions

Settings > Actions > General:

- Actions permissions: allow all actions, or at least actions created by GitHub, and the
  reusable workflows in `rhundhausen/weekend`.
- Workflow permissions: either setting works, because the callers ask for `contents: write` and
  `actions: read` themselves.

If `main` gets a branch protection rule or ruleset, allow `github-actions[bot]` to push to it, or
the nightly data commits will be rejected.

## 3. Secrets

Settings > Secrets and variables > Actions > New repository secret. The names must match exactly;
the table in development.md says what each is for. Create only the ones the city's sources use,
plus `RESEND_API_KEY` and `REPORT_EMAIL` for the report emails (one address, or several separated
by commas). A secret you don't create reaches the scripts as empty: that source fails with a
warning while the rest run, and without the Resend secrets the email step warns and sends nothing.

For the emails, verify the city's domain in Resend (resend.com > Domains) and create an API key
scoped to it with sending access. The sender, `<siteName> Reports <reports@<domain>>`, comes from
`city.json`, not a secret.

## 4. Cloudflare

1. Workers & Pages > Create > Import a repository: the city repo, with `website` as the root
   directory. The build command comes from `wrangler.jsonc`, which clones the engine and runs its
   `build.sh`.
2. For the visitor log, create the D1 database named in `city.json`'s `logDatabase`
   (`npx wrangler d1 create <logDatabase>` or the dashboard) and put its id in `wrangler.jsonc`
   (website/README.md, "Visitor log").
3. Add the city's domain to the Worker (Settings > Domains & Routes).

## 5. The first run

1. Actions > ingest > Run workflow, branch `main`, with the source left blank, so the raw file
   starts with every source.
2. When it finishes, check:
   - The run is green and the `out` artifact holds the sources' files and `run.json`.
   - `main` has a new commit by the city's bot titled `data: raw ingest YYYY-MM-DD [skip ci]` that
     changes only `data/raw-events.json`, and Cloudflare skipped it.
3. Refine starts by itself when ingest finishes. When it finishes, check:
   - The run is green and its log starts with the raw file's `asOf` and source count.
   - `main` has a new commit titled `data: nightly refine YYYY-MM-DD` that changes only
     `data/events.json`, `data/archive/`, `data/links.json`, `data/city-lookup.json`, and
     `data/meta.json`, and Cloudflare deployed it.
   - The test workflow did not run for either commit.
4. If a commit step fails with a permission error, recheck step 2.

After that, ingest runs nightly at midnight in the city's time zone and refine follows each run.
GitHub turns off scheduled workflows in a public repo after 60 days with no repository activity;
the nightly data commits count as activity, so this only matters if ingest stops committing.
