# In-game test: tavern look (0.5.0)

The new art and fonts are new files: **restart the client completely** (a `/reload` does not pick up
new textures or fonts). Then `/console scriptErrors 1` and `/gs`. `/gs demo` makes the next solo spin
a free-game round. Compare with the state images in `design/gildenslots-v2/zustaende/` (rendered at
double size: halve their pixel positions).

## What to report if something is off

- **Green squares or empty boxes** instead of art: the client does not load the TGA files. Say which
  parts (all of them, or only some, e.g. the large 1024 x 512 tome sheet) and paste the path from the
  error if there is one. Check that `Interface/AddOns/GuildSlots/Media/Art/` exists in the game folder.
- **Fonts look like the normal game font** (Friz Quadrata / Morpheus / Arial Narrow): `SetFont` with
  the bundled `.ttf` files failed and the window fell back. Say which texts (title, numbers, labels).
- **Pay lines drawn as thin flat staircases** instead of glowing lines: the client has no
  `CreateLine`. Not an error, but report it.
- **Glows look flat or dark** (cell glow, rays, landing flash): `SetBlendMode("ADD")` is missing or
  ignored.
- Any Lua error text, and whether the frame rate drops (big win with coin rain is the heaviest moment).

## Checklist

- [ ] State 01 (idle): `/gs` opens a 600 x 672 window with tiled dark wood and a gold frame with red
      corner jewels; title in a decorative serif; Solo / Guild toggles, sound and close icons at the
      top right; a gold divider; three dark displays (balance with a coin icon, last win "–", total stake
      with "10 × 1" etc.); reel field with a gold frame and shaded reels; ten numbered markers on each
      side; "Good luck! 10 lines active."; three stake buttons; the gold SPIN button glows slowly; paytable
      (and officer, for officers; refill in solo) buttons; footer line.
- [ ] Symbols: copper, silver, gold coin, potion, sword, kraken (M, named "Kraken" / "Krake"), dragon,
      crown, legendary weapon, tome. They scroll without gaps or tearing at the field's top and bottom.
- [ ] Markers: left side shows 2 4 9 10 / 1 6 7 / 3 5 8 from top to bottom, right side 2 4 8 10 / 1 6 7 /
      3 5 9 (the game's lines, not the design's example).
- [ ] Each reel landing flashes briefly.
- [ ] State 02 (line win): the line is a glowing band in its colour from the left marker through the
      cell centres to the right marker; markers of that line are lit (coloured disc, dark digit);
      winning cells show the framed "win" art, all other cells are darkened; sparkles play on the winning
      cells; the button reads CONTINUE / WEITER; text "Line 1 · 3 × Dragon · 150".
- [ ] State 03: after the round the stakes are replaced by TAKE n and GAMBLE ×2 (red); hint "n won – take
      or gamble?".
- [ ] State 04 (gamble): GAMBLE darkens the reels and shows a face-down card, RED and BLACK buttons, "At
      stake: n → if right 2n", a wide TAKE button, SPIN disabled. Pick a colour: the card turns (narrows,
      widens) and shows your colour on a win, the other colour on a loss. "LAST CARDS" fills up. TAKE
      works before picking.
- [ ] State 05 (`/gs demo`): the tomes pulse; the window darkens; a purple "10 FREE GAMES" banner pops in
      (small → slightly too big → settles) with a shine passing over it; the tome opens (8 frames, stays
      open); symbols shuffle on the book and stop; "Expanding symbol: Crown" in a small panel; the button
      reads START.
- [ ] State 06 (free game): purple wood, purple frames, darker reel background; displays show FREE GAME
      i / N, free-game win, expanding symbol name with its icon; "Balance n" under the buttons; the
      cyan hint "Free game 3 of 10 – stake as when triggered (50)".
- [ ] State 07 (expansion): the column background and the framed symbol fill each expanding reel with a
      gold glow; other reels darken; all markers light up in their colours.
- [ ] State 08 (big win, 20× stake or more, e.g. the demo round): rays turn behind a red "BIG WIN"
      banner, a shine sweeps over it, a large count-up, coins (spinning) rain over the whole window.
      Rays stay inside the reel field. Frame rate stays smooth.
- [ ] Closing the window during any of this (Escape or X) stops everything at once; reopening shows
      the settled balance, no coins, no banner.
- [ ] State 09 (paytable): overlay with the real pays at the current stake (legendary weapon 5× at stake 10 = 5,000; at stake 100 = 50,000),
      the tome row in multiples of the stake, return rate and gamble rule at the top right, ten line
      diagrams in the line colours matching the markers. The X and the paytable button close it.
- [ ] State 10 (guild mode without tokens): dark panel over the reels with the officer shield, "No
      tokens yet." / "Ask an officer.", red hint line, stakes and SPIN disabled. A guild on table T1
      shows "Cannot play here." with the table message.
- [ ] State 11 (officer window, `/gs officer`): same wood and frame, 448 wide, not taller than 728;
      grant section with the list of addon users (click selects, gold band), player / tokens fields
      (field turns brighter with focus), gold GRANT button; self test toggle; recent purchases with
      green / orange / red status badges; guild settings status, eight fields, the read-only line with a
      copy button (click selects the line for Ctrl+C).
- [ ] `/gs fx`: only lines, pulses and count-ups remain (no coin rain, rays, sparkles, breathing, pop,
      landing flash); `/gs fx` again brings them back; the choice survives `/reload`.
- [ ] German client: umlauts in labels ("LETZTE KÄUFE", "GILT FÜR 10 LINIEN") are upper case and render.

Report back: the items that fail, screenshots of states 02, 04, 06, 08 and 11, and the three
"what to report" points above.
