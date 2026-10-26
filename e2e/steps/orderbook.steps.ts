/**
 * Steps for the price ladder and the "How it works" dialog.
 */

import { createBdd } from 'playwright-bdd';
import { expect } from '@playwright/test';
import { test } from '../support/demo-fixtures.js';
import { dwellForDemo } from '../support/demo-fixtures.js';

const { When, Then } = createBdd(test);

Then('the ladder fills with bids and asks', async ({ page }) => {
  await expect(page.locator('#ladder .level[data-side="bid"] .ord').first()).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('#ladder .level[data-side="ask"] .ord').first()).toBeVisible({ timeout: 15_000 });
  await dwellForDemo(page, 2000);
});

Then('the explanation opens', async ({ page }) => {
  const dialog = page.getByRole('dialog', { name: 'How it works' });
  await expect(dialog).toBeVisible();
  await expect(dialog).toContainText('Each row is a queue.');
  await dwellForDemo(page, 4000);   // hold so viewers can read it
});

When('I close the explanation', async ({ page }) => {
  await page.getByRole('button', { name: 'Close' }).click();
  await dwellForDemo(page);
});

Then('the book is in view again', async ({ page }) => {
  await expect(page.getByRole('dialog')).toBeHidden();
  await dwellForDemo(page);
});
