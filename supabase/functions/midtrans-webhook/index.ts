// Called by Midtrans whenever a payment changes. Deploy with --no-verify-jwt,
// because Midtrans has no Supabase login; its signature is checked instead.
import { database, json, midtrans, serverKey } from "../_shared/live.ts";
import { handleNotification } from "../_shared/payments.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "POST only." });
  const notification = await request.json().catch(() => null);
  const result = await handleNotification(database, midtrans, serverKey, notification);
  return json(result.status, result.body);
});
