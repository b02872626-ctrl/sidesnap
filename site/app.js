// Sidesnap landing page: menu bar clock, the menu, a pretend capture onto the
// edge shelf, and the install steps. Nothing is saved or sent anywhere.
(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------- Menu ----------

  const icon = document.getElementById("menuIcon");
  const panel = document.getElementById("panel");
  function setMenu(open) {
    panel.classList.toggle("hidden", !open);
    icon.setAttribute("aria-expanded", String(open));
  }
  icon.addEventListener("click", () => setMenu(panel.classList.contains("hidden")));
  document.addEventListener("click", (e) => {
    if (!panel.contains(e.target) && !icon.contains(e.target)) setMenu(false);
  });

  // ---------- A pretend capture: select, flash, card, onto the shelf ----------

  const wrap = document.getElementById("stageWrap");
  const flash = document.getElementById("flash");
  const card = document.getElementById("cornerCard");
  const tabShot = document.getElementById("tabShot");
  const tabCount = document.getElementById("tabCount");
  const fan = document.querySelector(".edge .fan");
  let count = 3, busy = false, timers = [];
  const at = (ms, fn) => timers.push(setTimeout(fn, ms));

  function capture() {
    if (busy) return;
    busy = true;
    setMenu(false);
    timers.forEach(clearTimeout); timers = [];
    const fast = reduceMotion ? 0.3 : 1;
    wrap.classList.add("selecting");
    at(900 * fast, () => {
      wrap.classList.remove("selecting");
      flash.classList.add("on");
      requestAnimationFrame(() => requestAnimationFrame(() => flash.classList.remove("on")));
      card.classList.remove("tuck");
      card.classList.add("show");
    });
    // The card tucks into the shelf by itself a few seconds later.
    at(3400 * fast, () => {
      card.classList.add("tuck");
      count += 1;
      tabCount.textContent = `${count} on shelf`;
      // The old newest moves into the fan; the new one sits on the tab.
      const moved = document.createElement("div");
      moved.className = tabShot.className.replace("tab-shot", "").trim();
      moved.innerHTML = "<i></i>";
      fan.appendChild(moved);
      while (fan.children.length > 4) fan.firstElementChild.remove();
      tabShot.className = "shot tab-shot s-chart";
      const tab = tabShot.parentElement;
      tab.classList.remove("bump"); void tab.offsetWidth; tab.classList.add("bump");
    });
    at(3800 * fast, () => { card.classList.remove("show", "tuck"); busy = false; });
  }

  document.getElementById("menuCapture").addEventListener("click", capture);

  // ⌥⇧S on the page plays the same capture, with the keys lighting up.
  const keys = { Alt: "kOpt", Shift: "kShift", KeyS: "kS" };
  function light(id, on) { const k = document.getElementById(id); if (k) k.classList.toggle("down", on); }
  document.addEventListener("keydown", (e) => {
    if (e.key === "Alt") light(keys.Alt, true);
    if (e.key === "Shift") light(keys.Shift, true);
    if (e.code === "KeyS" && e.altKey && e.shiftKey) {
      e.preventDefault();
      light(keys.KeyS, true);
      capture();
    }
  });
  document.addEventListener("keyup", (e) => {
    if (e.key === "Alt") light(keys.Alt, false);
    if (e.key === "Shift") light(keys.Shift, false);
    if (e.code === "KeyS") light(keys.KeyS, false);
  });
  window.addEventListener("blur", () => Object.values(keys).forEach((id) => light(id, false)));

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

  const bar = document.querySelector(".menubar");
  const onScroll = () => bar.classList.toggle("scrolled", window.scrollY > 4);
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
