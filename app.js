/* EvenOut — Splitwise-style group expense splitting.
   Vanilla JS SPA. All data via Supabase RPCs (see schema.sql).
   Routing: #/g/<group-uuid> is the shareable capability link. */

"use strict";

const CFG = window.EVENOUT_CONFIG || window.HISAAB_CONFIG || {};
const CONFIGURED = CFG.SUPABASE_URL && !CFG.SUPABASE_URL.startsWith("PASTE_");
const db = CONFIGURED
  ? window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY)
  : null;

const $ = (sel, el = document) => el.querySelector(sel);
const app = $("#app");

const SYM = { USD: "$", INR: "₹", EUR: "€", GBP: "£" };
const fmt = (n, cur) =>
  `${SYM[cur] || cur + " "}${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

function esc(s) {
  return String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function expDate(e) {
  // spent_on (v3+) is a plain date; older rows fall back to created_at
  const d = e.spent_on ? new Date(e.spent_on + "T12:00:00") : new Date(e.created_at);
  return d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
}

let session = null; // Supabase auth session (optional — link-only use is fine)

async function rpc(fn, args) {
  const { data, error } = await db.rpc(fn, args);
  if (error) {
    // graceful pre-migration fallback: old add_expense has no p_spent_on
    if (fn === "add_expense" && args.p_spent_on && /add_expense/.test(error.message)
        && /function|parameter|argument/i.test(error.message)) {
      const { p_spent_on, ...rest } = args;
      const retry = await db.rpc(fn, rest);
      if (!retry.error) return retry.data;
    }
    throw new Error(error.message);
  }
  return data;
}

/* ── Local list of groups you've touched (device-only convenience) ── */
function rememberGroup(id, name) {
  const seen = JSON.parse(localStorage.getItem("evenout_groups") || localStorage.getItem("hisaab_groups") || "[]")
    .filter(g => g.id !== id);
  seen.unshift({ id, name });
  localStorage.setItem("evenout_groups", JSON.stringify(seen.slice(0, 12)));
}

/* ── Balance math ─────────────────────────────────────────────────── */
function computeBalances(data) {
  // balance > 0 → the group owes this member; < 0 → member owes the group
  const bal = Object.fromEntries(data.members.map(m => [m.id, 0]));
  for (const e of data.expenses) {
    bal[e.paid_by] += Number(e.amount);
    for (const s of e.splits || []) bal[s.member_id] -= Number(s.share);
  }
  for (const k in bal) bal[k] = Math.round(bal[k] * 100) / 100;
  return bal;
}

function simplifyDebts(balances) {
  // Greedy min-transaction settle-up: repeatedly match top debtor & creditor.
  const debtors = [], creditors = [];
  for (const [id, b] of Object.entries(balances)) {
    if (b < -0.005) debtors.push({ id, amt: -b });
    else if (b > 0.005) creditors.push({ id, amt: b });
  }
  debtors.sort((a, b) => b.amt - a.amt);
  creditors.sort((a, b) => b.amt - a.amt);
  const plan = [];
  let i = 0, j = 0;
  while (i < debtors.length && j < creditors.length) {
    const pay = Math.min(debtors[i].amt, creditors[j].amt);
    plan.push({ from: debtors[i].id, to: creditors[j].id, amount: Math.round(pay * 100) / 100 });
    debtors[i].amt -= pay; creditors[j].amt -= pay;
    if (debtors[i].amt < 0.005) i++;
    if (creditors[j].amt < 0.005) j++;
  }
  return plan;
}

/* ── Views ────────────────────────────────────────────────────────── */
function renderHome() {
  app.innerHTML = "";
  app.appendChild($("#tpl-home").content.cloneNode(true));

  const seen = JSON.parse(localStorage.getItem("evenout_groups") || localStorage.getItem("hisaab_groups") || "[]");
  const recent = $("#recent-groups");
  if (seen.length) {
    recent.innerHTML = "<h2>Your groups on this device</h2>" + seen.map(g =>
      `<a class="group-link" href="#/g/${esc(g.id)}">${esc(g.name)}</a>`).join("");
  } else {
    recent.remove();
  }

  // Signed in? Show groups pinned to the account (any device).
  const acct = $("#account-groups");
  if (session) {
    db.from("user_groups").select("group_id, group_name").order("added_at", { ascending: false })
      .then(({ data }) => {
        if (data && data.length) {
          acct.innerHTML = "<h2>Your groups (account)</h2>" + data.map(g =>
            `<a class="group-link" href="#/g/${esc(g.group_id)}">${esc(g.group_name || "Unnamed group")}</a>`).join("");
        } else acct.remove();
      });
  } else {
    acct.remove();
  }

  $("#form-create").addEventListener("submit", async ev => {
    ev.preventDefault();
    const f = ev.target;
    const members = f.members.value.split(",").map(s => s.trim()).filter(Boolean);
    if (members.length < 1) return alert("Add at least one person.");
    setBusy(f, true);
    try {
      const gid = await rpc("create_group", {
        p_name: f.name.value.trim(), p_currency: f.currency.value, p_members: members,
      });
      rememberGroup(gid, f.name.value.trim());
      location.hash = `#/g/${gid}`;
    } catch (e) { alert("Could not create group: " + e.message); }
    setBusy(f, false);
  });
}

async function renderGroup(gid) {
  app.innerHTML = `<p class="loading">Loading group…</p>`;
  let data;
  try {
    data = await rpc("get_group_data", { p_group: gid });
  } catch (e) {
    app.innerHTML = `<section class="panel"><h2>Couldn't load this group</h2>
      <p>${esc(e.message)}</p><p><a href="./">← back home</a></p></section>`;
    return;
  }
  if (!data || !data.group) {
    app.innerHTML = `<section class="panel"><h2>Group not found</h2>
      <p>Check the link — it must be exactly the one that was shared.</p>
      <p><a href="./">← back home</a></p></section>`;
    return;
  }

  const g = data.group;
  rememberGroup(g.id, g.name);
  if (session) {
    // pin to account (idempotent) so it shows on any device he signs into
    db.from("user_groups").upsert(
      { user_id: session.user.id, group_id: g.id, group_name: g.name },
      { onConflict: "user_id,group_id" }
    ).then(() => {});
  }
  const nameOf = Object.fromEntries(data.members.map(m => [m.id, m.name]));
  const balances = computeBalances(data);
  const plan = simplifyDebts(balances);

  const balRows = data.members.map(m => {
    const b = balances[m.id];
    const cls = b > 0.005 ? "pos" : b < -0.005 ? "neg" : "";
    const label = b > 0.005 ? "gets back" : b < -0.005 ? "owes" : "settled up";
    return `<div class="bal-row"><a class="member-link" href="#/g/${g.id}/m/${m.id}">${esc(m.name)}</a>
      <span class="${cls}">${label}${cls ? " " + fmt(Math.abs(b), g.currency) : ""}</span></div>`;
  }).join("");

  const planRows = plan.length
    ? plan.map(p => `<div class="plan-row">${esc(nameOf[p.from])} → ${esc(nameOf[p.to])}
        <strong>${fmt(p.amount, g.currency)}</strong>
        <button class="btn small settle-btn" data-from="${p.from}" data-to="${p.to}"
          data-amt="${p.amount}">mark paid</button></div>`).join("")
    : `<p class="hint">Everyone is settled up. 🎉</p>`;

  const expRows = data.expenses.length ? data.expenses.map(e => `
    <div class="exp-row ${e.is_settlement ? "settlement" : ""}">
      <div>
        <strong>${esc(e.description)}</strong>
        <div class="exp-meta">${esc(nameOf[e.paid_by] || "?")} paid ${fmt(e.amount, g.currency)}
          · ${expDate(e)}</div>
      </div>
      <span class="row-btns">${e.is_settlement ? "" :
        `<button class="edit-btn" data-id="${e.id}" title="edit">✎</button>`}
      <button class="del-btn" data-id="${e.id}" title="delete">×</button></span>
    </div>`).join("")
    : `<p class="hint">No expenses yet — add the first one.</p>`;

  const memberOpts = data.members.map(m => `<option value="${m.id}">${esc(m.name)}</option>`).join("");
  const splitInputs = data.members.map(m => `
    <label class="split-line"><span>${esc(m.name)}</span>
      <input type="checkbox" class="split-in" data-id="${m.id}" checked>
      <input type="number" step="0.01" min="0" class="split-amt hidden" data-id="${m.id}" placeholder="0.00">
    </label>`).join("");

  app.innerHTML = `
    <section class="group-head">
      <h1>${esc(g.name)}</h1>
      <button class="btn small" id="copy-link">copy invite link</button>
    </section>

    <section class="panel" id="expense-panel">
      <h2 id="expense-form-title">Add expense</h2>
      <form id="form-expense">
        <label>Description <input name="description" required maxlength="200" placeholder="Dinner, cab, groceries…"></label>
        <div class="row2">
          <label>Amount <input name="amount" type="number" step="0.01" min="0.01" required></label>
          <label>Paid by <select name="paid_by">${memberOpts}</select></label>
        </div>
        <label>Date <input name="spent_on" type="date" value="${today()}" max="${today()}" required></label>
        <fieldset>
          <legend>Split <select id="split-mode"><option value="equal">equally</option><option value="exact">by exact amounts</option></select></legend>
          <div id="split-list">${splitInputs}</div>
        </fieldset>
        <button type="submit" class="btn" id="expense-submit">Add expense</button>
        <button type="button" class="btn small hidden" id="expense-cancel">cancel edit</button>
      </form>
    </section>

    <section class="panel">
      <h2>Balances</h2>
      ${balRows}
      <h3>Settle up (${plan.length} payment${plan.length === 1 ? "" : "s"})</h3>
      ${planRows}
    </section>

    <section class="panel">
      <h2>History</h2>
      ${expRows}
      <details class="add-member"><summary>Add a person</summary>
        <form id="form-member"><input name="name" required maxlength="60" placeholder="Name">
        <button class="btn small">Add</button></form>
      </details>
    </section>`;

  /* interactions */
  $("#copy-link").onclick = async () => {
    await navigator.clipboard.writeText(location.href);
    $("#copy-link").textContent = "copied!";
    setTimeout(() => ($("#copy-link").textContent = "copy invite link"), 1500);
  };

  $("#split-mode").onchange = ev => {
    const exact = ev.target.value === "exact";
    app.querySelectorAll(".split-amt").forEach(i => i.classList.toggle("hidden", !exact));
    app.querySelectorAll(".split-in").forEach(i => i.classList.toggle("hidden", exact));
  };

  $("#form-expense").addEventListener("submit", async ev => {
    ev.preventDefault();
    const f = ev.target;
    const amount = Math.round(parseFloat(f.amount.value) * 100) / 100;
    const exact = $("#split-mode").value === "exact";
    let splits = [];
    if (exact) {
      app.querySelectorAll(".split-amt").forEach(i => {
        const v = Math.round((parseFloat(i.value) || 0) * 100) / 100;
        if (v > 0) splits.push({ member_id: i.dataset.id, share: v });
      });
      const total = splits.reduce((s, x) => s + x.share, 0);
      if (Math.abs(total - amount) > 0.02)
        return alert(`Split amounts (${total.toFixed(2)}) must add up to ${amount.toFixed(2)}.`);
    } else {
      const chosen = [...app.querySelectorAll(".split-in:checked")].map(i => i.dataset.id);
      if (!chosen.length) return alert("Pick at least one person to split with.");
      // distribute cents so shares sum exactly to the amount
      const cents = Math.round(amount * 100);
      const base = Math.floor(cents / chosen.length);
      splits = chosen.map((id, idx) => ({
        member_id: id,
        share: (base + (idx < cents - base * chosen.length ? 1 : 0)) / 100,
      }));
    }
    setBusy(f, true);
    try {
      if (f.dataset.editing) {
        await rpc("update_expense", {
          p_group: gid, p_expense: f.dataset.editing,
          p_description: f.description.value.trim(),
          p_amount: amount, p_paid_by: f.paid_by.value,
          p_splits: splits, p_spent_on: f.spent_on.value || today(),
        });
      } else {
        await rpc("add_expense", {
          p_group: gid, p_description: f.description.value.trim(),
          p_amount: amount, p_paid_by: f.paid_by.value,
          p_splits: splits, p_is_settlement: false,
          p_spent_on: f.spent_on.value || today(),
        });
      }
      renderGroup(gid);
    } catch (e) {
      const msg = f.dataset.editing && /update_expense/.test(e.message)
        ? "Editing needs migration 005 — ask Shubham to run it."
        : e.message;
      alert("Could not save expense: " + msg); setBusy(f, false);
    }
  });

  // Edit: prefill the form with the expense and switch to save mode
  app.querySelectorAll(".edit-btn").forEach(btn => btn.onclick = () => {
    const e = data.expenses.find(x => x.id === btn.dataset.id);
    if (!e) return;
    const f = $("#form-expense");
    f.dataset.editing = e.id;
    f.description.value = e.description;
    f.amount.value = Number(e.amount).toFixed(2);
    f.paid_by.value = e.paid_by;
    f.spent_on.value = e.spent_on || today();
    // exact mode with current shares — add/drop people by editing amounts,
    // or switch to "equally" and use the checkboxes
    $("#split-mode").value = "exact";
    $("#split-mode").dispatchEvent(new Event("change"));
    const shareOf = Object.fromEntries((e.splits || []).map(s => [s.member_id, s.share]));
    app.querySelectorAll(".split-amt").forEach(i => {
      i.value = shareOf[i.dataset.id] ? Number(shareOf[i.dataset.id]).toFixed(2) : "";
    });
    app.querySelectorAll(".split-in").forEach(i => {
      i.checked = !!shareOf[i.dataset.id];
    });
    $("#expense-form-title").textContent = `Edit: ${e.description}`;
    $("#expense-submit").textContent = "Save changes";
    $("#expense-cancel").classList.remove("hidden");
    $("#expense-panel").scrollIntoView({ behavior: "smooth" });
  });

  $("#expense-cancel").onclick = () => renderGroup(gid);

  app.querySelectorAll(".settle-btn").forEach(btn => btn.onclick = async () => {
    const { from, to, amt } = btn.dataset;
    if (!confirm(`${nameOf[from]} paid ${nameOf[to]} ${fmt(amt, g.currency)}?`)) return;
    try {
      await rpc("add_expense", {
        p_group: gid,
        p_description: `Settlement: ${nameOf[from]} → ${nameOf[to]}`,
        p_amount: Number(amt), p_paid_by: from,
        p_splits: [{ member_id: to, share: Number(amt) }],
        p_is_settlement: true,
      });
      renderGroup(gid);
    } catch (e) { alert("Could not record settlement: " + e.message); }
  });

  app.querySelectorAll(".del-btn").forEach(btn => btn.onclick = async () => {
    if (!confirm("Delete this entry for everyone?")) return;
    try {
      await rpc("delete_expense", { p_group: gid, p_expense: btn.dataset.id });
      renderGroup(gid);
    } catch (e) { alert("Could not delete: " + e.message); }
  });

  $("#form-member").addEventListener("submit", async ev => {
    ev.preventDefault();
    try {
      await rpc("add_member", { p_group: gid, p_name: ev.target.name.value.trim() });
      renderGroup(gid);
    } catch (e) { alert("Could not add person: " + e.message); }
  });
}

function setBusy(form, busy) {
  form.querySelectorAll("button, input, select").forEach(el => (el.disabled = busy));
}

/* ── Member view: one person's ledger + quick pair expense ────────── */
async function renderMember(gid, mid) {
  app.innerHTML = `<p class="loading">Loading…</p>`;
  let data;
  try { data = await rpc("get_group_data", { p_group: gid }); }
  catch (e) { app.innerHTML = `<section class="panel"><p>${esc(e.message)}</p></section>`; return; }
  if (!data || !data.group) { location.hash = `#/g/${gid}`; return; }

  const g = data.group;
  const me = data.members.find(m => m.id === mid);
  if (!me) { location.hash = `#/g/${gid}`; return; }
  const nameOf = Object.fromEntries(data.members.map(m => [m.id, m.name]));
  const others = data.members.filter(m => m.id !== mid);
  const bal = computeBalances(data)[mid] || 0;
  const balLabel = bal > 0.005 ? `gets back ${fmt(bal, g.currency)}`
    : bal < -0.005 ? `owes ${fmt(-bal, g.currency)}` : "settled up";

  const involved = data.expenses.filter(e =>
    e.paid_by === mid || (e.splits || []).some(s => s.member_id === mid));
  const rows = involved.length ? involved.map(e => {
    const mine = e.paid_by === mid
      ? `paid ${fmt(e.amount, g.currency)}`
      : `owes ${fmt((e.splits || []).find(s => s.member_id === mid)?.share || 0, g.currency)}`;
    return `<div class="exp-row ${e.is_settlement ? "settlement" : ""}"><div>
      <strong>${esc(e.description)}</strong>
      <div class="exp-meta">${esc(me.name)} ${mine} · ${expDate(e)}</div></div></div>`;
  }).join("") : `<p class="hint">Nothing involving ${esc(me.name)} yet.</p>`;

  const otherOpts = others.map(m => `<option value="${m.id}">${esc(m.name)}</option>`).join("");

  app.innerHTML = `
    <section class="group-head">
      <h1>${esc(me.name)} <span class="in-group">in ${esc(g.name)}</span></h1>
      <a class="btn small" href="#/g/${g.id}">← group</a>
    </section>
    <section class="panel"><h2>Balance</h2>
      <div class="bal-row"><span>${esc(me.name)}</span><span class="${bal > 0.005 ? "pos" : bal < -0.005 ? "neg" : ""}">${balLabel}</span></div>
    </section>
    ${others.length ? `
    <section class="panel">
      <h2>Add expense with ${esc(me.name)}</h2>
      <form id="form-pair">
        <label>Description <input name="description" required maxlength="200" placeholder="Cab, coffee, tickets…"></label>
        <div class="row2">
          <label>Amount <input name="amount" type="number" step="0.01" min="0.01" required></label>
          <label>Date <input name="spent_on" type="date" value="${today()}" max="${today()}" required></label>
        </div>
        <div class="row2">
          <label>With <select name="other">${otherOpts}</select></label>
          <label>Who paid?
            <select name="payer_side">
              <option value="me">${esc(me.name)} paid</option>
              <option value="other">the other person paid</option>
            </select>
          </label>
        </div>
        <label>How to split
          <select name="mode">
            <option value="equal">split equally between the two</option>
            <option value="full">the non-payer owes the full amount</option>
          </select>
        </label>
        <button type="submit" class="btn">Add</button>
      </form>
    </section>` : ""}
    <section class="panel"><h2>${esc(me.name)}'s activity</h2>${rows}</section>`;

  const pairForm = $("#form-pair");
  if (pairForm) pairForm.addEventListener("submit", async ev => {
    ev.preventDefault();
    const f = ev.target;
    const amount = Math.round(parseFloat(f.amount.value) * 100) / 100;
    const other = f.other.value;
    const payer = f.payer_side.value === "me" ? mid : other;
    const ower = payer === mid ? other : mid;
    const splits = f.mode.value === "full"
      ? [{ member_id: ower, share: amount }]
      : [{ member_id: payer, share: Math.round(amount * 50) / 100 },
         { member_id: ower, share: amount - Math.round(amount * 50) / 100 }];
    setBusy(f, true);
    try {
      await rpc("add_expense", {
        p_group: gid, p_description: f.description.value.trim(),
        p_amount: amount, p_paid_by: payer, p_splits: splits,
        p_is_settlement: false, p_spent_on: f.spent_on.value || today(),
      });
      renderMember(gid, mid);
    } catch (e) { alert("Could not add: " + e.message); setBusy(f, false); }
  });
}

/* ── Optional sign-in (email magic link) ──────────────────────────── */
function renderAuthArea() {
  const el = $("#auth-area");
  if (!el || !CONFIGURED) return;
  if (session) {
    el.innerHTML = `<span class="auth-mail">${esc(session.user.email || "")}</span>
      <button class="linkish" id="signout-btn">sign out</button>`;
    $("#signout-btn").onclick = async () => { await db.auth.signOut(); };
  } else {
    el.innerHTML = `<button class="linkish" id="signin-btn">sign in</button>`;
    $("#signin-btn").onclick = async () => {
      const email = prompt(
        "Optional sign-in: your groups get remembered on any device.\n" +
        "Enter your email — we send a one-time login link. No password, " +
        "no spam, used for nothing else.");
      if (!email || !email.includes("@")) return;
      const { error } = await db.auth.signInWithOtp({
        email: email.trim(),
        options: { emailRedirectTo: location.origin + location.pathname },
      });
      alert(error ? "Could not send link: " + error.message
        : "Check your email — the login link signs you in here.");
    };
  }
}

async function initAuth() {
  if (!CONFIGURED) return;
  session = (await db.auth.getSession()).data.session;
  renderAuthArea();
  db.auth.onAuthStateChange((_ev, s) => {
    const was = !!session; session = s; renderAuthArea();
    if (!!s !== was) route(); // re-render lists on sign-in/out
  });
}

/* ── Router ───────────────────────────────────────────────────────── */
function route() {
  if (!CONFIGURED) {
    $("#setup-banner").classList.remove("hidden");
    renderHome();
    $("#form-create") && ($("#form-create").querySelector("button").disabled = true);
    return;
  }
  const pair = location.hash.match(/^#\/g\/([0-9a-f-]{36})\/m\/([0-9a-f-]{36})$/i);
  if (pair) return renderMember(pair[1], pair[2]);
  const m = location.hash.match(/^#\/g\/([0-9a-f-]{36})$/i);
  if (m) renderGroup(m[1]);
  else renderHome();
}

/* ── Anonymous usage ping (feeds the public stats page) ────────────
   Stores only (day, random-device-token). No PII, no third parties,
   honors Do Not Track. Aggregates are public at stats.html. */
function deviceToken() {
  let t = localStorage.getItem("evenout_device");
  if (!t) {
    t = (crypto.randomUUID && crypto.randomUUID()) ||
      String(Date.now()) + "-" + Math.random().toString(36).slice(2, 12);
    localStorage.setItem("evenout_device", t);
  }
  return t;
}

function logPing(kind) {
  if (!CONFIGURED) return;
  if (navigator.doNotTrack === "1") return; // respected, as promised
  if (kind === "open" && sessionStorage.getItem("evenout_pinged")) return;
  if (kind === "open") sessionStorage.setItem("evenout_pinged", "1");
  db.rpc("log_ping", { p_device: deviceToken(), p_kind: kind }).then(() => {});
}

window.addEventListener("hashchange", route);
initAuth().finally(route);
logPing("open");

/* ── PWA: offline shell + install button ─────────────────────────── */
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}

let installPrompt = null;
const installBtn = $("#install-btn");
window.addEventListener("beforeinstallprompt", (ev) => {
  ev.preventDefault();
  installPrompt = ev;
  installBtn.classList.remove("hidden");
});
installBtn.addEventListener("click", async () => {
  if (!installPrompt) return;
  installPrompt.prompt();
  await installPrompt.userChoice;
  installPrompt = null;
  installBtn.classList.add("hidden");
});
window.addEventListener("appinstalled", () => {
  installBtn.classList.add("hidden");
  logPing("install");
});
