# Hisaab

Split group expenses with friends. Free, no ads, no accounts. A group is a
private link — share it on WhatsApp and everyone can add expenses, see
balances, and settle up with the fewest payments.

**Live:** https://shubham-safaya.github.io/hisaab/

## How it works
- Frontend: static vanilla-JS SPA on GitHub Pages (this repo).
- Data: Supabase (free tier) — but **all** access goes through Postgres
  `SECURITY DEFINER` RPCs in `schema.sql`. Direct table access is revoked,
  so the public anon key cannot list or enumerate anything; a group's
  unguessable UUID in the link *is* the membership. Treat group links like
  group-chat invites.

## Upgrading to v3.0 (existing project)
1. SQL Editor → paste `migrations/002_v3.sql` → Run (expense dates + accounts).
2. Authentication → URL Configuration → set Site URL to
   `https://shubham-safaya.github.io/hisaab/` (magic links land there).

## One-time setup (owner, ~3 minutes)
1. Create a free project at https://supabase.com (any name/region).
2. In the project: **SQL Editor → New query**, paste all of `schema.sql`, Run.
3. **Project Settings → API**: copy the Project URL and the `anon` public key
   into `config.js` (the anon key is meant to be public; RLS + RPCs do the
   protecting).
4. Commit + push. Done — the setup banner disappears.

## Features
- Groups with any number of people — a link is all you need (no sign-ups)
- Optional email sign-in (magic link, no password) that remembers your groups
  on any device; link-only usage keeps working without it
- Expenses split equally or by exact amounts (cent-accurate distribution)
- Backdate expenses (defaults to today; future dates rejected server-side)
- Click any person for their ledger + quick two-person expenses
- Live balances: who owes, who gets back
- Settle-up plan with the minimum number of payments + "mark paid"
- Multi-currency groups (USD/INR/EUR/GBP)
- Recent groups remembered per device

## Roadmap (beta → app)
- [ ] Percent / share-based splits
- [ ] Supabase Realtime (balances update without refresh)
- [ ] Export group history to CSV
- [x] PWA manifest + offline shell → installable "app" without app-store fees (v0.2)
- [ ] Native wrapper (Capacitor) if it ever earns a Play Store listing ($25 one-time)
