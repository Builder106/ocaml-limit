/**
 * Shared steps used by every feature. Phrased as natural English
 * (not tied to selectors) so step text reads well in narration.
 */

import { createBdd } from 'playwright-bdd';
import { expect } from '@playwright/test';
import { test } from '../support/demo-fixtures.js';
import { dwellForDemo } from '../support/demo-fixtures.js';

const { Given, When, Then } = createBdd(test);

Given('I open the dashboard', async ({ page }) => {
  await page.goto('/');
  // Wait until the boot script + first render have completed so the
  // status header is present. Anchoring on a stable element rather
  // than networkidle, which fires too early on a long-poll SPA.
  await expect(page.getByText('QUANT TERMINAL', { exact: false })).toBeVisible();
  await dwellForDemo(page);
});

Then('the dashboard is connected', async ({ page }) => {
  // The status pill flips from DISCONNECTED to LIVE once the
  // WebSocket handshake completes.
  await expect(page.getByText('LIVE', { exact: true })).toBeVisible({ timeout: 10_000 });
  await dwellForDemo(page);
});

Then('I see the order book panel', async ({ page }) => {
  await expect(page.getByText('Order Book L2', { exact: true })).toBeVisible();
});

Then('I see the liquidity depth chart', async ({ page }) => {
  await expect(page.getByText('Liquidity Depth (DOM)', { exact: true })).toBeVisible();
});

Then('I see the trade tape', async ({ page }) => {
  await expect(page.getByText('Trade Tape (Real-Time)', { exact: true })).toBeVisible();
});

When('I pause for a moment', async ({ page }) => {
  await dwellForDemo(page, 2500);
});

When('I pause for {int} seconds', async ({ page }, secs: number) => {
  await page.waitForTimeout(secs * 1000);
});
