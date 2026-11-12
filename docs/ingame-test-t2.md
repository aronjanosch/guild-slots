# In-game test: T2 window (0.4.0)

Restart the client (new files), `/console scriptErrors 1`, then `/gs`.
`/gs demo` makes the next solo spin a free-game round (three books, a retrigger, an expansion).

- [ ] `/gs` opens a 560 x 568 window; drag, `/gs reset`, Escape closes.
- [ ] All ten symbols show icons (copper, silver, gold, potion, sword, murloc, dragon, crown, Thunderfury, book); no green squares.
- [ ] Solo spin: five reels land left to right, the reel sound stops with the last reel, one stop sound per reel.
- [ ] A reel landing with a book plays the book sound.
- [ ] Two books before the last reels: the remaining reels spin longer with a gold glow.
- [ ] Line win: all lines flash, then each line is drawn in its colour with markers lit at both edges, other cells dimmed, text "Line N: k x Symbol = amount", total counts up.
- [ ] SPIN while reels turn stops them quickly; SPIN/Space during the presentation jumps to the end.
- [ ] Take and gamble (won and lost) work; the balance always matches after the animation.
- [ ] Free games (`/gs demo`): books pulse, "10 FREE GAMES" banner, symbol shuffle, badge and "Free game i / N" in the top bar, purple reel tint.
- [ ] Free games play by themselves; SPIN skips one free game per click; the retrigger shows "+10 FREE GAMES" and the counter total grows.
- [ ] Expansion: the symbol fills its reels one by one, then all line markers light up with the expansion win.
- [ ] Summary banner, then back to the base reels and the take/gamble offer.
- [ ] Big win (20x+): banner, gold flash, coin particles; the frame rate stays smooth.
- [ ] Close the window during free games: reopening shows the settled balance and base reels; no sounds on close.
- [ ] Paytable overlay: pays change with the stake, ten line diagrams, return rate about 92.0 % in solo (table T3).
- [ ] Sound toggle silences everything; `/gs space` toggles the Space key.
- [ ] Guild mode with a T3 line (`GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T3`): purchase, spin, free games; see `ingame-test-m3.md` for the purchase steps. Paytable return rate about 92.0 %.
- [ ] An account bought under a T2 line (`...;T=T2`) keeps playing T2: paytable about 95.0 %; switching between solo and guild mode changes the paytable's return rate, and the reels show no wrong symbols after the switch.
- [ ] Guild with a T1 line: the window says the table is not supported and does not spin; solo still plays.
- [ ] Officer form without a guild-info line proposes `T=T3` and its note names T2 (95 %) and T3 (92 %); stakes like 15 are rejected naming the stakes field.
- [ ] Listen to the placeholder sounds (line win, book land, free start, expansion, big win) and note replacements.

Report back: Lua error text, screenshots of a line win, a free game and an expansion, whether the
frame rate drops anywhere, which sounds do not fit.
