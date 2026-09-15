#!/usr/bin/env bash
# Assemble the landing page (site/ + the README's screenshots) into build/site — what GitHub Pages
# serves (.github/workflows/pages.yml). Preview locally: the "site" entry in .claude/launch.json, or
#   scripts/build_site.sh && python3 -m http.server 8765 --directory build/site
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/build/site"
rm -rf "$OUT"
mkdir -p "$OUT/images"
cp -R "$ROOT_DIR/site/." "$OUT/"
cp "$ROOT_DIR"/docs/images/*.png "$ROOT_DIR"/docs/images/*.webp "$ROOT_DIR"/docs/images/*.jpg "$OUT/images/"
# The social card (1200×630), made by scripts/make_launch_assets.swift; committed with the screenshots.
# sitemap.xml, dated with the last commit that touched the page or its images.
LASTMOD="$(git -C "$ROOT_DIR" log -1 --format=%cs -- site docs/images 2>/dev/null)"
cat > "$OUT/sitemap.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://smithplus.github.io/Osmotic/</loc>
    <lastmod>${LASTMOD:-$(date +%F)}</lastmod>
  </url>
</urlset>
XML
echo "$OUT"
