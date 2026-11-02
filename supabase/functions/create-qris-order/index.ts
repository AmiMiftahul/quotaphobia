// Called by the game when a signed-in player presses Buy.
import { admin, database, json, midtrans } from "../_shared/live.ts";
import { createOrder } from "../_shared/payments.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "POST only." });
  const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer /, "");
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return json(401, { error: "Please sign in again." });
  try {
    const body = await request.json().catch(() => ({}));
    const result = await createOrder(database, midtrans, data.user.id, body.product_id, () => `ss-${crypto.randomUUID()}`);
    return json(result.status, result.body);
  } catch (failure) {
    console.error(`create-qris-order failed: ${failure}`);
    return json(500, { error: "Something went wrong. You have not been charged." });
  }
});
