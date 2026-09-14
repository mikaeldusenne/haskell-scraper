# Writing an adapter

Keep HTML selection pure; use small stages to connect parsing to HTTP and disk.
The complete [example](../examples/Download.hs) downloads links from the synthetic
site. Run it against the local server described in the README:

```sh
stack exec -- runghc -isrc examples/Download.hs
```

It writes the linked section HTML to `example_downloads/`. For a real site, change
its URL and selectors, then add one representative synthetic fixture.

## Stage contract

```haskell
type PPM a = StateT Config IO a
type Stage = UrlWithDest -> PPM (Either String [UrlWithDest])
```

`PPM` uses `Control.Monad.Trans.State.Strict`. `UrlWithDest` contains the page URL
and the directory for that node. `mainLoop config stages` starts at `config.base`
inside `config.download_folder`; you do not need to call `createConfig` first.

An intermediate stage returns `Right children`. Each child has a URL reference
(relative to the current page, or absolute) and a nonempty destination **relative
to its parent**. Absolute destinations, `..` components, reserved metadata paths
and duplicate destinations are rejected. The final stage performs its writes and
returns `Right []`. An empty intermediate result is an error, as are unprocessed
children from the final stage.

Return `Left "useful explanation"` for network or parse failures. The crawler
retries that stage, so make writes idempotent. `writeOutput` handles generated
UTF-8 bytes without replacing different existing content. `download` handles
streaming and its URL cache. Filesystem exceptions become failed stages; Ctrl-C
is not swallowed.

Use the final Bool from `mainLoop` to propagate failure:

```haskell
ok <- mainLoop config stages
unless ok exitFailure
```

The Hafez implementation uses `[findlinks, findlinks, genPoem]`. Its selection
functions `extractLinks` and `parsePoem` can be tested directly without IO.

## Useful functions

| Function | Purpose |
| --- | --- |
| `extracturl :: URLString -> PPM (Either String [Tag String])` | Fetch and parse UTF-8 HTML; detect the configured login marker |
| `openURL :: URLString -> PPM (Either String String)` | Fetch UTF-8 text with checked HTTP status |
| `resolveURL :: URLString -> URLString -> Either String URLString` | Pure RFC 3986 URL-reference resolution; preserves query and removes fragment |
| `tag_class_f "a" "download" (fromAttrib "href")` | Select attributes from elements with a CSS class token |
| `download :: UrlWithDest -> PPM (Either String ())` | Save one URL to an absolute destination below the configured output directory |
| `downloader generators "" node` | Download selected links plus their containing page into the node directory |
| `writeOutput root path bytes` | Atomically write generated content, accepting identical existing bytes |
| `retry extraAttempts description action` | Bounded retry of an action returning `Either` |

`mkurl` resolves against `Config.base`. For links found on a nested page, use
`resolveURL (url node) href`; joining URLs with `(</>)` is incorrect. That operator
is for filesystem paths. Query-bearing resource filenames get a deterministic
query digest to distinguish, for example, `file?id=1` and `file?id=2`.

Requests are restricted to the configured **origin** (scheme + hostname + port),
including every redirect. The redirect limit is ten per request chain. An off-site
CDN is consequently rejected; a custom cross-origin policy would require extending
the transport explicitly.

Call side-effecting helpers inside `mainLoop` so its directory lock is held. Custom
stages are ordinary Haskell IO and must use the checked write helpers; the library
cannot prevent arbitrary IO in an adapter from writing elsewhere.

## Configuration

Start from `defaultconfig` and override only what the adapter needs.

| Field | Default | Meaning |
| --- | --- | --- |
| `download_folder` | `scrapper_downloads` | Output root; normalized to an absolute path |
| `base` | `https://example.com/` | Starting page and allowed origin |
| `request_delay_ms` | `1000` | Wait before each HTTP request |
| `retry_count` | `2` | Extra attempts per stage |
| `retry_delay_ms` | `2000` | Wait between failed attempts |
| `timeout_seconds` | `30` | HTTP response timeout |
| `login_path` | `Nothing` | Optional form endpoint, resolved against `base` |
| `login_arg_login` | `member_login` | Username form field |
| `login_arg_pass` | `member_pass` | Password form field |
| `login_env_prefix` | `SCRAPER_` | Prefix for `LOGIN` / `PASS` environment variables |
| `login_csrf_field` | `Nothing` | Fetch the login page first and submit this hidden form field with its session cookies |
| `login_needed_tag` | `TagOpen "button" [("aria-label", "Please sign in")]` | Recognizable login-page marker; customize to the site |
| `urlsfile` | `.scraper-urls` | Plain filename for the successful-download cache |
| `alreadies_urls` | `[]` | Internal cache state, loaded by `mainLoop` |
| `session_cookies` | Empty cookie jar | Internal session state, updated after responses |

## Form login

A custom adapter can configure a simple form login:

```haskell
config = defaultconfig
  { base = "https://example.com/members/"
  , download_folder = "members_downloads"
  , login_path = Just "/login"
  , login_arg_login = "username"
  , login_arg_pass = "password"
  , login_env_prefix = "MY_SITE_"
  }
```

Supply credentials through the environment. For Bash, prompting avoids putting
the password literally in shell history:

```bash
read -r -p 'Login: ' MY_SITE_LOGIN
read -r -s -p 'Password: ' MY_SITE_PASS
printf '\n'
export MY_SITE_LOGIN MY_SITE_PASS
# Run your adapter here.
unset MY_SITE_LOGIN MY_SITE_PASS
```

For a server-rendered CSRF form, set `login_csrf_field = Just "_token"` (using the
site's actual field name). Login fetches a fresh hidden value and retains the
initial cookies before submitting the form. Missing or conflicting tokens fail
explicitly. See [AmeriLingua](AMERILINGUA.md) for a concrete adapter.

`mainLoop` performs one login before traversing the tree. Form values are URL
encoded; cookies persist in memory for that run and are never written to a
`cookies` file. Missing variables are reported by name. Request exceptions are
not rendered verbatim, because they can contain credentials.

A successful HTTP response alone cannot prove the site's login succeeded. Set
`login_needed_tag` to a marker that identifies its login page and test against
that site's actual behavior. The library does not automatically reauthenticate,
execute JavaScript, solve interactive challenges, or handle OAuth/MFA. For these flows, a
site API or an explicitly designed adapter is needed.
