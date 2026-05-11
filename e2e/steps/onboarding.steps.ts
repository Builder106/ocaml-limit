/**
 * Steps for the first-visit onboarding modal.
 */

import { createBdd } from 'playwright-bdd';
import { expect } from '@playwright/test';
import { test } from '../support/demo-fixtures.js';
import { dwellForDemo } from '../support/demo-fixtures.js';

const { Given, When, Then } = createBdd(test);

Given('I am a first-time visitor', async ({ page }) => {
  // Make sure no prior session's onboardingSeen flag suppresses the
  // auto-open. This init script runs *before* the dashboard's boot
  // script, so the modal logic sees a clean slate.
  await page.addInitScript(() => {
    localStorage.removeItem('onboardingSeen');
  });
});

Then('the onboarding modal opens automatically', async ({ page }) => {
  const modal = page.getByRole('dialog');
  await expect(modal).toBeVisible({ timeout: 5_000 });
  await dwellForDemo(page, 3000);   // hold so viewers can read it
});

Then('the modal explains the three headline numbers', async ({ page }) => {
  const modal = page.getByRole('dialog');
  await expect(modal).toContainText('18 M');
  await expect(modal).toContainText('1 μs');
  await expect(modal).toContainText('0 bytes');
  await dwellForDemo(page);
});

When('I click Explore to dismiss', async ({ page }) => {
  await page.getByRole('button', { name: /Explore/i }).click();
  await dwellForDemo(page);
});

Then('the dashboard is unobscured', async ({ page }) => {
  await expect(page.getByRole('dialog')).toBeHidden();
  await dwellForDemo(page);
});

When('I click the info icon in the header', async ({ page }) => {
  await page.getByRole('button', { name: 'Show onboarding' }).click();
  await dwellForDemo(page, 2000);
});

Then('the modal reopens', async ({ page }) => {
  await expect(page.getByRole('dialog')).toBeVisible();
  await dwellForDemo(page);
});
