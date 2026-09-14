# Changelog

## Unreleased

- Add the `amerilingua` adapter: catalogue pagination, all lesson PDFs, resource
  links (including Google Slides), and single-lesson downloads.
- Support fresh hidden CSRF form tokens and session cookies during login.
- Reject non-PDF responses before writing a successful download/cache entry.
- Add a local credential prompt and focused offline/loopback coverage.
- Trim surrounding whitespace in AmeriLingua links before URL and fragment parsing,
  fixing `Invalid URL reference` on lessons such as `who-said-that`.

## 0.2.0.0

- Make builds portable: remove the private `hlib` path and missing `Secrets`
  dependency; use LTS 24.59 / GHC 9.10.3 and maintained `http-client` / TLS libraries.
- Replace implicit execution with an explicit `hafez` CLI and useful exit statuses.
- Adapt Hafez extraction to current group/ghazal links and bilingual verse blocks.
- Preserve UTF-8, inline text and verse breaks; report missing or mismatched content.
- Check HTTP errors, bound retries/redirects, configure request delays/timeouts,
  and restrict requests to the configured origin.
- Submit encoded form credentials from environment variables and keep session
  cookies in memory. Remove unbounded automatic re-login.
- Stream downloads into temporary files, cache only completed transfers, copy
  cached files instead of repairing/creating symlinks, and preserve existing data.
- Mark a subtree complete only after all descendants succeed; lock each output
  directory while crawling and reject escaping child paths.
- Add synthetic fixtures, focused regressions, a local HTTP demonstration, CI,
  an example adapter and user/developer documentation.
- Add a license file matching the pre-existing BSD3 package declaration.

### Migration from 0.1

Use a **new output directory** for the first 0.2 run. Older `finished` markers
could be written after failures, and `urls.txt` could contain failed downloads.
The new `.scraper-*` state deliberately does not trust either format. Existing
output is not automatically migrated or deleted.

| Previous API / behavior | Replacement |
| --- | --- |
| Run executable without arguments to crawl | Explicit `hafez` command; no arguments now shows help |
| `mainLoop :: Config -> [Stage] -> IO ()` | Returns `IO Bool`; callers should propagate failure |
| `extracturl` returns tags or crashes | Returns `Either String [Tag String]` in `PPM` |
| `openURL (Just cookieFile) url` | `openURL url`; cookies are in `Config` |
| `mkurl` always returns a String | Returns `Either String URLString` in `PPM` |
| `Secrets.login` / `Secrets.pass` | `<prefix>LOGIN` / `<prefix>PASS` environment variables |
| Shared `cookies` file | In-memory, per-run cookie jar |
| Lazy State imports | `Control.Monad.Trans.State.Strict` |
| `finished`, `urls.txt` | `.scraper-finished`, `.scraper-source`, `.scraper-urls`, `.scraper-lock` |
| Old Hafez `linklist` / `Eng` / `farsi` selectors | Current `group-card`, `g-link`, `v-en`, `v-fa` structures |

The package and module spelling (`haskellwebscrapper`, `Scrapper`) is retained.
Unused starter code and private-library helper imports are removed. URLs now use
URI resolution, so directory bases must end in `/`. HTTP-to-HTTPS redirects also
change origin: configure the final HTTPS origin directly.
