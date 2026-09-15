// Landing page behavior. Everything here is an enhancement: without JS the page is complete and
// fully visible, and the download links go to the latest release page.

// Scroll reveals: blocks marked data-reveal rise in as they come into view (style.css "Motion").
// Blocks already on screen when this runs are shown as they are, so nothing blinks on load.
(() => {
  const blocks = [...document.querySelectorAll("[data-reveal]")];
  if (!("IntersectionObserver" in window) || blocks.length === 0) return;
  // Stagger siblings that reveal together (a grid, the FAQ), 70 ms apart via --i.
  for (const el of blocks) {
    if (el.style.getPropertyValue("--i")) continue;
    const peers = [...el.parentElement.children].filter((c) => c.hasAttribute("data-reveal"));
    if (peers.length > 1) el.style.setProperty("--i", String(Math.min(peers.indexOf(el), 6)));
  }
  const fold = window.innerHeight;
  for (const el of blocks) {
    if (el.getBoundingClientRect().top < fold) el.classList.add("is-in");
  }
  document.documentElement.classList.add("reveal-ready");
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        // In view, or already above it: a jump (a nav link, a fast scroll) can skip past a block
        // without it ever intersecting, and it must not stay hidden when the reader scrolls back.
        if (!e.isIntersecting && e.boundingClientRect.top > 0) continue;
        e.target.classList.add("is-in");
        io.unobserve(e.target);
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.12 },
  );
  for (const el of blocks) if (!el.classList.contains("is-in")) io.observe(el);
})();

const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");

// One scroll handler, coalesced into a frame: the docked keys and a few pixels of parallax under
// the hero shot.
(() => {
  const dock = document.querySelector(".navdock");
  const hero = document.querySelector(".shot--hero video, .shot--hero img");
  let queued = false;
  const update = () => {
    queued = false;
    const y = window.scrollY;
    if (dock) dock.classList.toggle("is-stuck", dock.getBoundingClientRect().top <= 0.5);
    // The hero image trails the page slightly, the way a part deeper in the case would.
    if (hero && !reduceMotion.matches) {
      const shift = Math.max(-14, Math.min(0, -y * 0.03));
      hero.style.transform = `translateY(${shift}px)`;
    }
  };
  const onScroll = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  };
  addEventListener("scroll", onScroll, { passive: true });
  addEventListener("resize", onScroll, { passive: true });
  update();
})();

// The key for the section you're reading latches, like the app's tabs.
(() => {
  const keys = [...document.querySelectorAll('.navdock .key[href^="#"]')];
  if (keys.length === 0 || !("IntersectionObserver" in window)) return;
  const sections = keys
    .map((key) => ({ key, section: document.querySelector(key.getAttribute("href")) }))
    .filter((pair) => pair.section);
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        const hit = sections.find((pair) => pair.section === e.target);
        for (const { key } of sections) key.classList.toggle("is-current", key === hit?.key);
      }
    },
    // A band across the middle of the window: whichever section crosses it owns the key.
    { rootMargin: "-45% 0px -45% 0px" },
  );
  for (const { section } of sections) io.observe(section);
})();

// Readouts count up when they come into view, the way a meter settles on its value: a beat after
// the readout lights (so the reader sees the needle move), brighter while it climbs.
(() => {
  const targets = [...document.querySelectorAll("[data-count]")];
  if (targets.length === 0 || !("IntersectionObserver" in window)) return;
  const run = (el) => {
    const end = Number(el.dataset.count);
    if (!Number.isFinite(end)) return;
    const line = el.closest("p") || el;
    if (reduceMotion.matches) {
      el.textContent = String(end);
      return;
    }
    el.textContent = "0";
    line.classList.add("is-counting");
    const started = performance.now();
    const tick = (now) => {
      const t = Math.min(1, (now - started) / 1000);
      const eased = 1 - Math.pow(1 - t, 3);  // ease-out, so it lands softly
      el.textContent = String(Math.round(end * eased));
      if (t < 1) return requestAnimationFrame(tick);
      line.classList.remove("is-counting");
    };
    requestAnimationFrame(tick);
  };
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        io.unobserve(e.target);
        // The readout flickers on first (lcd-boot, 460 ms); the meter moves after that.
        setTimeout(() => run(e.target), 520);
      }
    },
    { threshold: 0.6 },
  );
  for (const el of targets) io.observe(el);
})();

// The hero video: one session with a camera, on a loop. It starts once the page has loaded (the
// poster is what paints first), shows which step is on screen, stops while it is out of view, and
// the reader can pause it (a moving picture must be stoppable). Reduce Motion leaves the poster.
(() => {
  const figure = document.querySelector("[data-demo]");
  if (!figure) return;
  const video = figure.querySelector("video");
  const bar = figure.querySelector(".demo-bar");
  const stepName = figure.querySelector("[data-demo-step]");
  const toggle = figure.querySelector("[data-demo-toggle]");
  // "seconds:Name" pairs, written by scripts/make_demo_video.swift's storyboard.
  const steps = (figure.dataset.steps || "")
    .split(",")
    .map((pair) => pair.split(":"))
    .map(([t, name]) => ({ t: Number(t), name }))
    .filter((s) => Number.isFinite(s.t) && s.name);
  let userPaused = reduceMotion.matches;
  let inView = true;

  const label = () => {
    const now = video.currentTime;
    let current = steps[0];
    for (const s of steps) if (s.t <= now) current = s;
    if (current && stepName.textContent !== current.name) stepName.textContent = current.name;
  };
  const sync = () => {
    toggle.textContent = video.paused ? "Play" : "Pause";
    toggle.setAttribute("aria-pressed", String(video.paused));
  };
  const play = () => {
    if (userPaused || !inView) return;
    video.play().catch(() => {});  // autoplay refused: the poster stays, the key still works
  };

  video.addEventListener("timeupdate", label);
  video.addEventListener("play", sync);
  video.addEventListener("pause", sync);
  toggle.addEventListener("click", () => {
    userPaused = !video.paused;
    if (userPaused) video.pause();
    else {
      inView = true;
      play();
    }
  });

  const start = () => {
    bar.hidden = false;
    sync();
    new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          inView = e.isIntersecting;
          if (inView) play();
          else video.pause();
        }
      },
      { threshold: 0.2 },
    ).observe(figure);
  };
  if (document.readyState === "complete") start();
  else addEventListener("load", start, { once: true });
})();

// iOS Safari applies :active (the key press) only when a touch listener exists.
document.addEventListener("touchstart", () => {}, { passive: true });

// Point the download keys at the latest release's .dmg and show its version.
(async () => {
  try {
    const res = await fetch("https://api.github.com/repos/smithplus/Osmotic/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!res.ok) return;
    const release = await res.json();
    const dmg = (release.assets || []).find((a) => /^Osmotic-[\d.]+\.dmg$/.test(a.name));
    const version = String(release.tag_name || "").replace(/^v/, "");
    if (dmg && dmg.browser_download_url.startsWith("https://github.com/smithplus/Osmotic/releases/download/")) {
      for (const a of document.querySelectorAll("[data-download]")) a.href = dmg.browser_download_url;
    }
    if (/^\d+\.\d+\.\d+$/.test(version)) {
      for (const el of document.querySelectorAll("[data-version]")) el.textContent = `Version ${version}`;
      for (const el of document.querySelectorAll("[data-version-short]")) el.textContent = `v${version}`;
    }
  } catch {
    // Keep the static links.
  }
})();
