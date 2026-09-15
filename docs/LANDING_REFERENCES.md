# Landing page references

Sites the owner picked (2026-09-15) as the bar for https://smithplus.github.io/Osmotic/: they get to the point without losing the details a user needs. Revisit them before changing the landing page.

| Site | Why it's here |
|---|---|
| [Raycast](https://www.raycast.com) | The owner's favorite. Dark, product-first, every section is a big visual with a one-line caption. |
| [Liqoria](https://www.liqoria.com) | Closest to Osmotic: a native Mac utility, dark, a 4-word headline, a grid of feature icons with 2-word labels. |
| [Dropover](https://dropoverapp.com) | Similar product size: bento cards, each a small title, two lines and a visual. |
| [Craft](https://www.craft.do) | The hero is just the headline and one key; details live behind expandable rows. |
| [Rectangle](https://rectangleapp.com) | The minimum: icon, name, one line, download, fine print; each feature is 3 words, 1 line, 1 screenshot. |

## Measured (desktop, 1440×900, 2026-09-15)

| Site | Words | Page height | Words per 1,000 px | Average paragraph | Longest paragraph | Images/videos |
|---|---|---|---|---|---|---|
| Rectangle | 240 | 4,611 px | 52 | 11 words | 20 | 6 |
| Liqoria | 513 | 7,084 px | 72 | 12 | 56 (an FAQ answer) | 41 + 3 |
| Craft | 835 | 11,057 px | 75 | 10 | 63 | 174 |
| Dropover | 744 | 7,443 px | 100 | 13 | 26 | 12 + 3 |
| Raycast | 1,748 | 15,983 px | 109 | 10 | 18 | 115 |
| Osmotic, before the rewrite | 812 | 6,321 px | 128 | 20 | 43 (8 over 25) | 4 |
| Osmotic, after (2026-09-15) | 433 | 5,763 px | 75 | 9 | 19 | 4 + 10 icons |

## Patterns to keep

1. **Hero = headline, one short line, one key, fine print.** No paragraph under the headline (Craft has none; Rectangle and Raycast have one line of 10–15 words).
2. **Visual first, caption second.** Each feature is a 3–5 word heading, one sentence of at most ~15 words, and a large screenshot (Liqoria, Dropover, Rectangle).
3. **Icon grid for the small stuff.** Liqoria puts ten features in a 5×2 grid of icons with 2-word labels instead of paragraphs.
4. **Details on demand.** FAQs and extra detail collapse (Liqoria, Craft); the page never explains what a screenshot already shows.
5. **Short section headings, lots of room.** Headings are 3–6 words; sections breathe (Raycast, Dropover).
6. **Proof as numbers, not prose.** A figure beats a sentence (our LCD readouts: speed, price, license, account).

## Targets for Osmotic

- Under ~450 words on the page, paragraphs averaging ≤ 12 words, none over 20 (FAQ answers aside, and those stay collapsed).
- Keep the app's hardware look (keys, LCD, LEDs, panels with screws): the references set the density, not the style.
- Re-measure with the snippet below after any copy change.

```js
// In the browser console on the page:
const ps=[...document.querySelectorAll('p')].map(p=>p.innerText.trim().split(/\s+/).length).filter(n=>n>3);
({words: document.querySelector('main').innerText.split(/\s+/).length, avg: Math.round(ps.reduce((a,b)=>a+b,0)/ps.length), max: Math.max(...ps), over20: ps.filter(n=>n>20).length})
```
