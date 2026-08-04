# e2e — demo recording

Playwright + Gherkin pipeline that records narrative walkthroughs of
the dashboard. The mp4s convert to GIFs that the root README embeds
under collapsed `<details>` sections.

## What's here

```
e2e/
├── playwright.demo.config.ts   demo-mode config (slowMo, video on)
├── reporter/demo-reporter.ts   webm → mp4, skips warmups + 0-byte files
├── support/demo-fixtures.ts    cursor injection, dwell helper, animated typing
├── steps/                      step definitions, English-phrased
├── demo/features/              one .feature per cluster (00–04)
└── scripts/to-gifs.sh          two-pass-palette mp4 → gif conversion
```

## One-time setup

```bash
cd e2e
npm install
npm run install:browsers     # downloads Playwright's Chromium build
```

You'll also need `ffmpeg` on `PATH` (the reporter shells out to it for
the webm → mp4 step). `brew install ffmpeg` on macOS.

## Recording

```bash
npm run demo                   # all features, against the live VM
```

By default the demos target `https://ocaml-lob.duckdns.org/`. To
record against a local dev server instead:

```bash
DEMO_URL=http://localhost:8080/ npm run demo
```

Outputs land in `e2e/demo-output/<feature>-<scenario>.mp4`.

Then:

```bash
npm run gifs                   # mp4 → assets/demos/*.gif
```

The README's `<details>` blocks reference `assets/demos/*.gif` —
once those files exist, GitHub renders them inline.

## Tuning knobs

All overridable as env vars:

| Var | Default | What it controls |
| --- | --- | --- |
| `DEMO` | `0` (set to `1` by the `demo` script) | Master switch — fixtures no-op when unset |
| `DEMO_URL` | `https://ocaml-lob.duckdns.org/` | Target |
| `DEMO_SLOWMO` | `1200` | Per-action pause (ms) |
| `DEMO_TYPE_DELAY` | `70` | Per-character delay in `animatedFill` |
| `DEMO_TAIL_MS` | `1500` | Hold-final-frame at end of each scenario |
| `DEMO_DWELL_MS` | `1500` | Default `dwellForDemo()` duration |

Bump `DEMO_SLOWMO` for slower / more readable demos; drop it for
faster iteration when iterating on step definitions.

## Warmups

`00-warmup-a.feature` and `00-warmup-b.feature` exist only to absorb
Playwright's "0-byte first-test video" bug under single-worker +
slowMo + `video: 'on'`. The reporter discards anything whose slug
prefix is `00-warmup-`; don't add real assertions to them.

## Adding a new demo

1. Create `demo/features/0N-<cluster>.feature` (one scenario per
   feature, narrative-style steps).
2. Reuse existing steps if possible — the step library is shared.
   New step phrases go in `steps/<cluster>.steps.ts`.
3. `npm run demo` regenerates everything; `npm run gifs` rebuilds
   the GIFs. Commit the GIFs (they're a few hundred KB each at the
   default 960px / 10 fps).
4. Add a `<details>` block to the root README pointing at the new
   GIF path.

## Steps-as-narration

Step phrases are deliberately English-flavored ("When I submit a
buy order") rather than selector-bound ("When I click
`#order-buy-btn`"). This makes the feature files double as
voiceover scripts — see the project's global CLAUDE.md for the
narration / TTS conventions when you're ready to add audio.
