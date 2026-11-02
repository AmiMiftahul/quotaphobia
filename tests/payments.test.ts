// Run with: node --test tests/payments.test.ts
import assert from "node:assert/strict";
import { test } from "node:test";
import { createOrder, expectedSignature, handleNotification, mapStatus, midtransClient } from "../supabase/functions/_shared/payments.ts";
import type { Database, Midtrans, MidtransStatus, Order } from "../supabase/functions/_shared/payments.ts";

const KEY = "test-server-key";

// Behaves like apply_payment in store_schema.sql.
function fakes(status: Partial<MidtransStatus> = {}) {
  const orders = new Map<string, Order>();
  const owned = new Map<string, string>();
  const calls = { charges: 0 };
  let current: MidtransStatus = { transaction_status: "settlement", transaction_id: "tx1", gross_amount: "15000.00", ...status };
  let chargeFails = false;
  const db: Database = {
    async getProduct(id) {
      return id === "skin" ? { id, name: "Skin", price_idr: 15000, active: true } : id === "old" ? { id, name: "Old", price_idr: 1, active: false } : null;
    },
    async ownsProduct(player, product) { return owned.has(`${player}/${product}`); },
    async countRecentPending(player) { return [...orders.values()].filter((o) => o.player_id === player && o.status === "pending").length; },
    async insertOrder(order) { orders.set(order.order_id, { ...order }); },
    async closeOrderAsFailed(id) { orders.get(id)!.status = "failed"; },
    async getOrder(id) { return orders.get(id) ?? null; },
    async applyPayment(id, newStatus) {
      const order = orders.get(id)!;
      const key = `${order.player_id}/${order.product_id}`;
      if (newStatus === "paid") {
        if (["paid", "paid_duplicate", "refunded"].includes(order.status)) return "no_change";
        if (owned.has(key)) { order.status = "paid_duplicate"; return "duplicate"; }
        owned.set(key, id);
        order.status = "paid";
        return "granted";
      }
      if (newStatus === "refunded") {
        if (owned.get(key) === id) owned.delete(key);
        order.status = "refunded";
        return "refunded";
      }
      if (order.status === "pending") order.status = newStatus;
      return "closed";
    },
  };
  const midtrans: Midtrans = {
    async chargeQris() {
      calls.charges++;
      if (chargeFails) throw new Error("down");
      return { transactionId: "tx1", qrUrl: "https://example.test/qr.png" };
    },
    async getStatus() { return current; },
  };
  return {
    db, midtrans, orders, owned, calls,
    setStatus(next: Partial<MidtransStatus>) { current = { ...current, ...next }; },
    failCharges() { chargeFails = true; },
  };
}

let nextId = 0;
const newId = () => `ss-${++nextId}`;

async function signed(orderId: string, statusCode = "200", grossAmount = "15000.00", extra = {}) {
  return {
    order_id: orderId, status_code: statusCode, gross_amount: grossAmount,
    signature_key: await expectedSignature(orderId, statusCode, grossAmount, KEY), ...extra,
  };
}

async function placeOrder(f: ReturnType<typeof fakes>, player = "p1") {
  const result = await createOrder(f.db, f.midtrans, player, "skin", newId);
  assert.equal(result.status, 200);
  return result.body.order_id as string;
}

test("buying uses the database's price and returns a QR code", async () => {
  const f = fakes();
  const result = await createOrder(f.db, f.midtrans, "p1", "skin", newId);
  assert.equal(result.body.amount_idr, 15000);
  assert.equal(result.body.qr_url, "https://example.test/qr.png");
  assert.equal(f.owned.size, 0, "nothing is unlocked before payment");
});

test("items not for sale, and bad requests, are refused without charging", async () => {
  const f = fakes();
  assert.equal((await createOrder(f.db, f.midtrans, "p1", "nope", newId)).status, 404);
  assert.equal((await createOrder(f.db, f.midtrans, "p1", "old", newId)).status, 404);
  assert.equal((await createOrder(f.db, f.midtrans, "p1", 42, newId)).status, 400);
  assert.equal(f.calls.charges, 0);
});

test("a failed charge closes the order and says the player wasn't charged", async () => {
  const f = fakes();
  f.failCharges();
  const result = await createOrder(f.db, f.midtrans, "p1", "skin", newId);
  assert.equal(result.status, 502);
  assert.equal([...f.orders.values()][0].status, "failed");
});

test("too many unpaid orders are refused", async () => {
  const f = fakes();
  for (let i = 0; i < 5; i++) await placeOrder(f);
  assert.equal((await createOrder(f.db, f.midtrans, "p1", "skin", newId)).status, 429);
});

test("a real settlement unlocks the item", async () => {
  const f = fakes();
  const id = await placeOrder(f);
  const result = await handleNotification(f.db, f.midtrans, KEY, await signed(id));
  assert.deepEqual(result, { status: 200, body: { result: "granted" } });
  assert.equal(f.owned.get("p1/skin"), id);
});

test("a forged notification unlocks nothing", async () => {
  const f = fakes();
  const id = await placeOrder(f);
  const forged = await signed(id);
  forged.signature_key = await expectedSignature(id, "200", "15000.00", "attacker-guess");
  assert.equal((await handleNotification(f.db, f.midtrans, KEY, forged)).status, 403);
  assert.equal(f.owned.size, 0);
});

test("a validly signed notice claiming payment is not believed if Midtrans says pending", async () => {
  const f = fakes({ transaction_status: "pending" });
  const id = await placeOrder(f);
  const result = await handleNotification(f.db, f.midtrans, KEY, await signed(id));
  assert.equal(result.body.result, "no_change");
  assert.equal(f.owned.size, 0);
});

test("a wrong amount unlocks nothing", async () => {
  const f = fakes({ gross_amount: "1.00" });
  const id = await placeOrder(f);
  const result = await handleNotification(f.db, f.midtrans, KEY, await signed(id));
  assert.equal(result.body.result, "amount_mismatch");
  assert.equal(f.owned.size, 0);
});

test("duplicate notifications are harmless", async () => {
  const f = fakes();
  const id = await placeOrder(f);
  await handleNotification(f.db, f.midtrans, KEY, await signed(id));
  const again = await handleNotification(f.db, f.midtrans, KEY, await signed(id));
  assert.equal(again.body.result, "no_change");
  assert.equal(f.owned.size, 1);
});

test("paying twice through two open QR codes is flagged for a refund", async () => {
  const f = fakes();
  const first = await placeOrder(f);
  const second = await placeOrder(f);
  await handleNotification(f.db, f.midtrans, KEY, await signed(first));
  const result = await handleNotification(f.db, f.midtrans, KEY, await signed(second));
  assert.equal(result.body.result, "duplicate");
  assert.equal(f.orders.get(second)!.status, "paid_duplicate");
});

test("a late payment on an expired order still unlocks, because the money arrived", async () => {
  const f = fakes({ transaction_status: "expire" });
  const id = await placeOrder(f);
  await handleNotification(f.db, f.midtrans, KEY, await signed(id, "202"));
  assert.equal(f.orders.get(id)!.status, "expired");
  f.setStatus({ transaction_status: "settlement" });
  await handleNotification(f.db, f.midtrans, KEY, await signed(id));
  assert.equal(f.orders.get(id)!.status, "paid");
  assert.equal(f.owned.size, 1);
});

test("a refund takes the item back", async () => {
  const f = fakes();
  const id = await placeOrder(f);
  await handleNotification(f.db, f.midtrans, KEY, await signed(id));
  f.setStatus({ transaction_status: "refund" });
  await handleNotification(f.db, f.midtrans, KEY, await signed(id));
  assert.equal(f.owned.size, 0);
  assert.equal(f.orders.get(id)!.status, "refunded");
});

test("a temporary failure asks Midtrans to retry, and made-up orders don't", async () => {
  const f = fakes();
  const id = await placeOrder(f);
  f.midtrans.getStatus = async () => { throw new Error("network"); };
  assert.equal((await handleNotification(f.db, f.midtrans, KEY, await signed(id))).status, 503);
  assert.equal(f.owned.size, 0);
  assert.equal((await handleNotification(f.db, f.midtrans, KEY, await signed("made-up"))).status, 200);
  assert.equal((await handleNotification(f.db, f.midtrans, KEY, { nonsense: true })).status, 400);
  assert.equal((await handleNotification(f.db, f.midtrans, KEY, null)).status, 400);
});

test("statuses map correctly, including card fraud checks", () => {
  const base = { transaction_id: "t", gross_amount: "1" };
  assert.equal(mapStatus({ ...base, transaction_status: "settlement" }), "paid");
  assert.equal(mapStatus({ ...base, transaction_status: "capture", fraud_status: "accept" }), "paid");
  assert.equal(mapStatus({ ...base, transaction_status: "capture", fraud_status: "challenge" }), null);
  assert.equal(mapStatus({ ...base, transaction_status: "pending" }), null);
  assert.equal(mapStatus({ ...base, transaction_status: "partial_refund" }), null);
});

test("the Midtrans request has the documented shape, and defaults to the test server", async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const fetcher = (async (url: string, init: RequestInit) => {
    seen.push({ url, init });
    return new Response(JSON.stringify({
      status_code: "201", transaction_id: "tx9",
      actions: [{ name: "generate-qr-code-v2", url: "https://x/v2.png" }, { name: "generate-qr-code", url: "https://x/qr.png" }],
    }));
  }) as typeof fetch;
  const client = midtransClient("key", false, fetcher);
  const charge = await client.chargeQris({ order_id: "o1", player_id: "p", product_id: "skin", amount_idr: 15000, status: "pending" }, "Skin");
  assert.equal(charge.qrUrl, "https://x/qr.png");
  assert.equal(seen[0].url, "https://api.sandbox.midtrans.com/v2/charge");
  const headers = seen[0].init.headers as Record<string, string>;
  assert.equal(headers.Authorization, "Basic " + btoa("key:"));
  const body = JSON.parse(seen[0].init.body as string);
  assert.equal(body.payment_type, "qris");
  assert.deepEqual(body.transaction_details, { order_id: "o1", gross_amount: 15000 });
  assert.equal(body.qris.acquirer, "gopay");

  const live = midtransClient("key", true, fetcher);
  await live.chargeQris({ order_id: "o2", player_id: "p", product_id: "skin", amount_idr: 15000, status: "pending" }, "Skin");
  assert.equal(seen[1].url, "https://api.midtrans.com/v2/charge");
});
