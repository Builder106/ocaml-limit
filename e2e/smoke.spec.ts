import { test, expect } from '@playwright/test';

type Feed = { push(msg: unknown): void };

test('seeded SSE book, fills, and order ticket', async ({ page }) => {
  const problems: string[] = [];
  page.on('console', (msg) => {
    if (msg.type() === 'warning' || msg.type() === 'error') problems.push(msg.text());
  });
  page.on('pageerror', (err) => problems.push(err.message));

  await page.addInitScript(() => {
    class SeededEventSource {
      static readonly CLOSED = 2;
      readyState = 1;
      onmessage: ((event: MessageEvent<string>) => void) | null = null;
      onerror: (() => void) | null = null;
      constructor(readonly url: string) {
        (window as unknown as { feed: Feed }).feed = {
          push: (msg: unknown) => this.onmessage?.({ data: JSON.stringify(msg) } as MessageEvent<string>),
        };
      }
      close(): void {}
    }
    Object.defineProperty(window, 'EventSource', { value: SeededEventSource });
  });
  // The delay makes this response arrive after the next book frame would
  // arrive on a slow network.
  await page.route('**/order', async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ status: 'ok', id: 7, filled: 0, resting: 100 }),
    });
  });
  await page.goto('/');

  const push = (msg: unknown) => page.evaluate((m) => (window as unknown as { feed: Feed }).feed.push(m), msg);
  const book = (bidOrders: [number, number][]) => ({
    type: 'BOOK',
    asks: [{ price: 1_500_100, qty: 4, count: 1, orders: [[1_000_000_001, 4]] }],
    bids: [{ price: 1_499_900, qty: bidOrders.reduce((s, [, q]) => s + q, 0), count: bidOrders.length, orders: bidOrders }],
  });

  await push(book([[1_000_000_002, 7]]));
  await push({ type: 'STATS', orders: 12, trades: 3, volume: 90, rejected: 0, last: 1_500_000, viewers: 1, host_mops: 21.4, host_bytes_per_order: 0.03 });
  await push({ type: 'TRADE', side: 'BUY', price: 1_500_100, qty: 5, passive: 1_000_000_001, active: 1_000_000_003, t: 1_700_000_000 });

  await expect(page.locator('#feed')).toHaveText('Live');
  await expect(page.locator('#ladder .level')).toHaveCount(21);
  await expect(page.locator('#ladder .level[data-side="ask"]')).toHaveCount(1);
  await expect(page.locator('#ladder .level[data-side="bid"] .ord')).toHaveCount(1);
  await expect(page.locator('#ladder .level.inside')).toHaveCount(3);
  await expect(page.locator('#q-spread')).toHaveText('0.0200');
  await expect(page.locator('#h-mops')).toHaveText('21.4M orders/s');
  await expect(page.locator('#tape tr')).toHaveCount(1);
  await expect(page.locator('#price')).toHaveValue('150.0000');

  const order = page.waitForRequest((request) => request.url().endsWith('/order'));
  await page.getByRole('button', { name: 'Send <GO>' }).click();
  const sent = await order;
  expect(sent.method()).toBe('POST');
  expect(sent.postDataJSON()).toEqual({ side: 'BUY', price: 1_500_000, qty: 100 });

  await expect(page.locator('#ticket-status')).toContainText('#7 Buy sent');
  await push(book([[1_000_000_002, 7], [7, 100]]));
  await expect(page.locator('#ticket-status')).toContainText('2nd in line at 149.9900');
  await expect(page.locator('#ladder .ord.mine')).toHaveCount(1);

  expect(problems).toEqual([]);
});
