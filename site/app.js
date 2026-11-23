// Sidesnap landing page: the menu bar, and a working copy of Sidesnap on the
// little desktop (capture, the corner card, the edge shelf), plus the install
// steps. Screenshots here are copies of the page, made in the page. Nothing is
// saved or sent anywhere.
(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const narrow = window.matchMedia("(max-width: 980px)");
  const $ = (id) => document.getElementById(id);

  // ---------- Menu ----------

  const icon = $("menuIcon");
  const panel = $("panel");
  function setMenu(open) {
    panel.classList.toggle("hidden", !open);
    icon.setAttribute("aria-expanded", String(open));
  }
  icon.addEventListener("click", () => setMenu(panel.classList.contains("hidden")));
  document.addEventListener("click", (e) => {
    if (!panel.contains(e.target) && !icon.contains(e.target)) setMenu(false);
  });

  // ---------- Sidesnap at its real sizes ----------
  // Everything inside #scr is laid out in the app's own points on a screen
  // 1400 points wide, then scaled to fit the little desktop.

  const W = 1400;
  const screenEl = $("screen");
  const scr = $("scr");
  let s = 1, H = 750;
  function layout() {
    const r = screenEl.getBoundingClientRect();
    if (!r.width) return;
    s = r.width / W;
    H = r.height / s;
    scr.style.transform = `scale(${s})`;
    scr.style.setProperty("--H", H.toFixed(2));
  }
  layout();
  window.addEventListener("resize", layout);

  const toLocal = (cx, cy) => {
    const o = scr.getBoundingClientRect();
    return { x: (cx - o.left) / s, y: (cy - o.top) / s };
  };
  const rectOf = (el) => {
    const r = el.getBoundingClientRect(), o = scr.getBoundingClientRect();
    return { x: (r.left - o.left) / s, y: (r.top - o.top) / s, w: r.width / s, h: r.height / s, pw: r.width, ph: r.height };
  };
  const inside = (p, r) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
  const grow = (r, m) => ({ x: r.x - m, y: r.y - m, w: r.w + 2 * m, h: r.h + 2 * m });
  const overlaps = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
  const fmtTime = (t) => new Date(t).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });

  const target = $("target");
  const chatWin = $("chatWin");
  const bar = document.querySelector(".stage-bar");

  // A picture of the screen right now: the desktop photo plus copies of what's
  // on it. Like the app, Sidesnap's own card and shelf are left out.
  function snapshot(kind, win) {
    const world = document.createElement("div");
    world.className = "world";
    world.style.width = W + "px";
    world.style.height = H + "px";
    if (kind !== "Window") {
      const bg = document.createElement("div");
      bg.className = "world-bg";
      world.append(bg);
    }
    for (const el of kind === "Window" ? [win] : [target, chatWin, bar]) {
      const r = rectOf(el);
      const c = el.cloneNode(true);
      c.removeAttribute("id");
      c.querySelectorAll("[id]").forEach((n) => n.removeAttribute("id"));
      c.querySelectorAll(".down").forEach((n) => n.classList.remove("down"));
      c.querySelectorAll("[contenteditable]").forEach((n) => n.removeAttribute("contenteditable"));
      c.classList.remove("nudge", "drop");
      c.classList.add("clone");
      Object.assign(c.style, {
        left: r.x + "px", top: r.y + "px", width: r.pw + "px", height: r.ph + "px",
        transform: `scale(${1 / s})`,
      });
      world.append(c);
    }
    return world;
  }

  // Fills a 216 × 135 thumbnail, cropped to fill like the app's.
  function fill(thumb, item) {
    thumb.replaceChildren();
    thumb.classList.toggle("clear", item.kind === "Window" && !item.art);
    if (item.art) {
      const a = document.createElement("div");
      a.className = "art " + item.art;
      a.innerHTML = "<i></i>";
      thumb.append(a);
      return;
    }
    const bw = 216, bh = 135, { x, y, w, h } = item.rect;
    const k = Math.max(bw / w, bh / h);
    const world = item.world.cloneNode(true);
    world.style.transform = `translate(${bw / 2 - (x + w / 2) * k}px, ${bh / 2 - (y + h / 2) * k}px) scale(${k})`;
    thumb.append(world);
  }

  // What's on the shelf, newest first.
  const now = Date.now();
  let items = [
    { id: 3, kind: "Area", title: "Terminal", art: "s-terminal", text: "Build succeeded. Universal app signed.", time: now - 4 * 60e3 },
    { id: 2, kind: "Window", title: "Photos", art: "s-photo", text: "", time: now - 26 * 60e3 },
    { id: 1, kind: "Area", title: "Notes", art: "s-doc", text: "Launch checklist: icon, release notes, update feed", time: now - 52 * 60e3, pinned: true },
  ];
  let nextId = 4;
  let paused = false;

  function copyString(t) {
    try { navigator.clipboard && navigator.clipboard.writeText(t).catch(() => {}); } catch (_) { /* not allowed here */ }
  }

  // The menu bar icon shows a check for a second after a capture.
  let iconTimer;
  function flashIcon() {
    icon.classList.add("captured");
    clearTimeout(iconTimer);
    iconTimer = setTimeout(() => icon.classList.remove("captured"), 1000);
  }

  // ---------- A small note that says what was copied ----------

  const hud = $("hud");
  let hudTimer;
  function showHud(title, detail, near) {
    $("hudTitle").textContent = title;
    $("hudDetail").textContent = detail || "";
    hud.classList.add("on");
    const w = hud.offsetWidth, h = hud.offsetHeight;
    let x = near.x + near.w / 2 - w / 2, y = near.y + near.h + 12;
    if (y + h > H - 8) y = near.y - h - 12;
    hud.style.left = Math.min(Math.max(x, 8), W - w - 8) + "px";
    hud.style.top = Math.max(8, y) + "px";
    clearTimeout(hudTimer);
    hudTimer = setTimeout(() => hud.classList.remove("on"), 2200);
  }
  const editorNote = (near) => showHud("Editing happens in the app", "Arrows, boxes, text, speech bubbles, blur, numbered steps and crop.", near);

  // ---------- Choosing what to capture ----------

  const pick = $("pick"), sel = $("sel"), selSize = $("selSize"), winHl = $("winHl"), hint = $("hint");
  const HINTS = {
    area: "Drag to select an area   ·   Space for a window   ·   Esc to cancel",
    window: "Click a window to capture it   ·   Space for an area   ·   Esc to cancel",
    text: "Select the text or QR code to copy   ·   Esc to cancel",
  };
  let mode = null, start = null, cur = null;

  function startPick(m) {
    setMenu(false);
    closeCtx();
    hideFan();
    layout();
    mode = m;
    start = cur = null;
    pick.className = "pick on" + (m === "window" ? " win" : "");
    hint.textContent = HINTS[m];
    winHl.classList.remove("on");
  }
  // The window under the pointer, front one first.
  function windowAt(p) {
    for (const el of [chatWin, target]) { const r = rectOf(el); if (r.w && inside(p, r)) return { el, r }; }
    return null;
  }
  function endPick() { mode = null; start = null; pick.className = "pick"; }
  function switchMode() {
    mode = mode === "area" ? "window" : "area";
    start = null;
    pick.className = "pick on" + (mode === "window" ? " win" : "");
    hint.textContent = HINTS[mode];
  }
  function selRect() {
    const x1 = Math.max(0, Math.min(start.x, cur.x)), y1 = Math.max(0, Math.min(start.y, cur.y));
    const x2 = Math.min(W, Math.max(start.x, cur.x)), y2 = Math.min(H, Math.max(start.y, cur.y));
    return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
  }
  function drawSel() {
    const r = selRect();
    pick.classList.add("has-sel");
    Object.assign(sel.style, { left: r.x + "px", top: r.y + "px", width: r.w + "px", height: r.h + "px" });
    selSize.textContent = `${Math.round(r.w)} × ${Math.round(r.h)}`;
    selSize.classList.toggle("inside", r.y < 30);
  }

  pick.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    const p = toLocal(e.clientX, e.clientY);
    if (mode === "window") {
      const w = windowAt(p);
      if (w) { endPick(); capture("Window", w.r, w.el); }
      return;
    }
    pick.setPointerCapture(e.pointerId);
    start = cur = p;
  });
  pick.addEventListener("pointermove", (e) => {
    const p = toLocal(e.clientX, e.clientY);
    if (mode === "window") {
      const w = windowAt(p);
      winHl.classList.toggle("on", !!w);
      if (w) Object.assign(winHl.style, { left: w.r.x + "px", top: w.r.y + "px", width: w.r.w + "px", height: w.r.h + "px", borderRadius: 14 / s + "px" });
      return;
    }
    if (!start) return;
    cur = p;
    drawSel();
  });
  pick.addEventListener("pointerup", () => {
    if (!start || mode === "window") return;
    const r = selRect(), m = mode;
    start = null;
    if (r.w < 4 || r.h < 4) { pick.classList.remove("has-sel"); return; }
    endPick();
    if (m === "text") grabText(r); else capture("Area", r);
  });

  // The words on the page inside an area (stands in for reading the pixels).
  function textIn(r) {
    const els = [target.querySelector(".window-title"), ...target.querySelectorAll(".window-foot > span"),
      bar.querySelector("strong"), $("clock"), chatWin.querySelector(".window-title"), ...chatLog.querySelectorAll(":scope > .msg:not(.pic)")];
    const parts = [];
    for (const el of els) {
      if (!el) continue;
      const b = rectOf(el);
      if (inside({ x: b.x + b.w / 2, y: b.y + b.h / 2 }, r)) parts.push(el.textContent.replace(/\s+/g, " ").trim());
    }
    return parts.join("\n");
  }
  function grabText(r) {
    const t = textIn(r);
    flashIcon();
    if (!t) return showHud("No text found", "Try selecting a little more around it.", r);
    copyString(t);
    const lines = t.split("\n").length;
    showHud(lines === 1 ? "Copied text" : `Copied ${lines} lines of text`, t.slice(0, 80), r);
  }

  function capture(kind, rect, win) {
    const world = snapshot(kind, win);
    flashIcon();
    const title = kind === "Screen" ? "Full screen"
      : kind === "Window" ? win.querySelector(".window-title").textContent
      : overlaps(rect, rectOf(target)) ? "Weekly sign-ups" : overlaps(rect, rectOf(chatWin)) ? "Team chat" : "Screenshot";
    const item = { id: nextId++, kind, title, rect: { x: rect.x, y: rect.y, w: rect.w, h: rect.h }, world,
      text: textIn(rect), time: Date.now() };
    setClip(item);   // every capture is copied, like the app
    stepDone(1);
    if (paused) return;   // Pause Shelf History: clipboard only, nothing kept
    items.unshift(item);
    showCard(item, rect);
  }

  function run(m) {
    if (narrow.matches) return mobileCapture();
    if (m === "full") { setMenu(false); layout(); capture("Screen", { x: 0, y: 0, w: W, h: H }); }
    else startPick(m);
  }

  // ---------- The corner card ----------

  const card = $("card"), cardThumb = $("cardThumb"), cardTitle = $("cardTitle"), cardSub = $("cardSub");
  let cardItem = null, newCount = 0, cardShowing = false, closing = false, cardHover = false, pointerDown = false;
  let note = null, noteTimer, tuckTimer;

  card.addEventListener("pointerenter", () => { cardHover = true; });
  card.addEventListener("pointerleave", () => { cardHover = false; });

  function renderSub() {
    if (!cardItem) return;
    cardSub.textContent = note || (newCount > 1 ? `${newCount} new` : `${cardItem.kind} · ${fmtTime(cardItem.time)}`);
    cardSub.classList.toggle("ok", note === "Copied");
  }
  function setNote(t) {
    note = t;
    clearTimeout(noteTimer);
    renderSub();
    if (t) noteTimer = setTimeout(() => { note = null; renderSub(); }, 2000);
  }
  function showCard(item, from) {
    const was = cardShowing && !closing;
    cardItem = item;
    newCount = was ? newCount + 1 : 1;
    cardTitle.textContent = item.title;
    fill(cardThumb, item);
    card.classList.toggle("n2", newCount === 2);
    card.classList.toggle("n3", newCount > 2);
    setNote("Copied");
    cardShowing = true;
    closing = false;
    card.classList.remove("tuck");
    card.classList.add("show");
    edgeCardShown();
    scheduleTuck(3000);
    if (!reduceMotion) fly(item, from);
  }
  // It tucks into the edge tab by itself, but never while the pointer is on it.
  function scheduleTuck(ms) {
    clearTimeout(tuckTimer);
    tuckTimer = setTimeout(() => {
      if (!cardShowing) return;
      if (cardHover || pointerDown) scheduleTuck(1000); else closeCard();
    }, ms);
  }
  function closeCard() {
    clearTimeout(tuckTimer);
    if (!cardShowing || closing) return;
    closing = true;
    card.classList.add("tuck");
    setTimeout(() => {
      if (!closing) return;   // a new capture reopened it
      closing = false;
      cardShowing = false;
      card.classList.remove("show", "tuck");
      newCount = 0;
      edgeCardClosed();
    }, reduceMotion ? 120 : 220);
  }
  function fly(item, from) {
    cardThumb.classList.add("waiting");
    const f = document.createElement("div");
    f.className = "fly";
    Object.assign(f.style, { left: from.x + "px", top: from.y + "px", width: from.w + "px", height: from.h + "px" });
    const world = item.world.cloneNode(true);
    world.style.transform = `translate(${-from.x}px, ${-from.y}px)`;
    f.append(world);
    scr.append(f);
    const to = rectOf(cardThumb);
    f.getBoundingClientRect();
    requestAnimationFrame(() => {
      f.style.transform = `translate(${to.x - from.x}px, ${to.y - from.y}px) scale(${to.w / from.w}, ${to.h / from.h})`;
    });
    setTimeout(() => { cardThumb.classList.remove("waiting"); f.remove(); }, 470);
  }

  let thumbClick;
  cardThumb.addEventListener("click", () => {
    clearTimeout(thumbClick);
    thumbClick = setTimeout(() => { setNote("Copied"); if (cardItem) setClip(cardItem); }, 220);
  });
  cardThumb.addEventListener("dblclick", () => { clearTimeout(thumbClick); editorNote(rectOf(card)); });
  $("cardEdit").addEventListener("click", () => editorNote(rectOf(card)));
  $("cardSave").addEventListener("click", () => setNote("Saved"));
  $("cardClose").addEventListener("click", closeCard);

  // ---------- The edge tab and the stack ----------

  const tab = $("tab"), tabThumb = $("tabThumb"), tabLabel = $("tabLabel");
  const fan = $("fan"), list = $("list"), search = $("search"), searchClear = $("searchClear"), empty = $("empty");
  const TAB = () => ({ x: W - 236, y: H - 292, w: 236, h: 172 });
  let dock = "hidden", fanShown = false, idle = [], leaveTimer = null, copiedId = null, copiedTimer, lastP = { x: -1, y: -1 };

  function renderTab() {
    const first = items[0];
    if (first) fill(tabThumb, first);
    tabLabel.textContent = first && copiedId === first.id ? "Copied" : `${items.length} on shelf`;
  }
  function applyDock(instant) {
    const off = cardShowing || !items.length;
    tab.classList.toggle("instant", !!instant || off);
    tab.classList.toggle("hidden", off || dock === "hidden");
    tab.classList.toggle("sliver", !off && dock === "sliver");
    if (off) hideFan();
  }
  function setDock(d) {
    dock = d;
    if (d !== "tab") hideFan();
    applyDock(false);
  }
  function clearIdle() { idle.forEach(clearTimeout); idle = []; }
  // Any use restarts the timeline: a sliver after 5 seconds, gone after 5 minutes.
  function touch() {
    clearIdle();
    setDock("tab");
    idle.push(setTimeout(() => setDock("sliver"), 5000));
    idle.push(setTimeout(() => setDock("hidden"), 300000));
  }
  function edgeCardShown() { clearIdle(); hideFan(); applyDock(true); }
  function edgeCardClosed() {
    renderTab();
    tab.classList.add("instant", "hidden");
    void tab.offsetWidth;
    touch();
  }

  function showFan() {
    if (fanShown || cardShowing || !items.length) return;
    stepDone(3);
    fanShown = true;
    fan.classList.add("open");
    buildList(true);
    requestAnimationFrame(() => requestAnimationFrame(() => {
      fan.classList.add("spread");
      list.querySelectorAll(".item.in").forEach((n) => n.classList.remove("in"));
    }));
  }
  function hideFan() {
    if (!fanShown) return;
    fanShown = false;
    fan.classList.remove("open", "spread");
    clearTimeout(leaveTimer);
    leaveTimer = null;
    closeCtx();
    search.value = "";
    search.blur();
  }

  function makeItem(it, off, entering) {
    const el = document.createElement("div");
    el.className = "item glass" + (entering ? " in" : "") + (it.pinned ? " pinned" : "") + (copiedId === it.id ? " copied" : "");
    el.style.setProperty("--off", off + "px");
    el.dataset.id = it.id;
    el.title = "Click to copy, double-click to edit. Right-click for more.";
    const th = document.createElement("div");
    th.className = "thumb";
    fill(th, it);
    el.append(th);
    el.insertAdjacentHTML("beforeend",
      '<span class="pin"><svg viewBox="0 0 16 16"><path d="M10.2 1.2l4.6 4.6-1.6.6-2.7 2.7.2 3.4-1.3 1.3-2.9-2.9-4.3 4.3-.9-.9 4.3-4.3-2.9-2.9 1.3-1.3 3.4.2 2.7-2.7z"/></svg></span>' +
      '<span class="done"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#fff"/><path d="M7.5 12.5l3 3 6-6.5" fill="none" stroke="#1c1c1e" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg></span>' +
      '<button class="x" aria-label="Remove from shelf" title="Remove from shelf"><svg viewBox="0 0 10 10"><path d="M2 2l6 6m0-6-6 6"/></svg></button>');
    return el;
  }
  function buildList(entering) {
    const q = search.value.trim().toLowerCase();
    const results = q ? items.filter((it) => (it.title + " " + it.text).toLowerCase().includes(q)) : items.slice();
    // Oldest at the top, newest at the bottom next to the tab. The list is a
    // reversed column, so it opens scrolled to the newest; scroll up for older.
    list.replaceChildren(...results.map((it, i) =>
      makeItem(it, entering && i <= 6 ? i * 161 + 16 : 0, entering)));
    empty.hidden = results.length > 0;
    if (!results.length) empty.textContent = `No screenshot contains \u201C${search.value.trim()}\u201D`;
    searchClear.hidden = !search.value;
    // Always a whole number of cards, so none is shown cut in half.
    const room = H - 292 - 34 - 10 - 24;
    const fit = Math.max(1, Math.min(7, Math.floor((room + 10) / 161)));
    list.style.height = results.length ? Math.min(results.length, fit) * 161 - 10 + "px" : "0px";
    list.scrollTop = 0;
  }
  const itemOf = (el) => items.find((i) => i.id === Number(el.dataset.id));

  function markCopied(it) {
    setClip(it);
    copiedId = it.id;
    clearTimeout(copiedTimer);
    refreshCopied();
    copiedTimer = setTimeout(() => { copiedId = null; refreshCopied(); }, 1200);
  }
  function refreshCopied() {
    list.querySelectorAll(".item").forEach((n) => n.classList.toggle("copied", Number(n.dataset.id) === copiedId));
    renderTab();
  }
  function removeItems(ids) {
    list.querySelectorAll(".item").forEach((n) => { if (ids.includes(Number(n.dataset.id))) n.classList.add("gone"); });
    setTimeout(() => {
      items = items.filter((i) => !ids.includes(i.id));
      renderTab();
      if (!items.length) { hideFan(); applyDock(true); }
      else if (fanShown) buildList(false);
    }, 220);
  }

  let hovered = null;
  function setHover(el) {
    if (hovered === el) return;
    if (hovered) hovered.classList.remove("hover", "pressed");
    hovered = el;
    if (el) el.classList.add("hover");
  }
  list.addEventListener("pointerover", (e) => setHover(e.target.closest(".item")));
  list.addEventListener("pointerleave", () => setHover(null));
  list.addEventListener("pointerdown", (e) => { const el = e.target.closest(".item"); if (el && e.button === 0) el.classList.add("pressed"); });
  list.addEventListener("pointerup", () => list.querySelectorAll(".pressed").forEach((n) => n.classList.remove("pressed")));
  let itemClick;
  list.addEventListener("click", (e) => {
    const el = e.target.closest(".item");
    if (!el) return;
    const it = itemOf(el);
    if (e.target.closest(".x")) return removeItems([it.id]);
    clearTimeout(itemClick);
    itemClick = setTimeout(() => markCopied(it), 220);
  });
  list.addEventListener("dblclick", (e) => {
    const el = e.target.closest(".item");
    if (!el) return;
    clearTimeout(itemClick);
    editorNote(rectOf(el));
  });
  list.addEventListener("contextmenu", (e) => {
    const el = e.target.closest(".item");
    if (!el) return;
    e.preventDefault();
    openCtx(itemOf(el), el, toLocal(e.clientX, e.clientY));
  });

  tab.addEventListener("click", () => { if (items[0]) markCopied(items[0]); });

  search.addEventListener("input", () => { buildList(false); fan.classList.add("spread"); });
  searchClear.addEventListener("click", (e) => { e.preventDefault(); search.value = ""; buildList(false); search.focus(); });

  // The right-click menu on a screenshot in the stack
  const ctx = $("ctx");
  let ctxItem = null, ctxEl = null;
  function openCtx(it, el, p) {
    ctxItem = it;
    ctxEl = el;
    ctx.innerHTML = '<button data-a="edit">Edit</button><button data-a="copy">Copy</button>' +
      '<button data-a="text">Copy Text</button><button data-a="save">Save as a File</button>' +
      `<button data-a="pin">${it.pinned ? "Unpin" : "Pin"}</button><hr><button data-a="remove">Remove from Shelf</button>`;
    ctx.classList.add("on");
    const w = ctx.offsetWidth, h = ctx.offsetHeight;
    ctx.style.left = Math.min(p.x, W - w - 4) + "px";
    ctx.style.top = Math.min(p.y, H - h - 4) + "px";
  }
  function closeCtx() { ctx.classList.remove("on"); ctxItem = null; }
  ctx.addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b || !ctxItem) return;
    const it = ctxItem, r = rectOf(ctxEl);
    closeCtx();
    switch (b.dataset.a) {
      case "edit": editorNote(r); break;
      case "copy": markCopied(it); break;
      case "text":
        if (it.text) { copyString(it.text); showHud("Copied text", it.text.slice(0, 80), r); }
        else showHud("No text found", "There are no words in this screenshot.", r);
        break;
      case "save": showHud("Saved to Pictures", it.title + ".png", r); break;
      case "pin": it.pinned = !it.pinned; ctxEl.classList.toggle("pinned", it.pinned); break;
      case "remove": removeItems([it.id]); break;
    }
  });

  // Pointing at the right edge brings the tab back; leaving the stack closes it.
  function pointerMoved(p) {
    if (cardShowing || !items.length || mode) return;
    const full = TAB();
    if (dock !== "tab") {
      const nearEdge = p.x >= W - (dock === "hidden" ? 3 : 16) && p.x <= W + 40;
      const band = dock === "hidden" ? grow(full, 100) : full;
      if (nearEdge && p.y >= band.y && p.y <= band.y + band.h) { clearIdle(); setDock("tab"); showFan(); }
      return;
    }
    const m = 48;
    const overTab = inside(p, full);
    const nearTab = inside(p, grow(full, m));
    const nearFan = fanShown && inside(p, grow(rectOf(fan), m));
    if (overTab || nearFan || (fanShown && nearTab)) {
      clearTimeout(leaveTimer);
      leaveTimer = null;
      clearIdle();
      if (!fanShown && overTab) showFan();
    } else if (fanShown && !search.value && !ctx.classList.contains("on") && !leaveTimer) {
      leaveTimer = setTimeout(() => {
        leaveTimer = null;
        const back = inside(lastP, grow(rectOf(fan), m)) || inside(lastP, grow(TAB(), m));
        if (!back && !search.value && !ctx.classList.contains("on")) { hideFan(); touch(); }
      }, 700);
    }
  }
  document.addEventListener("pointermove", (e) => {
    if (narrow.matches) return;
    lastP = toLocal(e.clientX, e.clientY);
    pointerMoved(lastP);
  }, { passive: true });

  // A click anywhere else turns the tab into a sliver.
  document.addEventListener("pointerdown", (e) => {
    pointerDown = true;
    if (!ctx.contains(e.target)) closeCtx();
    if (mode || narrow.matches) return;
    const own = [tab, fan, card, ctx, panel, icon].some((el) => el.contains(e.target));
    if (!own && dock === "tab" && !cardShowing && items.length) setDock("sliver");
  });
  document.addEventListener("pointerup", () => { pointerDown = false; });
  document.addEventListener("dragend", () => { pointerDown = false; });

  // ---------- Menu actions and shortcuts ----------

  panel.addEventListener("click", (e) => {
    const b = e.target.closest("button.mi");
    if (!b) return;
    const a = b.dataset.act;
    if (a === "pause") {
      paused = !paused;
      b.setAttribute("aria-checked", String(paused));
      setMenu(false);
      return;
    }
    setMenu(false);
    setTimeout(() => run(a), 160);
  });

  // On narrow screens the shelf is a still picture; the menu just adds to it.
  let mCount = 3;
  function mobileCapture() {
    setMenu(false);
    flashIcon();
    if (!paused) $("mCount").textContent = `${++mCount} on shelf`;
  }

  function stageVisible() {
    const r = screenEl.getBoundingClientRect();
    return r.width > 0 && r.bottom > 80 && r.top < window.innerHeight - 80;
  }

  function light(id, on) { const k = $(id); if (k) k.classList.toggle("down", on); }
  document.addEventListener("keydown", (e) => {
    if (e.key === "Alt") light("kOpt", true);
    if (e.key === "Shift") light("kShift", true);
    if (e.key === "Escape") {
      if (mode) { e.preventDefault(); endPick(); return; }
      if (ctx.classList.contains("on")) { closeCtx(); return; }
      if (e.target === search && search.value) { search.value = ""; buildList(false); return; }
      if (fanShown) { hideFan(); touch(); }
      return;
    }
    if (mode && e.code === "Space") {
      e.preventDefault();
      if (mode !== "text") switchMode();
      return;
    }
    if (e.target === search || !e.altKey || e.metaKey || e.ctrlKey) return;
    let m = null;
    if (e.code === "KeyS") m = e.shiftKey ? "area" : "full";
    else if (e.code === "Digit2" && e.shiftKey) m = "window";
    else if (e.code === "KeyT" && e.shiftKey) m = "text";
    if (!m || !stageVisible()) return;
    e.preventDefault();
    if (e.code === "KeyS") light("kS", true);
    if (mode) endPick();
    run(m);
  });
  document.addEventListener("keyup", (e) => {
    if (e.key === "Alt") light("kOpt", false);
    if (e.key === "Shift") light("kShift", false);
    if (e.code === "KeyS") light("kS", false);
  });
  window.addEventListener("blur", () => ["kOpt", "kShift", "kS"].forEach((id) => light(id, false)));

  // ---------- The clipboard and the chat ----------
  // A pretend screenshot can't go on your real clipboard as a picture, so the
  // page keeps it and puts a short marker text there instead. Pasting a real
  // screenshot (from Sidesnap or macOS) works too: it only appears here.

  const CLIP_MARK = "Sidesnap demo screenshot";
  let clip = null;
  function setClip(item) {
    clip = item;
    copyString(CLIP_MARK);
    if (!stepIsDone(2)) chatWin.classList.add("nudge");
  }

  const chatLog = $("chatLog"), composer = $("composer");
  const replies = ["Perfect, thanks!", "Got it, that's the one.", "Nice, sharing it with the team.", "Thanks!"];
  let replyN = 0, replyTimer;

  // Draws a shelf screenshot into a box of at most bw × bh page pixels.
  function pictureOf(item, bw, bh) {
    const box = document.createElement("div");
    box.className = "pic-box";
    if (item.art) {
      box.style.width = bw + "px"; box.style.height = bw * 135 / 216 + "px";
      const a = document.createElement("div");
      a.className = "art " + item.art;
      a.innerHTML = "<i></i>";
      a.style.cssText = `position:absolute;left:0;top:0;width:216px;height:135px;transform:scale(${bw / 216});transform-origin:0 0`;
      box.append(a);
      return box;
    }
    const { x, y, w, h } = item.rect;
    const k = Math.min(bw / w, bh / h);
    box.style.width = w * k + "px"; box.style.height = h * k + "px";
    const world = item.world.cloneNode(true);
    world.style.transform = `translate(${-x * k}px, ${-y * k}px) scale(${k})`;
    box.append(world);
    return box;
  }
  function addMsg(cls, content) {
    const m = document.createElement("div");
    m.className = "msg " + cls;
    if (typeof content === "string") m.textContent = content; else m.append(content);
    chatLog.append(m);
    chatLog.scrollTop = chatLog.scrollHeight;
    return m;
  }
  function sendPicture(node) {
    addMsg("me pic", node);
    chatWin.classList.remove("nudge");
    stepDone(2);
    clearTimeout(replyTimer);
    replyTimer = setTimeout(() => {
      const m = addMsg("them", replies[replyN++ % replies.length]);
      m.insertAdjacentHTML("afterbegin", "<b>Maya</b>");
    }, 1100);
  }
  function sendItem(item) { if (item) sendPicture(pictureOf(item, 180, 120)); }
  function sendFile(file) {
    const img = new Image();
    img.alt = "Pasted screenshot";
    img.src = URL.createObjectURL(file);
    sendPicture(img);
  }

  // ⌘V in the chat, or anywhere on the demo when nothing else is being typed in.
  document.addEventListener("paste", (e) => {
    const inChat = chatWin.contains(document.activeElement);
    const typing = !inChat && document.activeElement && document.activeElement.matches("input, textarea, [contenteditable]");
    if (typing || (!inChat && !stageVisible())) return;
    const dt = e.clipboardData;
    const file = dt && [...dt.files].find((f) => f.type.startsWith("image/"));
    const text = dt ? dt.getData("text/plain") : "";
    if (file) { e.preventDefault(); sendFile(file); return; }
    if (clip && (!text || text === CLIP_MARK)) { e.preventDefault(); sendItem(clip); return; }
    if (inChat) {
      e.preventDefault();
      if (text) addMsg("me", text.slice(0, 300));
      else addMsg("note", "Take a screenshot first: press ⌥⇧S and drag over the chart.");
    }
  });
  composer.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      const t = composer.textContent.trim();
      if (t) { addMsg("me", t.slice(0, 300)); composer.textContent = ""; }
    }
  });
  // Drag the card or a shelf screenshot into the chat (or a real image file).
  function dragOut(el, getItem) {
    el.draggable = true;
    el.addEventListener("dragstart", (e) => {
      const it = getItem(e);
      if (!it) return e.preventDefault();
      e.dataTransfer.setData("text/x-sidesnap", String(it.id));
      e.dataTransfer.setData("text/plain", CLIP_MARK);
      e.dataTransfer.effectAllowed = "copy";
    });
  }
  dragOut(cardThumb, () => cardItem);
  list.addEventListener("dragstart", (e) => {
    const el = e.target.closest && e.target.closest(".item");
    const it = el && itemOf(el);
    if (!it) return;
    e.dataTransfer.setData("text/x-sidesnap", String(it.id));
    e.dataTransfer.setData("text/plain", CLIP_MARK);
  });
  const observeItems = new MutationObserver(() => list.querySelectorAll(".item").forEach((n) => { n.draggable = true; }));
  observeItems.observe(list, { childList: true });
  chatWin.addEventListener("dragover", (e) => { e.preventDefault(); e.dataTransfer.dropEffect = "copy"; chatWin.classList.add("drop"); });
  chatWin.addEventListener("dragleave", (e) => { if (!chatWin.contains(e.relatedTarget)) chatWin.classList.remove("drop"); });
  chatWin.addEventListener("drop", (e) => {
    e.preventDefault();
    chatWin.classList.remove("drop");
    const id = Number(e.dataTransfer.getData("text/x-sidesnap"));
    const file = [...e.dataTransfer.files].find((f) => f.type.startsWith("image/"));
    if (id) sendItem(items.find((i) => i.id === id) || (clip && clip.id === id ? clip : null));
    else if (file) sendFile(file);
  });

  // ---------- Try it: the three steps under the demo ----------
  const steps = [...document.querySelectorAll("#trySteps li")];
  const doneSteps = new Set();
  const stepIsDone = (n) => doneSteps.has(n);
  function showSteps() {
    const next = [1, 2, 3].find((n) => !doneSteps.has(n));
    steps.forEach((li) => {
      const n = Number(li.dataset.step);
      li.classList.toggle("done", doneSteps.has(n));
      li.classList.toggle("now", n === next);
    });
  }
  function stepDone(n) { doneSteps.add(n); showSteps(); }
  showSteps();

  // The tab slides in shortly after the page opens.
  renderTab();
  setTimeout(() => { if (!cardShowing) { tab.classList.add("instant", "hidden"); void tab.offsetWidth; touch(); } }, 700);

  // ---------- Install: play the three steps in turn while visible ----------

  const installStage = document.getElementById("installStage");
  if (installStage) {
    const wins = [...installStage.querySelectorAll(".mini-win")];
    const captions = [...document.querySelectorAll(".install-steps li")];
    let t = [];
    const clear = () => { t.forEach(clearTimeout); t = []; };
    const later = (ms, fn) => t.push(setTimeout(fn, ms));
    const setActive = (n) => {
      wins.forEach((w, i) => w.classList.toggle("active", i === n));
      captions.forEach((c, i) => c.classList.toggle("active", i === n));
    };
    function play() {
      clear();
      installStage.classList.add("playing");
      wins.forEach((w) => w.classList.remove("done", "press"));
      setActive(0);
      later(400, () => wins[0].classList.add("done"));
      later(1900, () => setActive(1));
      later(2500, () => wins[1].classList.add("press"));
      later(2700, () => { wins[1].classList.remove("press"); wins[1].classList.add("done"); });
      later(3800, () => setActive(2));
      later(4400, () => wins[2].classList.add("done"));
      later(6600, play);
    }
    function stop() {
      clear();
      installStage.classList.remove("playing");
      wins.forEach((w) => w.classList.add("done"));
      setActive(-1);
    }
    if (reduceMotion || !("IntersectionObserver" in window)) {
      stop();
    } else {
      new IntersectionObserver(([e]) => (e.isIntersecting ? play() : stop()), { threshold: 0.5 }).observe(installStage);
    }
  }

  // ---------- Menu bar: soft edge only once content scrolls under it ----------

  const menubar = document.querySelector(".menubar");
  const onScroll = () => menubar.classList.toggle("scrolled", window.scrollY > 4);
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // ---------- Menu bar clock ----------

  const clock = document.getElementById("clock");
  function tick() {
    const d = new Date();
    clock.textContent = d.toLocaleDateString(undefined, { weekday: "short" }) + " " +
      d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  }
  tick();
  setInterval(tick, 15000);
})();
