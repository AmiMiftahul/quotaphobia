// The payment rules, with no ties to any server. The real database and Midtrans
// are passed in, so tests can run these exact rules against fakes.

export type Order = {
  order_id: string;
  player_id: string;
  product_id: string;
  amount_idr: number;
  status: string;
};

export type Product = { id: string; name: string; price_idr: number; active: boolean };

export type Database = {
  getProduct(id: string): Promise<Product | null>;
  ownsProduct(playerId: string, productId: string): Promise<boolean>;
  countRecentPending(playerId: string): Promise<number>;
  insertOrder(order: Order): Promise<void>;
  closeOrderAsFailed(orderId: string): Promise<void>;
  getOrder(orderId: string): Promise<Order | null>;
  applyPayment(orderId: string, status: string, transactionId: string): Promise<string>;
};

export type Midtrans = {
  chargeQris(order: Order, productName: string): Promise<{ transactionId: string; qrUrl: string }>;
  getStatus(orderId: string): Promise<MidtransStatus>;
};

export type MidtransStatus = {
  transaction_status: string;
  transaction_id: string;
  gross_amount: string;
  fraud_status?: string;
};

export type Result = { status: number; body: Record<string, unknown> };

export const MAX_PENDING_ORDERS = 5;
export const QR_MINUTES = 15;

export async function createOrder(
  db: Database,
  midtrans: Midtrans,
  playerId: string,
  productId: unknown,
  newOrderId: () => string,
): Promise<Result> {
  if (typeof productId !== "string") {
    return { status: 400, body: { error: "Missing product." } };
  }
  // The price always comes from our database, never from the game.
  const product = await db.getProduct(productId);
  if (!product || !product.active) {
    return { status: 404, body: { error: "That item isn't for sale." } };
  }
  if (await db.ownsProduct(playerId, productId)) {
    return { status: 409, body: { error: "You already own this." } };
  }
  if ((await db.countRecentPending(playerId)) >= MAX_PENDING_ORDERS) {
    return { status: 429, body: { error: "Too many unpaid orders. Please try again in a few minutes." } };
  }
  const order: Order = {
    order_id: newOrderId(),
    player_id: playerId,
    product_id: productId,
    amount_idr: product.price_idr,
    status: "pending",
  };
  await db.insertOrder(order);
  try {
    const charge = await midtrans.chargeQris(order, product.name);
    return {
      status: 200,
      body: { order_id: order.order_id, amount_idr: order.amount_idr, qr_url: charge.qrUrl, expires_minutes: QR_MINUTES },
    };
  } catch (error) {
    console.error(`Charge failed for ${order.order_id}: ${error}`);
    await db.closeOrderAsFailed(order.order_id);
    return { status: 502, body: { error: "Payment service is unavailable. You have not been charged." } };
  }
}

export async function expectedSignature(orderId: string, statusCode: string, grossAmount: string, serverKey: string): Promise<string> {
  const data = new TextEncoder().encode(orderId + statusCode + grossAmount + serverKey);
  const digest = await crypto.subtle.digest("SHA-512", data);
  return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index++) {
    difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  }
  return difference === 0;
}

// Midtrans's status mapped to ours. Null means nothing to do yet.
export function mapStatus(status: MidtransStatus): string | null {
  switch (status.transaction_status) {
    case "settlement":
      return "paid";
    case "capture":
      return status.fraud_status === "accept" ? "paid" : null;
    case "expire":
      return "expired";
    case "deny":
    case "cancel":
    case "failure":
      return "failed";
    case "refund":
    case "chargeback":
      return "refunded";
    default:
      return null;
  }
}

// Non-2xx answers make Midtrans retry, so temporary problems answer 503 and
// anything that can never succeed answers 200 or a rejection.
export async function handleNotification(
  db: Database,
  midtrans: Midtrans,
  serverKey: string,
  // deno-lint-ignore no-explicit-any
  notification: any,
): Promise<Result> {
  const orderId = notification?.order_id;
  const statusCode = notification?.status_code;
  const grossAmount = notification?.gross_amount;
  const signature = notification?.signature_key;
  if (typeof orderId !== "string" || typeof statusCode !== "string" || typeof grossAmount !== "string" || typeof signature !== "string") {
    return { status: 400, body: { error: "Malformed notification." } };
  }
  if (!sameText(signature, await expectedSignature(orderId, statusCode, grossAmount, serverKey))) {
    console.warn(`Rejected notification with a bad signature for ${orderId}`);
    return { status: 403, body: { error: "Bad signature." } };
  }
  try {
    const order = await db.getOrder(orderId);
    if (!order) {
      // Midtrans's dashboard test button sends made-up order ids.
      console.warn(`Notification for unknown order ${orderId}`);
      return { status: 200, body: { result: "unknown_order" } };
    }
    // Never act on the notification alone: ask Midtrans for the current truth.
    // This also handles notifications arriving out of order.
    const current = await midtrans.getStatus(orderId);
    const newStatus = mapStatus(current);
    if (!newStatus) {
      return { status: 200, body: { result: "no_change" } };
    }
    if (newStatus === "paid" && Number(current.gross_amount) !== order.amount_idr) {
      console.error(`AMOUNT MISMATCH on ${orderId}: expected ${order.amount_idr}, got ${current.gross_amount}`);
      return { status: 200, body: { result: "amount_mismatch" } };
    }
    const result = await db.applyPayment(orderId, newStatus, current.transaction_id);
    if (result === "duplicate") {
      console.error(`REFUND NEEDED: ${orderId} paid for something the player already owns.`);
    }
    return { status: 200, body: { result } };
  } catch (error) {
    console.error(`Could not process ${orderId}: ${error}`);
    return { status: 503, body: { error: "Try again later." } };
  }
}

export function midtransClient(serverKey: string, isProduction: boolean, fetcher: typeof fetch = fetch): Midtrans {
  const base = isProduction ? "https://api.midtrans.com" : "https://api.sandbox.midtrans.com";
  const headers = {
    "Accept": "application/json",
    "Content-Type": "application/json",
    "Authorization": "Basic " + btoa(serverKey + ":"),
  };
  return {
    async chargeQris(order, productName) {
      const response = await fetcher(`${base}/v2/charge`, {
        method: "POST",
        headers,
        body: JSON.stringify({
          payment_type: "qris",
          transaction_details: { order_id: order.order_id, gross_amount: order.amount_idr },
          item_details: [{ id: order.product_id, price: order.amount_idr, quantity: 1, name: productName.slice(0, 50) }],
          qris: { acquirer: "gopay" },
        }),
      });
      const data = await response.json();
      if (String(data.status_code) !== "201") {
        throw new Error(`Midtrans answered ${data.status_code}: ${data.status_message}`);
      }
      const action = data.actions?.find((item: { name: string }) => item.name === "generate-qr-code");
      if (!action?.url) {
        throw new Error("Midtrans sent no QR code.");
      }
      return { transactionId: data.transaction_id, qrUrl: action.url };
    },
    async getStatus(orderId) {
      const response = await fetcher(`${base}/v2/${encodeURIComponent(orderId)}/status`, { headers });
      if (!response.ok) {
        throw new Error(`Status check answered HTTP ${response.status}`);
      }
      return await response.json();
    },
  };
}
