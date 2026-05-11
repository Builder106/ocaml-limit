/**
 * Custom demo reporter — handles three Playwright quirks documented
 * in the project's E2E conventions:
 *
 *   1. `onTestEnd` fires before the video file is guaranteed flushed.
 *      Collect attachments in onTestEnd, do the heavy work in onEnd.
 *
 *   2. Single-worker + slowMo + `video: 'on'` produces one 0-byte
 *      webm in an early slot. Two warmup scenarios at the top of the
 *      feature list absorb that. We identify them by slug prefix
 *      (`00-warmup-`) and discard their output silently.
 *
 *   3. ffmpeg fed a 0-byte input emits a confusing error. Skip via
 *      `statSync` before invocation.
 *
 * Final outputs land in `demo-output/<feature>-<scenario>.mp4`.
 */

import type { Reporter, TestCase, TestResult, FullResult } from '@playwright/test/reporter';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, renameSync, rmSync, statSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OUTPUT_DIR = path.resolve(__dirname, '../demo-output');

type Pending = {
  slug: string;
  sourcePath: string;
};

function slugify(title: string): string {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/(^-|-$)/g, '');
}

export default class DemoReporter implements Reporter {
  private pending: Pending[] = [];

  onTestEnd(test: TestCase, result: TestResult) {
    // Filename = feature slug only (e.g. `01-core`). Each .feature
    // holds exactly one scenario, so the scenario name would just be
    // redundant; the README references `assets/demos/<feature>.gif`.
    const generatedSpec = path.basename(test.location.file);
    const featureSlug = slugify(
      generatedSpec.replace(/\.spec\.(js|ts)$/, '').replace(/\.feature$/, '')
    );

    const video = result.attachments.find((a) => a.name === 'video');
    if (!video?.path) return;

    this.pending.push({ slug: featureSlug, sourcePath: video.path });
  }

  async onEnd(_result: FullResult) {
    if (this.pending.length === 0) return;

    mkdirSync(OUTPUT_DIR, { recursive: true });

    for (const { slug, sourcePath } of this.pending) {
      // Skip the warmup videos — they exist only to dodge the
      // 0-byte first-video bug, no one wants to watch them.
      if (slug.startsWith('00-warmup-')) {
        safeUnlink(sourcePath);
        safeRmdir(path.dirname(sourcePath));
        continue;
      }

      // Guard against the 0-byte case — Playwright sometimes still
      // emits one even with the warmup workaround, and ffmpeg's error
      // message is more obscure than this skip.
      if (!existsSync(sourcePath) || statSync(sourcePath).size === 0) {
        console.warn(`[demo-reporter] skipping 0-byte video for ${slug}`);
        safeUnlink(sourcePath);
        safeRmdir(path.dirname(sourcePath));
        continue;
      }

      const outMp4 = path.join(OUTPUT_DIR, `${slug}.mp4`);

      try {
        execFileSync('ffmpeg', [
          '-y',
          '-i', sourcePath,
          '-c:v', 'libx264',
          '-preset', 'veryfast',
          '-pix_fmt', 'yuv420p',
          '-movflags', '+faststart',
          outMp4,
        ], { stdio: ['ignore', 'ignore', 'pipe'] });

        // Conversion succeeded; remove the source webm + its per-test
        // folder so test-results/ doesn't accumulate.
        safeUnlink(sourcePath);
        safeRmdir(path.dirname(sourcePath));
        console.log(`[demo-reporter] wrote ${path.relative(process.cwd(), outMp4)}`);
      } catch (err) {
        console.error(`[demo-reporter] ffmpeg failed on ${slug}: ${(err as Error).message}`);
      }
    }
  }
}

function safeUnlink(p: string) {
  try { unlinkSync(p); } catch { /* already gone */ }
}

function safeRmdir(p: string) {
  try { rmSync(p, { recursive: true, force: true }); } catch { /* ignore */ }
}
