/**
 * Steps for the theme-toggle feature cluster. The demo cycles
 * through all three modes (system → light → dark) so the viewer
 * sees both palettes plus the OS-tracking state.
 */

import { createBdd } from 'playwright-bdd';
import { expect } from '@playwright/test';
import { test } from '../support/demo-fixtures.js';
import { dwellForDemo } from '../support/demo-fixtures.js';

const { Given, When, Then } = createBdd(test);

Given('I start with the {string} theme', async ({ page }, theme: string) => {
  // Override the fixture's default-dark pin for this scenario.
  await page.addInitScript((t) => {
    localStorage.setItem('theme', t);
  }, theme);
});

When('I click the theme toggle', async ({ page }) => {
  await page.getByRole('button', { name: 'Cycle theme' }).click();
  await dwellForDemo(page, 2000);
});

Then('the dashboard is in {string} mode', async ({ page }, theme: string) => {
  // The boot script writes the resolved mode to <html data-theme="…">,
  // which is the cleanest read for current state.
  await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
  await dwellForDemo(page);
});

Then('the choice persists in storage', async ({ page }) => {
  const stored = await page.evaluate(() => localStorage.getItem('theme'));
  expect(['system', 'light', 'dark']).toContain(stored);
});
