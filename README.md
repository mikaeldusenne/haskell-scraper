# Haskell Scraper

A small Haskell library for **staged, resumable HTML scraping**, with adapters for
English/Farsi ghazals at [Hafiz on Love](https://www.hafizonlove.com/divan/) and
authenticated lesson downloads from [AmeriLingua](docs/AMERILINGUA.md).

You describe a finite sequence of stages: an index yields section links, a section
yields document links, and the final stage saves the content. The crawler runs
sequentially, waits between HTTP requests, and records successful subtrees so an
interrupted run can resume.

This is a library with a site-specific executable. Passing an arbitrary website
to the Hafez command does **not** teach it that site's HTML structure. For another
site, write a short [adapter](docs/ADAPTERS.md).

## Install and build

Requirements: Git, [Stack](https://docs.haskellstack.org/en/stable/install_and_upgrade/),
a C toolchain, and the system libraries required by GHC (including GMP and zlib).
Python 3 is needed only for the local demonstration and HTTP smoke tests.

On Arch Linux, install the native build requirements with:

```sh
sudo pacman -Syu --needed base-devel gmp zlib
```

Install a recent upstream Stack release using the linked installation guide.
The [Arch Stack package](https://archlinux.org/packages/extra/x86_64/stack/)
was still on 2.9 and flagged outdated when checked on 2026-09-14, so it is not
the recommended route for this compiler version. Then:

```sh
git clone https://github.com/mikaeldusenne/haskell-scraper.git
cd haskell-scraper
stack build
stack test
stack run -- --help
```

The project pins [LTS 24.59 / GHC 9.10.3](https://www.stackage.org/lts-24.59).
Stack downloads the matching compiler when necessary; the first build needs
network access, several gigabytes of free space, and more time than later builds.
There is no dependency on a private `hlib` checkout, `Secrets.hs`, or libcurl.
`package.yaml` is the package source of truth; Stack generates the Cabal file.

To install the executable on your PATH:

```sh
stack install
# Stack reports the destination, normally ~/.local/bin.
haskellwebscrapper-exe --version
```

The historical package/executable spelling `haskellwebscrapper` is retained.

## Try it locally first

The repository includes a synthetic three-page site with original test text.
It exercises the real HTTP client and parser without requesting a public website.

From the repository root, start a server in one terminal:

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory test/fixtures
```

In another terminal, from the same repository:

```sh
stack run -- hafez \
  --base-url http://127.0.0.1:8000/ \
  --output demo_downloads \
  --delay-ms 0
```

Expected files:

| Path below `demo_downloads/` | Content |
| --- | --- |
| `index-01.html/p_demo.html/en.txt` | English text, preserving verse breaks |
| `index-01.html/p_demo.html/fa.txt` | Farsi text in UTF-8 |
| `index-01.html/p_demo.html/source.txt` | Source page URL |

The English text begins `Hello world.`. Run the same command again: the completed
crawl is skipped without additional HTTP requests. Stop the test server with Ctrl-C.
For an automated version, run `python3 test/smoke.py` after `stack test`.

## Use the Hafez adapter

```sh
stack run -- hafez --output hafez_downloads --delay-ms 1000
```

This follows the site's group links and the ghazal links actually listed in each
group. It does not download the PDF collection or the miscellaneous works.
The current `group-card`, `g-link`, `v-en` and `v-fa` HTML structures were inspected
on 2026-09-14. Missing or mismatched verse blocks produce an error, not empty files.

Review the site's terms and request policies before running a crawl. The crawler
does not implement `robots.txt` or `Retry-After` automatically. The site credits
Shahriar Shahriari; preserve the source URLs and consult the site's stated reuse
conditions before redistributing translations. If you just want the complete
collection to read, the site's own PDF downloads may be simpler than scraping.

| Option | Default | Meaning |
| --- | --- | --- |
| `--output DIR`, `-o DIR` | `hafez_downloads` | Output and resume state directory |
| `--base-url URL` | `https://www.hafizonlove.com/divan/` | Starting index URL; include `/` for a directory URL |
| `--delay-ms N` | `1000` | Delay before each request, including redirects and login |
| `--retries N` | `2` | Extra attempts per failed extraction stage |
| `--timeout-seconds N` | `30` | HTTP response timeout; must be positive |
| `--help`, `-h` | — | Help; does not crawl |
| `--version` | — | Package version |

No arguments prints help. Invalid arguments, failed HTTP requests, parse errors,
and local write errors produce a nonzero exit status. A failed stage gets at most
`1 + retries` attempts, with a two-second wait between attempts. Successful sibling
subtrees remain available for the next run.

## AmeriLingua

Download the lesson PDFs and retain Google Slides links with a fresh form login:

```sh
bash scripts/amerilingua.sh --output amerilingua_downloads
```

The script prompts for your credentials locally. Start with one lesson before
running the catalogue; see [the AmeriLingua guide](docs/AMERILINGUA.md) for login,
pagination, output files, restart behavior and live-site validation limits.

To add objectives, video transcripts, vocabulary and pronunciation MP3s to an
existing PDF catalogue, use `amerilingua-content` with the same output directory.
It maintains separate completion checkpoints. A companion yt-dlp script downloads
the saved video URLs; see [content and media](docs/AMERILINGUA.md#add-objectives-transcripts-vocabulary-and-media)
for commands, output files and the Arch Linux packages.

For AmeriLingua, `amerilingua-index` adds metadata, the site's ordered Lesson
Sequences and tag navigation using relative symlinks over the existing flat
catalogue. It also generates `index.html` at the catalogue root: open it directly
in a browser to search courses and combine tag filters without an HTTP server.
See the [catalogue navigation guide](docs/AMERILINGUA-INDEX.md).

## Resume and preserve your files

Use the **same command and output directory** to resume. Each node's
`.scraper-finished` file is written only after its stage and all descendants
succeed. A `.scraper-source` file binds the directory to its starting URL.
The `.scraper-urls` file records completed binary downloads made with the library's
`download` helper; the Hafez text adapter does not use this download cache.

Downloads are streamed to a temporary file beside their destination and installed
only after a complete response. Cached downloads are copied into additional
locations; no deduplication symlinks are created. Existing untracked download
files are refused. Generated files may be reused only when their bytes are
identical; different content is preserved and reported as an error.

A `.scraper-lock` directory prevents two `mainLoop` runs from sharing an output
directory. Normal exit and Ctrl-C release it. After a forced kill or power loss,
check that no crawler is still running, then remove **only the empty lock**:

```sh
rmdir hafez_downloads/.scraper-lock
```

Completion markers are checkpoints, not an integrity database. The crawler does
not revalidate already completed output or detect remote changes. If you edit or
remove output, change selectors, or want a fresh snapshot, choose a **new output
directory**. Keep the old one until you have checked the new result.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `stack` cannot find a matching compiler | Allow Stack to install GHC; check disk space and the linked Stack installation guide |
| HTTP status `401`/`403`, or login page received | The Hafez CLI has no login options; custom form login is documented in [Adapters](docs/ADAPTERS.md#form-login) |
| HTTP status `404`/`503`, timeout, or TLS failure | Verify the URL, network and site's availability; rerun to resume. TLS certificate validation stays enabled |
| Request outside the configured origin | Scheme, hostname and port must match `base`, including redirects; use the site's final HTTPS origin |
| No Hafez links / missing verse blocks | The wrong adapter is being used, or the site's HTML changed; inspect a page and update the pure selectors |
| Invalid cache record | Preserve the damaged `.scraper-urls` file for diagnosis; use a new output directory if you cannot repair it confidently |
| Existing untracked file / different content | Nothing was overwritten; inspect the existing file or select a fresh output directory |
| `.scraper-lock` already exists | Another crawl may be active; see the lock recovery instructions above |
| Completion marker belongs to another pipeline | Use a new output directory after changing the pipeline |

## Library and development

- [Write an adapter, download assets, configure login](docs/ADAPTERS.md)
- [Build, test, architecture, dependency updates](docs/DEVELOPMENT.md)
- [Changes and migration from 0.1](CHANGELOG.md)

The library fetches server-rendered UTF-8 HTML. It does not execute JavaScript,
solve interactive login/MFA flows, discover arbitrary pagination, or support
multiple writers in one output directory. Binary downloads are streamed; HTML
pages are held in memory. HTTP timeouts are response timeouts, not a total deadline
for the entire crawl. Extraction stages determine the breadth and depth of work.

## License

[BSD 3-Clause](LICENSE), matching the project's existing package declaration.
Scraped content remains subject to its source's rights and reuse conditions.
