// Connects the payment rules to the real Supabase database and environment.
import { createClient } from "npm:@supabase/supabase-js@2";
import { midtransClient } from "./payments.ts";
import type { Database, Midtrans, Order } from "./payments.ts";

export const serverKey = Deno.env.get("MIDTRANS_SERVER_KEY") ?? "";
// Stays in test mode unless this is deliberately set to "true".
const isProduction = Deno.env.get("MIDTRANS_IS_PRODUCTION") === "true";

export const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false } },
);

export const midtrans: Midtrans = midtransClient(serverKey, isProduction);

function check<T>(result: { data: T; error: unknown }): T {
  if (result.error) throw new Error(JSON.stringify(result.error));
  return result.data;
}

export const database: Database = {
  async getProduct(id) {
    return check(await admin.from("products").select("id,name,price_idr,active").eq("id", id).maybeSingle());
  },
  async ownsProduct(playerId, productId) {
    const rows = check(await admin.from("entitlements").select("product_id").eq("player_id", playerId).eq("product_id", productId));
    return (rows ?? []).length > 0;
  },
  async countRecentPending(playerId) {
    const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
    const rows = check(await admin.from("orders").select("order_id").eq("player_id", playerId).eq("status", "pending").gte("created_at", since));
    return (rows ?? []).length;
  },
  async insertOrder(order: Order) {
    check(await admin.from("orders").insert(order));
  },
  async closeOrderAsFailed(orderId) {
    check(await admin.from("orders").update({ status: "failed" }).eq("order_id", orderId).eq("status", "pending"));
  },
  async getOrder(orderId) {
    return check(await admin.from("orders").select("order_id,player_id,product_id,amount_idr,status").eq("order_id", orderId).maybeSingle());
  },
  async applyPayment(orderId, status, transactionId) {
    return check(await admin.rpc("apply_payment", { p_order_id: orderId, p_status: status, p_transaction_id: transactionId }));
  },
};

export function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
