# AmeriLingua

Download every PDF linked from each lesson's resource bar, and keep all resource
URLs (including Google Slides) in `links.txt`. The adapter follows catalogue
pagination and writes one folder per lesson. An individual lesson URL skips the
catalogue entirely.

## First run

From the project root, start with the lesson used to inspect the site:

```sh
bash scripts/amerilingua.sh \
  --base-url https://www.amerilingua.com/esl-lesson-plans/telling-time \
  --output amerilingua_telling_time
```

The script reuses exported credentials and asks locally only for missing values.
Passwords entered at the prompt are hidden and are not saved. Do not run the
script with shell tracing (`bash -x`).

| Value | Preferred variable | Fallback variable |
| --- | --- | --- |
| Email | `AMERILINGUA_LOGIN` | `AMERILINGUA_EMAIL` |
| Password | `AMERILINGUA_PASS` | `AMERILINGUA_PWD` |

If your private `~/.env` defines `AMERILINGUA_EMAIL` and `AMERILINGUA_PWD`, export
the assignments before launching the script. A subshell limits their lifetime:

```bash
(
  set -a
  source "$HOME/.env"
  set +a
  bash scripts/amerilingua.sh --output amerilingua_downloads
)
```

Sourcing a file does not export plain assignments unless `set -a` is enabled or
the file uses `export`. The launcher does not source files automatically. The
preferred nonempty variable wins when both names exist; empty values fall back
to the alias and then to a prompt. Never print the password to check it is loaded.

Once that works, collect the catalogue:

```sh
bash scripts/amerilingua.sh --output amerilingua_downloads --delay-ms 1000
```

Expected outputs include `lesson_plan.pdf`, `worksheets.pdf`, the available
answer keys and homework PDFs, `source.txt` and `links.txt`. Filenames are derived
from the site's resource URLs; the adapter does not hard-code a fixed number of
PDFs. Google Slides links remain links, with their query and slide fragment intact.
The scraper does not download a Google Slides presentation or export it as PDF.

For automation, supply `AMERILINGUA_LOGIN` and `AMERILINGUA_PASS` through your
process environment and run `stack run -- amerilingua [OPTIONS]` directly. Do not
put credentials in Git, command arguments, examples, or bug reports.

## Login and access checks

The configured flow is `GET /login`, followed by `POST /login` with the freshly
parsed hidden `_token`, `email`, and `password`. The initial cookies are retained
for the POST; cookies returned after login are used for subsequent requests. The
generic `login_csrf_field` setting enables this behavior without changing simple
form login for other adapters. Cookies and tokens stay in memory for that run.

A successful HTTP login response does not by itself prove that your account has
access. The adapter checks resource links on the first lesson before discovering
the rest of the catalogue. Locked/missing buttons fail explicitly. PDF responses
must start with `%PDF-` before they are committed to disk or the download cache,
so a login page returned with HTTP 200 cannot become a fake PDF.

The selectors and login field names were identified from the public catalogue
and user-provided browser inspection on 2026-09-14. The tests use synthetic HTML
and a local HTTP server, including CSRF/session continuity and HTML returned in
place of a PDF. A successful authenticated run on the live site has **not** been
independently verified: the remote inspection browser was blocked by Cloudflare.
A user reported `Scrape completed.` for a local `telling-time` run on 2026-09-14;
the resulting files have not been independently inspected.

If your local run is blocked by Cloudflare, requires a CAPTCHA/MFA, or uses a
different sign-in method, this HTTP client cannot complete that flow. It does not
bypass those controls. Check normal access in your browser and report only the
scraper's error, without passwords, CSRF tokens or cookie values.

## Traversal, restart and limits

- Lesson links come from `.lesson-item.row`; resource buttons come from
  `.lesson-files .lesson-files-item a`. Unrelated navigation is excluded.
- Catalogue pagination follows the next-page link (`rel="next"`, `»`, `›`, or
  `Next`), preserves filters in that link, and rejects cycles or more than 200
  catalogue pages. Index pages are discovered before downloading the lessons.
- Requests, redirects and PDF downloads stay within the configured origin.
  External resource URLs are listed in `links.txt` without making requests to them.
- Ctrl-C stops the run. Use the same command/output directory to resume successful
  subtrees. Each new run signs in again; a session expiring mid-download causes a
  failed lesson, which can be retried on the next run.
- Completed outputs are not refreshed automatically. Use a new directory after
  changing the selected catalogue, the adapter, or when collecting an updated copy.

## Development

`src/AmeriLingua.hs` keeps index/resource parsing pure and uses the existing
crawler for HTTP, retries, atomic downloads and checkpoints. `copyPDF` is a small
consumer passed to `downloadWith`; ordinary `download` behavior is unchanged.

```sh
stack test --ghc-options=-Werror
python3 test/smoke.py
```

References: [catalogue](https://www.amerilingua.com/esl-lesson-plans),
[example lesson](https://www.amerilingua.com/esl-lesson-plans/telling-time).
