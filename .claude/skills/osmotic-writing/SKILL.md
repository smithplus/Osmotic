---
name: osmotic-writing
description: >
  Write, audit or rewrite anything people read about Osmotic: README, docs, landing page,
  release notes, CHANGELOG, Product Hunt copy, and the app's UI strings (English and
  Rioplatense Spanish). Use when writing or editing that copy, or when asked to review,
  improve, tighten or translate it. Adapted from the tabella-writing skill.
---

# osmotic-writing

## Pick the mode

- **Long form**: paragraphs (README, docs, landing sections, release notes, maker comments). All checks below.
- **UI microcopy**: keys, menu items, LCD readouts, notices, errors, empty states. Use the microcopy rules; skip sentence length and flow.

Mixed pieces (a notice with a title, body and key) get each part checked in its own mode.

## Long-form checks (in order)

For each finding: quote the text, say in one sentence why it's weak, give the rewrite.

1. **Sentence length.** Over 30 words: split it. One idea per sentence.
2. **Clutter.** "in order to" → to; "due to the fact that" → because; "has the ability to" → can; "a large number of" → many; "it is important to note that" → delete. Spanish: "con el fin de" → para; "en el caso de que" → si; "tiene la capacidad de" → puede; "a nivel de" → reformular.
3. **Adjectives without data.** "fast", "significantly", "very", "seamless", "powerful" → a number or nothing. We have real ones: ~33 MB/s measured on a Pocket 3; 83 tests; 14 real captures in the golden tests; the app idles at ~0% CPU.
4. **Weasel words.** "might", "should", "virtually", "potentially" → a commitment, a number, or an explicit "not tested yet".
5. **Jargon.** Define it for camera owners, not protocol engineers. "datalink", "DUML", "UVC" belong in docs/PROTOCOL.md, not the landing page. Say "the camera's own Wi-Fi", "a USB webcam".
6. **So what?** Each paragraph must tell a camera owner why it matters to them.
7. **Flow.** No repeated words in nearby sentences; vary rhythm; put ideas in the order the reader needs them.
8. **Osmotic voice** (below).

## Osmotic voice

- **Like a good gear manual**: plain, precise, calm. The UI is audio hardware (keys, LCD, LEDs); the copy is the printed legend on it. No startup hype: no "revolutionary", "the best", "#1", "the only", "magic", "effortless".
- **The owner's voice, not a launch template.** Anything posted as the owner (Product Hunt, release notes, replies) opens with the substance: no "Hi Product Hunt!", "Excited to share", "Thrilled to announce", no emoji garnish, no sign-off clichés. First person, concrete, short; a dry, slightly ironic line is welcome ("For a camera with its own Wi-Fi, that felt backwards."), as in the owner's own notes.
- **No em dashes (—).** They read as machine-written. Use a period, comma, colon or parentheses. En dashes stay in ranges (10–16 s).
- **Honest status.** Say what was tested on hardware and what wasn't ("Tested on a Pocket 3"; "Not yet tested"). Never imply DJI endorsement: keep "not affiliated with DJI".
- **Credit first.** Osmosis (Konrad Iturbe), Kaze for DJI (Brian Merchant) and the protocol researchers are named whenever the origin of the work comes up.
- **Privacy as fact, not slogan.** "No account, no analytics; nothing leaves your Mac except update checks to GitHub."
- **Direct answers.** FAQ answers start with Yes, No, a number, or "Not yet".
- **English for docs and the web; the app is English + Rioplatense Spanish** (voseo: "Abrí", "Elegila", "Reintentá"). Spanish must read native, never a literal translation.

## UI microcopy (the app)

- **Keys and menu items: verb first, macOS Title Case** (HIG): "Download New", "Show in Finder", "Disconnect". The key style uppercases them on screen; the string stays Title Case. Same action, same name everywhere.
- **LCD readouts: `LABEL: value`**, short uppercase labels (`FILES:`, `LEFT:`), values in data units (`32.4 MB/S`, `00:45`).
- **Notices and errors: what happened, why, what to do**, in that order. "Couldn't reach the camera. It may have turned off. Turn it on and Try Again." Never "An error occurred".
- **Empty states: what's missing + next step** ("No USB camera. Plug the camera in with USB-C and choose Webcam on it.").
- **No "Please", "Oops", "Successfully", or "we"** (the app isn't a "we"). No trailing period on keys; notices are full sentences with periods.
- **Numbers:** `42%` (no space), thousands separators by locale, `Format` in `Theme.swift` for sizes and times.
- **Spanish:** imperative voseo for keys ("Descargar nuevos" for actions in infinitive, as the catalog already does), no English words left in ("Contraseña", not "Password"); product and app names stay (Zoom, OBS, Finder).
- New strings: see "New UI text" in CLAUDE.md (String Catalog, `scripts/sync_strings.sh`).

## Before committing copy

```bash
grep -rn "—" README.md site docs CHANGELOG.md scripts/dmg_readme.txt   # expect matches only inside code/log lines
```

## Output format for an audit

```markdown
## Writing audit: <what>
Summary (1–2 sentences) · Score X/10
Critical / Important / Polish findings (quote → why → rewrite)
Full rewrite (both languages if the piece is bilingual)
```
