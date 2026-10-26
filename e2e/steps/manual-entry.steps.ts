/**
 * Steps for the manual-order-entry feature.
 * Uses animatedFill so typing is visible character-by-character
 * rather than the field jumping from empty to full instantly.
 */

import { createBdd } from 'playwright-bdd';
import { expect } from '@playwright/test';
import { test } from '../support/demo-fixtures.js';
import { animatedFill, dwellForDemo } from '../support/demo-fixtures.js';

const { When, Then } = createBdd(test);

When('I pick the best bid price', async ({ page }) => {
  // Bids sit below the spread, highest first, so the first bid row is
  // the best bid. Clicking its price loads it into the ticket.
  await page.locator('#ladder .level[data-side="bid"] .px').first().click();
  await dwellForDemo(page, 600);
});

When('I enter a quantity of {string}', async ({ page }, qty: string) => {
  await animatedFill(page.locator('#qty'), qty);
  await dwellForDemo(page, 600);
});

When('I send the order', async ({ page }) => {
  await page.getByRole('button', { name: 'Send <GO>' }).click();
  await dwellForDemo(page);
});

Then('the ticket shows my place in line', async ({ page }) => {
  // The order may also fill outright if the market moves first.
  await expect(page.locator('#ticket-status')).toContainText(/in line|filled/, { timeout: 10_000 });
  await dwellForDemo(page, 2000);
});

Then('my order is outlined in the queue', async ({ page }) => {
  await expect(page.locator('#ladder .ord.mine')).toHaveCount(1, { timeout: 5_000 });
  await dwellForDemo(page, 2000);
});
