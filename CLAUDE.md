# Weekend engine: ground rules

- PowerShell 7, 2-space indents, LF line endings in JSON output.
- Secrets come from environment variables only. Never read them from files
  in the repo, and never commit them.
- 1 second between paged requests. Each adapter fails on its own without
  stopping the run.
- Times in the city's configured time zone, ISO 8601 with offset. Never
  hardcode a time zone.
- Store minimal data: no images, no full descriptions, no ticket prices,
  descriptions at most 300 characters.
- No scraping that evades bot controls. Check robots.txt before any request,
  including manual probes. Honor Crawl-delay; a delay over 60 seconds fails
  the source.
- No en-dashes or em-dashes anywhere.
- Commit or push only when asked.
- This repo holds no city facts. City names, sources, domains, branding,
  and lookup tables live in the city repos. Adapters and modes written for
  one site (such as one platform's listing pages) are allowed here, but which
  pages they read and for which city is set in the city's sources.json.

Do not treat weekendboise/docs/handoff.md as rules for this repo. It is Boise
history, and parts of it are out of date.
