/**
 * Steps for the live order book + trade tape feature cluster.
 * Mostly observational — the bot is doing the work, we just watch.
 */

import { createBdd } from 'playwright-bdd';
import { expect } from '@playwright/test';
import { test } from '../support/demo-fixtures.js';
import { dwellForDemo } from '../support/demo-fixtures.js';

const { When, Then } = createBdd(test);

Then('the order book populates with bids and asks', async ({ page }) => {
  // The seeded liquidity (15 levels per side) renders immediately.
  // Each row is a `data-row` div under `#ask-book` / `#bid-book`.
  await expect(page.locator('#bid-book .data-row').first()).toBeVisible({ timeout: 10_000 });
  await expect(page.locator('#ask-book .data-row').first()).toBeVisible({ timeout: 10_000 });
  await dwellForDemo(page, 2000);
});

Then('the trade tape starts streaming fills', async ({ page }) => {
  // The bot generates fills at ~1/sec; allow up to 10s for the
  // first one to land.
  const tape = page.locator('#trade-tape > div');
  await expect(tape.first()).toBeVisible({ timeout: 10_000 });
  await dwellForDemo(page);
});

When('I watch the book update for a few seconds', async ({ page }) => {
  // Pure observation — let the bot drive the visuals. ~6s shows
  // multiple trades + depth-chart redraws.
  await page.waitForTimeout(6000);
});
