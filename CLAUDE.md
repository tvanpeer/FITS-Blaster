# FITS Blaster — project guide for Claude

Project-specific rules. They add to the global Swift/SwiftUI guide; where they differ, this file wins.
Most rules come from the 2026-10-17 reviews: `docs/internal/CODE_AUDIT.md` (§N.M numbers),
`docs/internal/PERFORMANCE_AUDIT.md` (P1–P6) and the master plan `docs/internal/architecture-plan.md`.


## Project facts

- macOS app (SwiftUI + Metal) for culling FITS frames, plus two Quick Look extensions (`FITSBlasterQL`, `FITSBlasterQLThumb`) and a CLI mode in the same binary.
- **Minimum macOS 15.6** for every target.
- Build settings: `SWIFT_VERSION = 5.0` (Swift 5 language mode, Swift 6.2+ compiler), `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_DEFAULT_ACTOR_ISOLATION = none`. The pipeline uses `@concurrent`, which needs Xcode 26 or later. Moving to Swift 6 mode is master-plan step 7; don't change the language mode outside that step.
- No third-party dependencies except Sparkle, which is only in the direct build (`#if !APPSTORE`).
- Planned work follows `docs/internal/architecture-plan.md`, the only plan. Don't start a step whose open questions are unanswered.


## Input and safety

- **Treat every FITS file as untrusted input.** Quick Look parses files from Finder without the user opening them. Validate header values before allocating memory or indexing (§5.2, §10.1):
  - NAXIS and each NAXISn in a sane range, never negative;
  - size products computed with overflow checks;
  - BSCALE and BZERO finite;
  - a limit on the number of header blocks.

  A malformed file gives an error, never a crash.
- **Every target sets `MACOSX_DEPLOYMENT_TARGET` explicitly, equal to the app minimum.** The Quick Look extensions once inherited 26.2 from the project level and silently stopped working on older macOS (§5.1).
- **CSV/TSV export:** quote fields that contain the delimiter, quotes, `\n` or `\r`. Text cells starting with `=`, `+`, `-` or `@` get a leading `'` (metric number columns don't).
- No secrets, passwords or personal data in the repo; it is public.


## Correctness

- **Renders and metrics stay byte-identical** unless the change is an agreed behaviour change (master-plan step 13). Check with `scripts/run-render-tests.sh` and `scripts/metric-baselines.py`.
- **Behaviour stays the same** unless a change is agreed first. Collect behaviour changes and ask; don't slip them into a refactor.
- **Concurrency:**
  - Every spawned `Task` has an owner that can cancel it.
  - A result that arrives after a newer request is dropped; use a generation or ID check.
  - Check cancellation after long awaits.
  - No `@unchecked Sendable` to silence a warning.
  - No pointer escapes from `withUnsafe…` closures.
  - No new warnings with `SWIFT_STRICT_CONCURRENCY=complete`. The four known ones are listed in `CODE_AUDIT.md` §3.3 and fixed in master-plan step 7.
- **Compute header-derived facts once** (filter name, filter group, Bayer pattern) when the headers arrive, and store them on the entry. Don't re-parse headers on every access (§7.5).
- **Metal:** the CPU fallback must give the same result as the GPU path. A command-buffer error falls back to the CPU instead of returning garbage.


## SwiftUI performance

- **Large views must not read fast-changing state.** The sidebar, thumbnail grid and session chart should not read `selectedEntry` or other per-keypress state. Pass small values (an ID, a Bool) to the leaf views that need them (P1).
- **No O(n) work in `body`.** Don't filter, group, sort or parse headers there; derive the result once when its inputs change (P2, P3).
- **No model writes on every scroll or gesture frame,** and no animated `scrollTo` on every key press (P4, P5).
- Image decoding and resizing stay off the main thread (P6).
- For significant changes, state the expected performance impact and whether Metal is worth it, and measure with `BenchmarkTests` when performance is the goal.


## Testing

- Unit tests use Swift Testing. New parsing code gets malformed-input tests (§5.20).
- **Checks before a commit that touches code:** unit tests, render tests and metric baselines. SwiftLint must be clean if it is installed.
- **VM tests check what the user sees,** not only that files exist. For example: Quick Look extensions registered (`pluginkit`) and producing a thumbnail (`qlmanage -t`) on every supported macOS version. See `docs/internal/testing.md`.
- Local `xcodebuild` test builds are coverage-instrumented; scripts pass `ENABLE_CODE_COVERAGE=NO` where the output is compared.


## Workflow

- Plan before implementing. After presenting a plan, wait for an explicit go-ahead.
- Update `CHANGELOG.md` with every commit; `site/changelog.html` only at release time.
- Commit or push only when asked. Never create or push a tag without asking: tags publish releases.
- Internal reports and plans go in `docs/internal/`; user-facing docs in `docs/public/`.
