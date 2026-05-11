/**
 * Demo-mode setup: cursor injection, animated typing helper, dwell,
 * default theme pin.
 *
 * The Playwright-BDD test fixture is extended so every page:
 *   1. Has a visible cursor dot following mouse events (headless
 *      hides the system cursor; without this, viewers can't see
 *      where the test is "looking").
 *   2. Has `localStorage.theme = 'dark'` pre-set so demos boot in the
 *      brand aesthetic without depending on the host OS preference.
 *      Individual scenarios that need a different starting state
 *      override via the localStorage steps.
 *
 * Step files import `animatedFill` and `dwellForDemo` directly for
 * the per-keystroke typing animation and explicit narrative pauses.
 * (slowMo only fires between *Playwright actions* — it doesn't cover
 * `page.goto()` or `expect().toBeVisible()`, so modals would
 * otherwise flash on screen.)
 */

import { test as base, type Page, type Locator } from '@playwright/test';

const TYPE_DELAY = Number(process.env.DEMO_TYPE_DELAY ?? 70);

// ────────────────────────────────────────────────────────────────────
// 2. Init scripts injected on every page navigation. Defined as a
//    single string so they execute together before any user JS.
// ────────────────────────────────────────────────────────────────────
const CURSOR_AND_THEME_INIT = `
  // Pin the dashboard to dark mode by default so demos look
  // consistent regardless of OS pref. Individual scenarios override.
  if (!localStorage.getItem('theme')) {
    localStorage.setItem('theme', 'dark');
  }

  // Inject a visible cursor dot that follows mouse events.
  // Headless mode hides the system cursor; without this, viewers
  // can't see where actions are happening.
  const installCursor = () => {
    if (document.querySelector('#__demo_cursor')) return;
    const dot = document.createElement('div');
    dot.id = '__demo_cursor';
    dot.setAttribute('style', \`
      position: fixed;
      z-index: 2147483647;
      width: 22px; height: 22px;
      border-radius: 50%;
      background: rgba(0, 240, 255, 0.85);
      box-shadow: 0 0 0 3px rgba(0, 240, 255, 0.25),
                  0 0 18px rgba(0, 240, 255, 0.6);
      pointer-events: none;
      transform: translate(-50%, -50%);
      transition: transform 80ms linear;
      left: 0; top: 0;
    \`);
    document.body.appendChild(dot);
    document.addEventListener('mousemove', (e) => {
      dot.style.left = e.clientX + 'px';
      dot.style.top  = e.clientY + 'px';
    }, { passive: true });
    document.addEventListener('mousedown', () => {
      dot.style.transform = 'translate(-50%, -50%) scale(0.7)';
    });
    document.addEventListener('mouseup', () => {
      dot.style.transform = 'translate(-50%, -50%)';
    });
  };
  if (document.body) installCursor();
  else document.addEventListener('DOMContentLoaded', installCursor);
`;

// ────────────────────────────────────────────────────────────────────
// 3. dwellForDemo — explicit pause at narrative beats. slowMo only
//    fires between *Playwright actions*; goto() and toBeVisible()
//    resolve instantly. Without dwells, modals "flash" on screen.
// ────────────────────────────────────────────────────────────────────
export async function dwellForDemo(page: Page, ms?: number): Promise<void> {
  if (process.env.DEMO !== '1') return;
  const duration = ms ?? Number(process.env.DEMO_DWELL_MS ?? 1500);
  try {
    await page.waitForTimeout(duration);
  } catch {
    /* page may have closed already; that's fine */
  }
}

// ────────────────────────────────────────────────────────────────────
// 4. Animated fill — applied per-call rather than via prototype
//    patching (cleaner than the module-load patch above, easier to
//    debug). Use this instead of locator.fill() in steps.
// ────────────────────────────────────────────────────────────────────
export async function animatedFill(locator: Locator, value: string): Promise<void> {
  await locator.click();
  await locator.fill('');
  await locator.pressSequentially(value, { delay: TYPE_DELAY });
}

// ────────────────────────────────────────────────────────────────────
// 5. The extended test object — wires init scripts onto every page
//    and exposes the helpers to step definitions.
// ────────────────────────────────────────────────────────────────────
export type DemoFixtures = {
  // No additional fixtures beyond the patched page object — the
  // helpers are imported directly above.
};

export const test = base.extend<DemoFixtures>({
  page: async ({ page }, use) => {
    await page.addInitScript({ content: CURSOR_AND_THEME_INIT });
    await use(page);
    // Hold the final frame so the end-state of the scenario reads as
    // a still. Try/catch because the page may already be closed.
    const tail = Number(process.env.DEMO_TAIL_MS ?? 1500);
    try { await page.waitForTimeout(tail); } catch { /* ignore */ }
  },
});

export { expect } from '@playwright/test';
