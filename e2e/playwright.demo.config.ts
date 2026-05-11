/**
 * Playwright config for the DEMO suite — produces narrative
 * walkthroughs for the README. Distinct from a QA suite (which this
 * project doesn't have yet): demo videos prioritize visibility +
 * pacing over assertion density.
 *
 * Key knobs (all overridable via env vars):
 *   DEMO_URL        target (default: production)
 *   DEMO_SLOWMO     per-action pause in ms (default: 1200)
 *   DEMO_TAIL_MS    hold-final-frame at end of each scenario (default: 1500)
 *   DEMO_DWELL_MS   default dwellForDemo duration (default: 1500)
 *   DEMO_TYPE_DELAY per-char delay for animated typing (default: 70)
 *   DEMO_ZOOM       CSS zoom factor on <html> (default: 1.3)
 */

import { defineConfig, devices } from '@playwright/test';
import { defineBddConfig } from 'playwright-bdd';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// playwright-bdd v7 uses `paths` for feature files and `require` for
// step / support module globs. (v8 renamed these to `features` /
// `steps`; we pin v7 in package.json for stability.) Paths are
// relative to this config file.
const testDir = defineBddConfig({
  paths: ['demo/features/*.feature'],
  require: ['steps/**/*.ts', 'support/**/*.ts'],
  outputDir: path.join(__dirname, '.features-gen/demo'),
});

const slowMo = Number(process.env.DEMO_SLOWMO ?? 1200);

export default defineConfig({
  testDir,
  timeout: 180_000,           // demo scenarios are long-running (slowMo + dwells)
  fullyParallel: false,       // single-worker; see "0-byte first-test bug" note
  workers: 1,
  retries: 0,                 // re-runs would record over the previous video
  reporter: [
    ['list'],
    [path.join(__dirname, 'reporter/demo-reporter.ts')],
  ],

  use: {
    baseURL: process.env.DEMO_URL ?? 'https://ocaml-lob.duckdns.org/',
    headless: true,           // still records video; saves a window
    // Recording at 1440x900 (was 2560x1600). The output GIF lands at
    // 1280px wide, so 1440 source gives a clean 1.12× downscale and
    // a crisp display on Retina at GitHub's ~890 CSS-px column
    // width. The previous 2560 source was downscaled 2.67× into a
    // 960px GIF — visibly blurry on Retina, and the GIF was right
    // up against GitHub's 10 MB inline-image cap.
    viewport: { width: 1440, height: 900 },
    video: {
      mode: 'on',
      size: { width: 1440, height: 900 },
    },
    launchOptions: { slowMo },
    actionTimeout: 15_000,
  },

  projects: [
    {
      name: 'chromium',
      use: {
        // Re-pin viewport at the project level — the device preset
        // overrides the top-level `use` block silently otherwise.
        ...devices['Desktop Chrome'],
        viewport: { width: 1440, height: 900 },
        video: {
          mode: 'on',
          size: { width: 1440, height: 900 },
        },
      },
    },
  ],
});
