// Point the download keys at the latest release's .dmg and show its version. Without this (no JS,
// offline, API rate limit) the links still go to the latest release page.
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
