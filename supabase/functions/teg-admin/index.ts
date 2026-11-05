// TEG Leveranceplan – opret login med midlertidigt kodeord (samme model som Topas Tid og Topas BI).
// Ingen mail involveret: admin får et midlertidigt kodeord at give videre, og brugeren skal vælge sit eget ved første login.
// Loginnet er fælles med Topas BI. Adgang: aktiv admin i bi_brugere. Skriver med service-rollen.
import { createClient } from "npm:@supabase/supabase-js@2.117.3";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" } });
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Fx Topas-k3m9x2p7qa: 8+ tegn med bogstaver og tal, som i Topas BI. */
function midlertidigtKodeord(): string {
  const tegn = "abcdefghjkmnpqrstuvwxyz23456789";
  for (;;) {
    const k = [...crypto.getRandomValues(new Uint8Array(10))].map((x) => tegn[x % tegn.length]).join("");
    if (/\d/.test(k) && /[a-z]/.test(k)) return `Topas-${k}`;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ fejl: "Kun POST" }, 405);

  const auth = req.headers.get("authorization") ?? "";
  const token = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  if (!token) return json({ fejl: "Log ind først." }, 401);
  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: u, error: uErr } = await anon.auth.getUser(token);
  const kalder = u?.user?.email?.toLowerCase();
  if (uErr || !kalder) return json({ fejl: "Ugyldigt login." }, 401);
  const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: mig } = await db.from("bi_brugere").select("rolle, aktiv").eq("email", kalder).maybeSingle();
  const erAdmin = !!mig?.aktiv && mig.rolle === "admin";

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ fejl: "Ugyldig forespørgsel." }, 400); }
  if (body.handling === "tjek") return json({ admin: erAdmin });
  if (!erAdmin) return json({ fejl: "Kun administratorer kan oprette logins." }, 403);
  if (body.handling !== "opret") return json({ fejl: "Ukendt handling." }, 400);

  const email = String(body.email ?? "").trim().toLowerCase();
  if (!EMAIL.test(email)) return json({ fejl: "Skriv en gyldig e-mail." }, 400);
  if (email === kalder) return json({ fejl: "Skift dit eget kodeord under \"Skift kodeord\"." }, 400);

  // Findes loginnet allerede?
  let findes: { id: string; user_metadata?: Record<string, unknown> } | undefined;
  for (let side = 1; side <= 20 && !findes; side++) {
    const { data, error } = await db.auth.admin.listUsers({ page: side, perPage: 1000 });
    if (error) return json({ fejl: `Kunne ikke hente logins: ${error.message}` }, 500);
    findes = data.users.find((x) => x.email?.toLowerCase() === email);
    if (data.users.length < 1000) break;
  }
  if (findes) {
    // Admins i Topas BI nulstilles ikke herfra (beskytter admin-kontoerne).
    const { data: b } = await db.from("bi_brugere").select("rolle").eq("email", email).maybeSingle();
    if (b?.rolle === "admin") return json({ fejl: "Kodeordet for en administrator kan ikke nulstilles her." }, 403);
  }
  const kodeord = midlertidigtKodeord();
  const { error } = findes
    ? await db.auth.admin.updateUserById(findes.id, { password: kodeord, user_metadata: { ...(findes.user_metadata ?? {}), must_change: true } })
    : await db.auth.admin.createUser({ email, password: kodeord, email_confirm: true, user_metadata: { must_change: true } });
  if (error) return json({ fejl: `Kunne ikke gemme login: ${error.message}` }, 500);
  console.log(`teg-admin: ${kalder} ${findes ? "nulstillede" : "oprettede"} login for ${email}`);
  return json({ email, midlertidigt_kodeord: kodeord, nyt_login: !findes });
});
