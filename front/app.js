/**
 * OCaml LOB dashboard: one SSE stream from the Dream server, drawn as a
 * book of FIFO queues. Every figure on the page comes from the engine.
 */

// The Dream server also serves this page, so events and order resolve
// against the page's own path there (/ locally, /lob/ through the Funnel).
// On Vercel the server is cross-origin.
const API_BASE = location.hostname.endsWith('.vercel.app')
    ? 'https://econos-kernel.tailcb96b4.ts.net/lob/'
    : '';

// The demo book quotes in steps of 50 ticks ($0.0050).
const TICK_GRID = 50;
const LADDER_HALF = 10;
const TAPE_ROWS = 40;
const RETRY_MS = 5000;

const $ = (id) => document.getElementById(id);
const fmtPx = (ticks) => (ticks / 10_000).toFixed(4);
const fmtN = (n) => n.toLocaleString('en-US');
const ordinal = (n) => {
    const s = ['th', 'st', 'nd', 'rd'];
    const v = n % 100;
    return n + (s[(v - 20) % 10] || s[v] || s[0]);
};
const sideLabel = (side) => (side === 'BUY' ? 'Buy' : 'Sell');

// Orders this browser sent, keyed by engine id.
const mine = new Map();
let lastOrderId = null;
let priceSeeded = false;
let retryTimer = null;
let framesSeen = 0;
let ladderCenter = null;

// ── Feed ────────────────────────────────────────────────────────────

function setFeed(state, label) {
    const el = $('feed');
    if (el.dataset.state === state && el.textContent === label) return;
    el.dataset.state = state;
    el.textContent = label;
    document.querySelector('.book').classList.toggle('stale', state === 'down');
    $('book-state').textContent = state === 'down' ? 'Feed offline, retrying every few seconds' : '';
}

function connect() {
    clearTimeout(retryTimer);
    const es = new EventSource(`${API_BASE}events`);
    es.onopen = () => { framesSeen = 0; };
    es.onmessage = (event) => {
        setFeed('live', 'Live');
        handle(JSON.parse(event.data));
    };
    es.onerror = () => {
        // EventSource retries on its own unless the server answered with
        // a non-stream response, which closes it for good.
        if (es.readyState !== EventSource.CLOSED) {
            setFeed('retry', 'Reconnecting');
            return;
        }
        setFeed('down', 'Offline');
        retryTimer = setTimeout(connect, RETRY_MS);
    };
}

function handle(msg) {
    switch (msg.type) {
        case 'BOOK': framesSeen += 1; renderBook(msg.asks, msg.bids); break;
        case 'STATS': renderStats(msg); break;
        case 'TRADE': addFill(msg); break;
    }
}

// ── Book ────────────────────────────────────────────────────────────

function renderBook(asks, bids) {
    const bestAsk = asks[0];
    const bestBid = bids[0];
    $('q-bid').innerHTML = bestBid ? `<span class="b">${fmtPx(bestBid.price)}</span> x ${fmtN(bestBid.qty)}` : '-';
    $('q-ask').innerHTML = bestAsk ? `<span class="a">${fmtPx(bestAsk.price)}</span> x ${fmtN(bestAsk.qty)}` : '-';
    $('q-spread').textContent = bestAsk && bestBid ? `${fmtPx(bestAsk.price - bestBid.price)}` : '-';

    const mid = bestAsk && bestBid ? (bestAsk.price + bestBid.price) / 2 : (bestAsk || bestBid)?.price;
    if (mid !== undefined) {
        const target = Math.round(mid / TICK_GRID) * TICK_GRID;
        // Recenter only after the mid drifts two rungs, so rows stay put.
        if (ladderCenter === null || Math.abs(target - ladderCenter) >= 2 * TICK_GRID) ladderCenter = target;
        if (!priceSeeded && !$('price').value) {
            $('price').value = fmtPx(target);
            priceSeeded = true;
        }
    }
    if (ladderCenter !== null) renderLadder(asks, bids, bestAsk, bestBid);
    trackMine(asks, bids);
}

// A fixed ladder of prices around the centre, highest first. A price
// keeps its row while the book moves, so only the queues change.
function renderLadder(asks, bids, bestAsk, bestBid) {
    const levels = new Map();
    for (const level of asks) levels.set(level.price, ['ask', level]);
    for (const level of bids) levels.set(level.price, ['bid', level]);
    const prices = [];
    for (let i = LADDER_HALF; i >= -LADDER_HALF; i--) prices.push(ladderCenter + i * TICK_GRID);
    const maxQty = Math.max(1, ...prices.map((p) => levels.get(p)?.[1].qty ?? 0));

    const list = $('ladder');
    const rows = new Map([...list.children].map((li) => [li.dataset.price, li]));
    let prev = null;
    for (const price of prices) {
        const key = String(price);
        let li = rows.get(key);
        if (li) rows.delete(key);
        else li = makeRow(price);
        const [side, level] = levels.get(price) ?? ['', null];
        li.dataset.side = side;
        li.classList.toggle('inside', Boolean(bestAsk && bestBid && price > bestBid.price && price < bestAsk.price));
        li.querySelector('.qty').textContent = level ? fmtN(level.qty) : '';
        li.querySelector('.count').textContent = level ? fmtN(level.count) : '';
        renderQueue(li.querySelector('.queue'), level ? level.orders : [], maxQty);
        const ref = prev ? prev.nextSibling : list.firstChild;
        if (ref !== li) list.insertBefore(li, ref);
        prev = li;
    }
    for (const li of rows.values()) li.remove();
}

function makeRow(price) {
    const li = document.createElement('li');
    li.className = 'level';
    li.dataset.price = String(price);
    li.innerHTML = '<button class="px" type="button"></button><span class="qty"></span><span class="count"></span><div class="queue" aria-hidden="true"></div>';
    const px = li.querySelector('.px');
    px.textContent = fmtPx(price);
    px.setAttribute('aria-label', `Put ${fmtPx(price)} in the ticket`);
    px.addEventListener('click', () => {
        $('price').value = fmtPx(price);
        $('qty').focus();
    });
    return li;
}

// Blocks are keyed by order id so a fill shrinks or removes the block
// that was actually hit, and new orders join at the tail.
function renderQueue(queue, orders, maxQty) {
    const existing = new Map();
    for (const el of queue.children) {
        if (!el.classList.contains('gone')) existing.set(Number(el.dataset.id), el);
    }
    let prev = null;
    for (const [id, qty] of orders) {
        let el = existing.get(id);
        if (el) {
            existing.delete(id);
        } else {
            el = document.createElement('span');
            el.className = 'ord';
            el.dataset.id = String(id);
        }
        el.style.width = `${(qty / maxQty) * 100}%`;
        el.title = `#${id}, ${fmtN(qty)}`;
        el.classList.toggle('mine', mine.has(id));
        const ref = prev ? prev.nextSibling : queue.firstChild;
        if (ref !== el) queue.insertBefore(el, ref);
        prev = el;
    }
    for (const el of existing.values()) {
        el.classList.add('gone');
        setTimeout(() => el.remove(), 320);
    }
}

// ── Your orders ─────────────────────────────────────────────────────

function trackMine(asks, bids) {
    const order = mine.get(lastOrderId);
    if (!order || order.done) return;
    for (const level of order.side === 'BUY' ? bids : asks) {
        const at = level.orders.findIndex(([id]) => id === lastOrderId);
        if (at === -1) continue;
        order.missing = false;
        const [, left] = level.orders[at];
        const filled = order.qty - left;
        showTicket(`<span class="mono">#${lastOrderId}</span> ${sideLabel(order.side)} ${fmtN(left)} resting, ${ordinal(at + 1)} in line at ${fmtPx(level.price)}${filled ? `, ${fmtN(filled)} filled` : ''}`);
        return;
    }
    if (order.filled >= order.qty) {
        order.done = true;
        showTicket(`<span class="mono">#${lastOrderId}</span> ${sideLabel(order.side)} ${fmtN(order.qty)} filled`);
        return;
    }
    // Each frame sends the book before its fills, so an order that just
    // filled is missing for one frame before its fill arrives.
    if (!order.missing) {
        order.missing = true;
        return;
    }
    showTicket(`<span class="mono">#${lastOrderId}</span> ${sideLabel(order.side)} is resting outside the prices shown`);
}

function showTicket(html) {
    $('ticket-status').innerHTML = html;
}

async function submitOrder(event) {
    event.preventDefault();
    const side = new FormData(event.target).get('side');
    const qty = Number.parseInt($('qty').value.replace(/,/g, ''), 10);
    const price = Math.round(Number.parseFloat($('price').value) * 10_000);
    if (!Number.isFinite(qty) || !Number.isFinite(price)) {
        showTicket('Enter a quantity and a price.');
        return;
    }
    $('go').disabled = true;
    try {
        const response = await fetch(`${API_BASE}order`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ side, price, qty }),
        });
        const body = await response.json();
        if (!response.ok || body.status !== 'ok') {
            showTicket(`Not sent: ${body.reason || body.status}`);
            return;
        }
        mine.set(body.id, { side, qty, filled: body.filled, done: false });
        lastOrderId = body.id;
        if (body.resting === 0) {
            mine.get(body.id).done = true;
            showTicket(`<span class="mono">#${body.id}</span> ${sideLabel(side)} ${fmtN(body.filled)} filled on arrival`);
        } else {
            showTicket(`<span class="mono">#${body.id}</span> ${sideLabel(side)} sent, ${fmtN(body.filled)} filled on arrival`);
        }
    } catch {
        showTicket('The engine did not answer. Check the feed state.');
    } finally {
        $('go').disabled = false;
    }
}

// ── Fills and counters ──────────────────────────────────────────────

function addFill(msg) {
    const passive = mine.get(msg.passive);
    if (passive) passive.filled += msg.qty;

    // The server replays recent fills after the first frame of a
    // connection; only flash the ones that arrive after that.
    const live = framesSeen > 1;
    const block = document.querySelector(`.ord[data-id="${msg.passive}"]`);
    if (block && live) {
        block.classList.add('hit');
        setTimeout(() => block.classList.remove('hit'), 360);
    }

    const tape = $('tape');
    const row = document.createElement('tr');
    const time = new Date(msg.t * 1000).toTimeString().slice(0, 8);
    const side = msg.side === 'BUY' ? 'buy' : 'sell';
    const yours = mine.has(msg.active) ? ' (you)' : passive ? ' into yours' : '';
    row.innerHTML = `<td class="t">${time}</td><td>${fmtPx(msg.price)}</td><td>${fmtN(msg.qty)}</td><td class="${side}">${sideLabel(msg.side)}${yours}</td>`;
    if (live) {
        row.className = 'fresh';
        setTimeout(() => row.classList.remove('fresh'), 600);
    }
    tape.prepend(row);
    while (tape.children.length > TAPE_ROWS) tape.lastChild.remove();
}

function renderStats(s) {
    $('q-last').textContent = s.last === null ? '-' : fmtPx(s.last);
    $('q-orders').textContent = fmtN(s.orders);
    $('q-trades').textContent = fmtN(s.trades);
    $('q-volume').textContent = fmtN(s.volume);
    $('q-viewers').textContent = fmtN(s.viewers);
    $('h-mops').textContent = `${s.host_mops.toFixed(1)}M orders/s`;
    $('h-bytes').textContent = `${s.host_bytes_per_order.toFixed(2)} bytes/order`;
}

// ── Menu, keys, clock ───────────────────────────────────────────────

function runKey(key) {
    if (key === '1' || key === '2') {
        document.querySelector(`input[name="side"][value="${key === '1' ? 'BUY' : 'SELL'}"]`).checked = true;
        $('qty').focus();
        $('qty').select();
    } else if (key === '3') {
        $('about').showModal();
    } else if (key === '4') {
        document.querySelector('.menu a[data-key="4"]').click();
    }
}

document.querySelectorAll('.menu button').forEach((b) => {
    b.addEventListener('click', () => runKey(b.dataset.key));
});
document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target instanceof Element && e.target.closest('input, dialog')) return;
    if (['1', '2', '3', '4'].includes(e.key)) runKey(e.key);
});
$('about-close').addEventListener('click', () => $('about').close());
$('about').addEventListener('click', (e) => {
    if (e.target === $('about')) $('about').close();
});
$('ticket').addEventListener('submit', submitOrder);

function tick() {
    $('clock').textContent = new Date().toTimeString().slice(0, 8);
}
tick();
setInterval(tick, 1000);
connect();
