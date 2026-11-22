-- One row per UTC day: how many times Sidesnap.dmg was downloaded.
-- Nothing else is stored: no IPs, no user agents, no cookies, no IDs.
CREATE TABLE IF NOT EXISTS downloads (
  day   TEXT PRIMARY KEY,   -- e.g. 2026-11-18 (UTC)
  count INTEGER NOT NULL DEFAULT 0
);
