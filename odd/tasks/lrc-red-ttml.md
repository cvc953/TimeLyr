# Feature: lrc.red TTML support

## Objective

Add lrc.red (https://lrc.red/api) as a native TTML source in TimeLyr, preferred over the
existing Lyrics+ / KPoE mirrors, while preserving the current fallback chain.

## Problem

TimeLyr downloads TTML through the Lyrics+ (KPoE) mirrors. Those mirrors are unstable and
BiniLyrics already redirects to lrc.red. lrc.red exposes a documented, free API with
line/word/syllable TTML and a search endpoint, so it should be a first-class source.

## Scope

- New `LrcRedService` with search, metadata parsing, ranking, TTML download and polite
  request throttling.
- Integrate lrc.red into `FileService.saveTTMLForSong` as the preferred TTML source.
- Keep Lyrics+ (KPoE) as fallback when lrc.red has no match or fails.
- Save lrc.red TTML verbatim (it is already well-formed) and derive line-level LRC only
  when the song has no `.lrc`, so the in-app viewer keeps working.
- Fix TTML text extraction so adjacent syllable spans do not gain artificial spaces
  (`be`+`fore`, `an`+`gel`). This is required for lrc.red TTML and also improves KPoE CJK.
- Add unit tests for lrc.red JSON parsing/ranking and for lrc.red-style TTML to LRC.
- Credit lrc.red in the About screen and README (API terms require attribution + link).

Out of scope: manual search UI for lrc.red, cover art download, lrc.red `sync` endpoint.

## Constraints

- No new dependencies.
- lrc.red terms: send a descriptive `User-Agent` with app name + link + contact, throttle
  requests, and credit/link lrc.red wherever its data is shown.
- Do not break the Lyrics+ fallback or existing LRC saves.
- Existing project UI language is Spanish; keep user-facing strings in Spanish.

## Tasks

| ID | Task | Route | Acceptance | Checks |
| --- | --- | --- | --- | --- |
| T1 | Create `lib/services/lrc_red_service.dart` with `LrcRedTrack`, `search`, `selectBest`, `fetchTtml`, `fetchTtmlForSong`, UA + throttle + typed network errors | delegated | Search hits parse; best match rejects unrelated tracks; TTML fetched by ISRC | Unit tests for parsing/ranking |
| T2 | Integrate lrc.red first in `FileService.saveTTMLForSong`; save verbatim; derive LRC if missing; parameterize source tags; keep KPoE fallback | delegated | lrc.red match saves `.ttml`; no match falls back to KPoE; no duplicate LRC writes | Structural readback + tests |
| T3 | Fix `_ttmlInnerToPlainText` to remove tags without inserting spaces | delegated | `be`+`fore` → `before`; existing spaced spans still correct | TTML→LRC unit tests |
| T4 | Add tests in `test/lrc_red_service_test.dart` and extend KPoE TTML tests | delegated | Parsing, ranking, lrc.red TTML text extraction covered | `flutter test` (not available in this environment) |
| T5 | Update About screen and README credits | delegated | lrc.red credited with link | Structural readback |
| T6 | Commit work unit on `feat/lrc-red-ttml` | parent | Conventional commit, no AI attribution | `git show --stat` |

## Acceptance criteria

- A song with no local TTML triggers one lrc.red search plus one TTML request; on success
  the `.ttml` file is written next to the audio file.
- If lrc.red has no confident match, the existing Lyrics+ path still runs.
- lrc.red TTML is not mutated by the KPoE span-space workaround.
- If the song has no `.lrc`, a line-level `.lrc` is derived from the TTML so the viewer shows lyrics.
- lrc.red attribution is visible in About and README.

## Delivery strategy

`ask-on-risk` (default). Forecast: ~380 authored lines across service, integration, tests and docs.
If the running count exceeds ~400 authored lines, ask once before the next commit.

## Progress

- [x] T1 lrc.red service
- [x] T2 FileService integration
- [x] T3 TTML text extraction fix
- [x] T4 Tests
- [x] T5 Credits
- [ ] T6 Work-unit commit

## Evidence / notes

- lrc.red endpoints verified live: `GET /search.json?q=...`, `GET /s/{isrc}.json`,
  `GET /s/{isrc}.ttml`, `GET /s/{isrc}.lrc`.
- lrc.red TTML uses `begin="19.764"` (seconds) and syllable-level adjacent spans with no
  whitespace, so the existing tag-to-space extraction is wrong for it.
- Flutter/Dart SDK is not installed in the current environment; unit tests cannot be run
  here. Static readback is the verification of record unless the toolchain becomes available.
- T1: `LrcRedService` parses search/track JSON defensively, resolves relative URLs, scores
  title/artist/duration, rejects below 0.7, serializes requests with a 200 ms floor and
  12 s timeout, and throws typed `LrcRedNetworkException` on 429/5xx/network/TLS/timeout.
- T2: `saveTTMLForSong` now returns early when a valid TTML exists (deriving a missing LRC),
  then tries lrc.red verbatim (no span mutation) and falls back to KPoE. LRC writes are
  idempotent because they only run when the file is missing.
- T3: `_ttmlInnerToPlainText` removes tags without inserting spaces; callers that need
  separation already carry literal whitespace (KPoE normalization restores it).
- T4: New `test/lrc_red_service_test.dart` covers search/track parsing, ranking, threshold
  rejection and duration scoring; KPoE test covers adjacent-syllable TTML.
- T5: About screen and README credit lrc.red with a link.
- Static checks: delimiter balance on all changed Dart files and `git diff --check` pass.
- Pending: project-wide `flutter test`/`flutter analyze`/`dart format` (SDK unavailable).
