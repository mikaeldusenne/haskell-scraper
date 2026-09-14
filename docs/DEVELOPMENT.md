# Development

## Commands

```sh
stack build
stack test --ghc-options=-Werror
python3 test/smoke.py
stack haddock --no-haddock-deps
stack sdist
```

`stack test` covers pure parsing/URL logic and temporary-directory regressions for
retries, atomic writes, path containment and subtree resume. It makes no network
requests. `test/smoke.py` starts an ephemeral loopback HTTP server and exercises
the real CLI, then enables the HTTP cases in the same Haskell test executable.
Those cases cover HTTP errors, truncated transfers, response timeout, same-origin
redirects, URL-encoded form login, cookies and cached binary downloads. No public
website or real credentials are used.

The smoke runner accepts `SCRAPER_EXE` and `SCRAPER_TEST_EXE` as optional paths to
already-built binaries. This permits validation with Cabal as well as Stack.
Python 3's standard library is sufficient.

Generate the Haddock reference with the command above; Stack prints its local
location. The CI workflow builds with the pinned GHC and treats compiler warnings
as errors, then runs the smoke test, generates API docs and creates a source archive.

## Code map

| Module | Responsibility |
| --- | --- |
| `Types` | Configuration, stage types, checked cache decoding |
| `Helpers` | URL resolution, HTTP transport, retry, safe filesystem helpers |
| `Scrapper` | Login, binary download cache, tree traversal and checkpoints |
| `Hafez` | Pure Hafez selectors and bilingual text output |
| `AmeriLingua` | Catalogue pagination, pure resource selectors, PDF validation and link export |
| `app/Main.hs` | Argument parsing and process exit status |

Keep site-specific logic in an adapter module. Prefer pure functions over extra
framework layers. Add a focused regression test when fixing an actual failure;
avoid tests that merely repeat implementation details. Fixture text must be
synthetic or clearly licensed for redistribution.

## Dependency maintenance

`package.yaml` drives Hpack. Do not hand-edit the generated, ignored
`haskellwebscrapper.cabal` file. `stack.yaml` and its lock file pin the snapshot.

To update dependencies, choose a compatible [Stackage LTS snapshot](https://www.stackage.org/lts),
update `stack.yaml` and the workflow's GHC version together, then run the commands
above. Review and commit the regenerated lock file. Verify the example adapter as
well. Keep dependency upgrades separate from unrelated parser or behavior changes.

## Boundaries

This is a sequential, finite-stage crawler, not a task queue. Checkpoints do not
track hashes of the pipeline code or revalidate completed files. One output
directory represents one source and one pipeline. The lock is for cooperating
processes, not a defense against another process deliberately changing files
between filesystem checks. A forcibly terminated process may leave an empty lock
and unused `.scraper-tmp*` files; normal exceptions clean up temporary files.

Remaining useful extensions include a deliberate `robots.txt` / `Retry-After`
policy, a total crawl budget, and opt-in checkpoint verification. Implement these
only with explicit semantics and fixtures; do not silently change existing resume
behavior or add unbounded retries.
