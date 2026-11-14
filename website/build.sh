#!/usr/bin/env bash
# Builds a city's site with this engine repo as its Hugo theme (see hugo.toml at the repo root).
#
# Run it from the city repo's website/ folder (the Cloudflare project root). The city's
# wrangler.jsonc build command fetches the engine and runs this script:
#   git clone --depth 1 https://github.com/rhundhausen/weekend ../.engine && bash ../.engine/website/build.sh
# Locally, with the engine checked out next to the city repo:
#   bash ../../weekend/website/build.sh
#
# It reads the city's time zone from ../city.json, installs Hugo when the pinned version is not
# already on the PATH, copies the engine's Worker into worker/ (wrangler.jsonc's main; the copy is
# build output, not committed), and builds into public/.

set -euo pipefail

HUGO_VERSION=0.162.1
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CITY_JSON="../city.json"

if [ ! -f "$CITY_JSON" ]; then
  echo "No $CITY_JSON: run this from a city repo's website/ folder." >&2
  exit 1
fi

# The city's IANA zone, so Hugo's dates match the site's. Node ships with Cloudflare's build image.
TZ="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$CITY_JSON', 'utf8')).timeZone)")"
export TZ
# The site's address, so the sitemap's links are absolute (pages still link each other by path).
DOMAIN="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$CITY_JSON', 'utf8')).domain)")"
# The site's name, as Hugo's title (site.toml has the rest of the config).
export HUGO_TITLE="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$CITY_JSON', 'utf8')).siteName)")"
export HUGO_CACHEDIR="${PWD}/.cache/hugo"

if ! hugo version 2>/dev/null | grep -q "v${HUGO_VERSION}"; then
  mkdir -p ~/.local/bin
  echo "Installing Hugo ${HUGO_VERSION}..."
  curl -sfL "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.tar.gz" \
    | tar -xz -C ~/.local/bin hugo
  export PATH="${HOME}/.local/bin:${PATH}"
fi
hugo version

# The commits being built, for the version line on the About page (site.Params.enginecommit and
# sitecommit). Cloudflare's build sets WORKERS_CI_COMMIT_SHA if the city checkout has no history.
ENGINE_COMMIT="$(git -C "$ENGINE" rev-parse --short=7 HEAD 2>/dev/null || true)"
SITE_COMMIT="$(git -C .. rev-parse --short=7 HEAD 2>/dev/null || true)"
if [ -z "$SITE_COMMIT" ] && [ -n "${WORKERS_CI_COMMIT_SHA:-}" ]; then SITE_COMMIT="${WORKERS_CI_COMMIT_SHA:0:7}"; fi
export HUGO_PARAMS_ENGINECOMMIT="$ENGINE_COMMIT" HUGO_PARAMS_SITECOMMIT="$SITE_COMMIT"
echo "Engine: ${ENGINE} (${ENGINE_COMMIT:-not a git checkout}), site: ${SITE_COMMIT:-unknown}"

rm -rf worker
cp -R "$ENGINE/website/worker" worker
rm -rf worker/test worker/node_modules

# site.toml mounts the city's ../data, ../ingestion/sources.json, and ../city.json, so the full
# city repo is needed; Cloudflare clones it and runs this from website/.
hugo build --gc --minify --config "$ENGINE/website/site.toml" --baseURL "https://${DOMAIN}/" --themesDir "$(dirname "$ENGINE")" --theme "$(basename "$ENGINE")"
