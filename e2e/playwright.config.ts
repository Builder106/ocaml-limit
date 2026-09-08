import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: 'smoke.spec.ts',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  reporter: 'list',
  use: { ...devices['Desktop Chrome'], baseURL: 'http://127.0.0.1:4174' },
  webServer: {
    command: 'python3 -m http.server 4174 --directory ../front',
    url: 'http://127.0.0.1:4174/',
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});
