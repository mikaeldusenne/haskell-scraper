# Navigate the catalogue by sequence and tag

`amerilingua-index` enriches an existing flat catalogue with lesson metadata and
relative directory symlinks. It fetches HTML only, using the same login, request
delay, retries and output lock as the other AmeriLingua commands. Lesson folders,
PDFs, Markdown and downloaded media stay in place.

From the repository directory, use the **same catalogue URL and output directory**
as your previous crawl:

```bash
source "$HOME/.env"
PATH="$HOME/.ghcup/bin:$PATH" \
AMERILINGUA_LOGIN="$AMERILINGUA_EMAIL" \
AMERILINGUA_PASS="$AMERILINGUA_PWD" \
"$HOME/.ghcup/bin/stack" run -- amerilingua-index \
  --base-url https://www.amerilingua.com/esl-lesson-plans \
  --output amerilingua_catalogue \
  --delay-ms 1000
```

The output path above is an example; replace it with your catalogue directory.
This command accepts a catalogue, including filters, rather than a single lesson.
It can also build a metadata-only catalogue in an empty directory; downloading
PDFs and media remains a separate command.

## Files and navigation

| Path relative to the catalogue | Purpose |
| --- | --- |
| `<lesson>/metadata.json` | Title, source URL, Category, Level, Topic, Grammar, Focus, Media, Lesson ID and Lesson Time when present |
| `_navigation/README.md` | Entry point to tags and sequences |
| `_navigation/tags/category/Business_English/<lesson>` | Relative symlink to the original lesson folder |
| `_navigation/tags/level/A2_Elementary/<lesson>` | Another view of the same folder; multi-valued levels appear under each level |
| `_navigation/sequences/General_English/<sequence>/` | General English sequences linked from the site's hub |
| `_navigation/sequences/Business_English/<sequence>/` | Business English and Interview Prep sequences |
| `<sequence>/001-<lesson>`, `002-<lesson>`, … | Relative symlinks in the site's teaching order |
| `<sequence>/README.md` | Sequence title, introduction, numbered lesson headings, explanations and local/online links |

Tags cover **category, level, topic, grammar, focus and media**. Comma-separated
values become separate tags and JSON arrays; Lesson ID and Lesson Time remain
strings. Missing optional fields are omitted. Category, Level and the lesson title
are required so a changed page layout cannot silently produce an empty index.
Folder labels replace punctuation/spaces with underscores; `label.txt` preserves
the exact tag value and detects naming collisions.

Sequence membership and order come from the actual
[Lesson Sequences hub](https://www.amerilingua.com/lesson-sequences) and its linked
pages. They are **not inferred from Category or Level**. The parser follows the
page's h2 section and ordered h3 lesson cards, retaining the teaching notes.
General English and Business English views mirror the hub's groups.

A sequence lesson outside a filtered/local catalogue is marked “Not in this
catalogue” with an online link, without a dangling symlink. If an expected local
lesson failed indexing, that sequence remains unfinished and retryable.

## Resume and portability

Rerun the same command after an interruption. Separate `.scraper-index-finished`
checkpoints retain completed lessons and sequences; identical symlinks are safe
to reuse. Existing files, different symlinks and changed JSON/index text are never
silently replaced. The index is a snapshot; completed indexes are not automatically
refreshed when the website changes.

The links work directly on Arch Linux and remain valid if you move the **whole
catalogue** together. Copy tools must preserve symlinks rather than dereference
them. The media downloader does not follow these directory symlinks, so it does
not download the same lesson again through each tag.

Selectors are based on the supplied lesson metadata and Business English B2/C1
HTML, with the public hub checked on 2026-09-21. Unsupported sequence layouts fail
explicitly. Authenticated catalogue indexing has not been independently run
against the live site.
