// Sidesnap site Worker.
//
// Runs only for /downloads/*, /admin and /api/* (see run_worker_first in
// wrangler.jsonc). Every other path is served straight from the static files.
//
// Download counting is deliberately minimal: one number per UTC day.
// Nothing about the person is read into storage: no IP address, no user
// agent, no cookies, no IDs. The user agent is only looked at, in memory, to
// skip obvious bots; it is never saved.

const DMG_PATH = "/downloads/Sidesnap.dmg";
const BOT = /bot|crawl|spider|preview|curl|wget/i;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === DMG_PATH) {
      if (shouldCount(request)) {
        // Never slow down or break the download: the write happens after the
        // response is sent, and any database error is ignored.
        ctx.waitUntil(countDownload(env).catch(() => {}));
      }
      return env.ASSETS.fetch(request);
    }

    if (url.pathname === "/admin" || url.pathname === "/admin/" || url.pathname.startsWith("/api/")) {
      if (!(await isAdmin(request, env))) return unauthorized();
      if (url.pathname === "/api/stats") return json(await readStats(env));
      if (url.pathname.startsWith("/admin")) return html(renderAdmin(await readStats(env)));
      return private_(new Response("Not found", { status: 404 }));
    }

    return env.ASSETS.fetch(request);
  },
};

// ---------- Counting ----------

function shouldCount(request) {
  if (request.method !== "GET") return false;                 // skips HEAD
  const range = request.headers.get("Range");
  if (range && !/^bytes=0-/.test(range.trim())) return false;  // resumed download
  const ua = request.headers.get("User-Agent") || "";
  if (!ua.includes("Mozilla") || BOT.test(ua)) return false;   // obvious non-humans
  return true;
}

function utcDay(date = new Date()) {
  return date.toISOString().slice(0, 10);
}

async function countDownload(env) {
  await env.DB.prepare(
    "INSERT INTO downloads (day, count) VALUES (?1, 1) ON CONFLICT(day) DO UPDATE SET count = count + 1"
  ).bind(utcDay()).run();
}

// ---------- Stats ----------

async function readStats(env) {
  const today = new Date();
  const days = [];
  for (let i = 29; i >= 0; i--) {
    days.push(utcDay(new Date(today.getTime() - i * 86400000)));
  }
  const total = await env.DB.prepare("SELECT COALESCE(SUM(count), 0) AS n FROM downloads").first();
  const rows = await env.DB.prepare("SELECT day, count FROM downloads WHERE day >= ?1").bind(days[0]).all();
  const byDay = Object.fromEntries((rows.results || []).map((r) => [r.day, r.count]));
  const last30 = days.map((day) => ({ day, count: byDay[day] || 0 }));
  return {
    total: total ? total.n : 0,
    today: last30[29].count,
    last7: last30.slice(23).reduce((a, d) => a + d.count, 0),
    last30,
    generatedAt: new Date().toISOString(),
  };
}

// ---------- Admin auth (HTTP Basic, password from the ADMIN_PASSWORD secret) ----------

async function isAdmin(request, env) {
  const secret = env.ADMIN_PASSWORD;
  if (!secret) return false; // no password set yet: nobody gets in
  const header = request.headers.get("Authorization") || "";
  if (!header.startsWith("Basic ")) return false;
  let decoded;
  try {
    decoded = atob(header.slice(6));
  } catch {
    return false;
  }
  const password = decoded.slice(decoded.indexOf(":") + 1); // any user name
  return equalConstantTime(password, secret);
}

async function equalConstantTime(a, b) {
  // Hash both so they're the same length, then compare in constant time.
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(ha, hb);
}

// ---------- Responses ----------

function private_(response) {
  response.headers.set("Cache-Control", "no-store");
  response.headers.set("X-Robots-Tag", "noindex, nofollow");
  response.headers.set("Referrer-Policy", "no-referrer");
  return response;
}

function unauthorized() {
  return private_(new Response("Password required", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="Sidesnap admin", charset="UTF-8"', "Content-Type": "text/plain; charset=utf-8" },
  }));
}

function json(data) {
  return private_(new Response(JSON.stringify(data, null, 2), {
    headers: { "Content-Type": "application/json; charset=utf-8" },
  }));
}

function html(body) {
  return private_(new Response(body, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  }));
}

// ---------- Admin page ----------

function renderAdmin(s) {
  const max = Math.max(1, ...s.last30.map((d) => d.count));
  const W = 600, H = 160, gap = 4, bw = (W - gap * 29) / 30;
  const bars = s.last30.map((d, i) => {
    const h = d.count ? Math.max(3, (d.count / max) * (H - 20)) : 2;
    const x = i * (bw + gap);
    const label = `${d.day}: ${d.count}`;
    return `<rect x="${x.toFixed(1)}" y="${(H - h).toFixed(1)}" width="${bw.toFixed(1)}" height="${h.toFixed(1)}" rx="3" class="${d.count ? "bar" : "bar empty"}"><title>${label}</title></rect>`;
  }).join("");
  const fmt = (day) => new Date(day + "T00:00:00Z").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
  const rows = s.last30.slice().reverse().map((d) =>
    `<tr${d.count ? "" : ' class="zero"'}><td>${fmt(d.day)}</td><td>${d.count}</td></tr>`
  ).join("");

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="color-scheme" content="light dark">
<title>Sidesnap · Downloads</title>
<link rel="icon" href="/logo.svg" type="image/svg+xml">
<style>
  :root { --bg:#f4f1ec; --card:#fff; --text:#1d1d1f; --text2:#5e5e63; --text3:#8a8a90; --line:rgba(0,0,0,.09); --accent:#0a6cf0; --empty:rgba(0,0,0,.08); }
  @media (prefers-color-scheme: dark) { :root { --bg:#141416; --card:#232327; --text:#f5f5f7; --text2:#a8a8ae; --text3:#7c7c82; --line:rgba(255,255,255,.1); --accent:#3b8cff; --empty:rgba(255,255,255,.1); } }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:100%/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; -webkit-font-smoothing:antialiased; }
  main { max-width:760px; margin:0 auto; padding:40px 20px 64px; }
  header { display:flex; align-items:center; gap:10px; }
  header img { width:28px; height:28px; border-radius:7px; }
  h1 { margin:0; font-size:26px; letter-spacing:-.02em; }
  .sub { margin:6px 0 0; color:var(--text2); font-size:14px; }
  .cards { display:grid; grid-template-columns:repeat(3,1fr); gap:14px; margin-top:28px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:18px; }
  .card p { margin:0; font-size:13px; color:var(--text2); }
  .card strong { display:block; margin-top:4px; font-size:34px; letter-spacing:-.03em; font-variant-numeric:tabular-nums; }
  .panel { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:18px; margin-top:14px; }
  .panel h2 { margin:0 0 12px; font-size:15px; }
  svg { display:block; width:100%; height:auto; }
  .bar { fill:var(--accent); } .bar.empty { fill:var(--empty); }
  .axis { display:flex; justify-content:space-between; margin-top:6px; font-size:11.5px; color:var(--text3); }
  table { width:100%; border-collapse:collapse; font-size:14px; font-variant-numeric:tabular-nums; }
  td { padding:8px 4px; border-top:1px solid var(--line); }
  td:last-child { text-align:right; font-weight:600; }
  tr.zero td { color:var(--text3); font-weight:400; }
  .note { margin-top:18px; font-size:12.5px; color:var(--text3); }
  @media (max-width:560px) { .cards { grid-template-columns:1fr; } .card strong { font-size:28px; } }
</style>
</head>
<body>
<main>
  <header><img src="/icon.png" alt=""><h1>Downloads</h1></header>
  <p class="sub">Sidesnap.dmg · counted per day (UTC) · refresh for the latest</p>

  <div class="cards">
    <div class="card"><p>All time</p><strong>${s.total}</strong></div>
    <div class="card"><p>Last 7 days</p><strong>${s.last7}</strong></div>
    <div class="card"><p>Today</p><strong>${s.today}</strong></div>
  </div>

  <section class="panel">
    <h2>Last 30 days</h2>
    <svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Downloads per day, last 30 days">${bars}</svg>
    <div class="axis"><span>${fmt(s.last30[0].day)}</span><span>${fmt(s.last30[29].day)}</span></div>
  </section>

  <section class="panel">
    <h2>By day</h2>
    <table>${rows}</table>
  </section>

  <p class="note">Only a number per day is stored: no IP addresses, no browser details, no cookies, nothing about the person. Bots, HEAD requests and resumed downloads aren't counted.</p>
</main>
</body>
</html>`;
}
