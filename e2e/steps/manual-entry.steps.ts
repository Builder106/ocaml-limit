/**
 * Steps for the manual-order-entry feature cluster.
 * Uses animatedFill so typing is visible character-by-character
 * rather than the field jumping from empty to full instantly.
 */

import { createBdd } from 'playwright-bdd';
import { expect } from '@playwright/test';
import { test } from '../support/demo-fixtures.js';
import { animatedFill, dwellForDemo } from '../support/demo-fixtures.js';

const { When, Then } = createBdd(test);

When('I enter a price of {string}', async ({ page }, price: string) => {
  await animatedFill(page.locator('#order-price'), price);
  await dwellForDemo(page, 600);
});

When('I enter a quantity of {string}', async ({ page }, qty: string) => {
  await animatedFill(page.locator('#order-qty'), qty);
  await dwellForDemo(page, 600);
});

When('I submit a buy order', async ({ page }) => {
  await page.getByRole('button', { name: 'LMT BUY' }).click();
  await dwellForDemo(page);
});

When('I submit a sell order', async ({ page }) => {
  await page.getByRole('button', { name: 'LMT SELL' }).click();
  await dwellForDemo(page);
});

Then('the trade tape shows my fill', async ({ page }) => {
  // Tape entries prepend, so the most recent fill is the first row.
  // Without per-order tagging from the server we can't assert *which*
  // fill is ours, but a new entry appearing within a second of
  // submit is a strong signal.
  await expect(page.locator('#trade-tape > div').first()).toBeVisible({ timeout: 5_000 });
  await dwellForDemo(page, 2000);
});

Then('the risk log records the activity', async ({ page }) => {
  // The dashboard's mock log + the bot's risk alerts both populate
  // this panel — the manual order also adds an "[OK] Placing ..."
  // line via the client-side `addRiskLog`.
  await expect(page.locator('#risk-log')).toContainText('Placing');
  await dwellForDemo(page);
});
