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
  await expect(page.locator('#ladder')).toBeAttached();
  await dwellForDemo(page);
});

Then('the dashboard is connected', async ({ page }) => {
  // The feed reads "Live" once the first SSE frame arrives.
  await expect(page.locator('#feed')).toHaveText('Live', { timeout: 15_000 });
  await dwellForDemo(page);
});

Then('I see the fills tape', async ({ page }) => {
  await expect(page.locator('#tape tr').first()).toBeVisible({ timeout: 15_000 });
  await dwellForDemo(page);
});

When('I press {string}', async ({ page }, key: string) => {
  await page.keyboard.press(key);
  await dwellForDemo(page);
});

When('I watch the book update for a few seconds', async ({ page }) => {
  // Pure observation: the bot fills and refills the queues.
  await page.waitForTimeout(6000);
});
