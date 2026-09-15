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
    if (peers.length > 1) el.style.setProperty("--i", String(Math.min(peers.indexOf(el), 4)));
  }
  const fold = window.innerHeight;
  for (const el of blocks) {
    if (el.getBoundingClientRect().top < fold) el.classList.add("is-in");
  }
  document.documentElement.classList.add("reveal-ready");
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        e.target.classList.add("is-in");
        io.unobserve(e.target);
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.12 },
  );
  for (const el of blocks) if (!el.classList.contains("is-in")) io.observe(el);
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
    }
  } catch {
    // Keep the static links.
  }
})();
