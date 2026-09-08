import { test, expect } from '@playwright/test';

test('seeded local SSE snapshot and order boundary', async ({ page }) => {
  await page.addInitScript(() => {
    class SeededEventSource {
      static readonly OPEN = 1;
      readonly readyState = SeededEventSource.OPEN;
      onopen: (() => void) | null = null;
      onmessage: ((event: MessageEvent<string>) => void) | null = null;
      onerror: (() => void) | null = null;
      constructor(readonly url: string) {
        queueMicrotask(() => {
          this.onopen?.();
          this.onmessage?.({ data: JSON.stringify({ type: 'SNAPSHOT', asks: [{ price: 150.5, size: 4, totalSize: 4 }], bids: [{ price: 149.5, size: 7, totalSize: 7 }] }) } as MessageEvent<string>);
          this.onmessage?.({ data: JSON.stringify({ type: 'STATS', latency: '0.50', throughput: '1.00M' }) } as MessageEvent<string>);
        });
      }
      close(): void {}
    }
    class SeededChart {
      data = { datasets: [{ data: [] }, { data: [] }] };
      options = { scales: { x: { grid: {}, ticks: {} }, y: { grid: {}, ticks: {} } } };
      update(): void {}
    }
    Object.defineProperty(window, 'EventSource', { value: SeededEventSource });
    Object.defineProperty(window, 'Chart', { value: SeededChart });
    localStorage.setItem('onboardingSeen', '1');
  });
  const order = page.waitForRequest((request) => request.url().endsWith('/order'));
  await page.route('**/order', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' }));
  await page.goto('/');
  await expect(page.getByText('LIVE', { exact: true })).toBeVisible();
  await expect(page.locator('#ask-book .data-row')).toHaveCount(1);
  await expect(page.locator('#bid-book .data-row')).toHaveCount(1);
  await expect(page.locator('#spread')).toHaveText('1.00');
  await expect(page.locator('#stat-throughput')).toHaveText('1.00M orders/s');
  await page.getByRole('button', { name: 'LMT BUY' }).click();
  expect((await order).method()).toBe('POST');
  await expect(page.locator('#risk-log')).toContainText('Placing BUY order');
});
