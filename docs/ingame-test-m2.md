# Milestone 2: in-game test checklist (solo slot window)

The window only uses play money and sends nothing over the network.

## Install

Symlink the addon folder into the client (adjust the client path):

```sh
ln -s "$PWD/GuildSlots" "<WoW Forever>/Interface/AddOns/GuildSlots"
```

Before logging in, enable Lua errors in chat: `/console scriptErrors 1` (then `/reload`).
Check the character screen's AddOns list: "Guild Slots" is listed and not "out of date".

## What to try

1. `/gslots` and `/gs` open and close the window. `Escape` closes it.
2. Drag the window, `/reload`, open it again: same position. `/gs reset` centres it.
3. Spin a few times with the mouse. Watch:
   - each reel twitches up a little, speeds up and scrolls **downwards** at the same speed every
     spin (28 rows/s), then stops left to right (about 0.9 s, 1.3 s, 1.7 s) with a small bounce;
   - symbols are cut off cleanly at the top and bottom edge of the reels (clipping);
   - all 7 icons show (copper, silver and gold coin, potion, sword, murloc, dragon) and none is a
     green question mark;
   - the middle row is marked (thin green lines, small markers at both sides).
4. Click SPIN (it reads STOP) while the reels run: they stop at once.
5. A win: winning symbols glow and pulse, the others dim, the win and the balance count up.
   When reels 1 and 2 show the same symbol, reel 3 runs longer with a green glow.
6. After a win: TAKE and GAMBLE with the amount. GAMBLE flips a coin (gold coin = doubled,
   skull = lost); at most 3 times in a row. SPIN during the offer keeps the win.
7. Stake pills 10 / 50 / 100, REFILL resets the balance to 1000.
8. "Paytable +" opens the paytable with multipliers and the return rate.
9. Space: with the mouse over the window, Space spins (and stops). With the mouse elsewhere,
   Space still jumps. `/gs space` switches the Space key off and on.
10. Enter combat with the window open: Space must jump normally, no errors. Leave combat: Space
    over the window spins again.
11. Sound button in the header and `/gs sound`: reel start, reel stops, win, big win, gamble.
12. Play money balance survives `/reload` and a full restart.
13. German client: all texts in German.

## Report back

- Every Lua error (full text from the error popup or chat), with what you clicked before.
- Clipping: clean edges, or do icons spill over the reel panel?
- Icons: any missing (question mark)? Which ones?
- Animation: smooth or stuttering? Does the cruise read as a downward blur, or do the reels seem
  to run backwards or strobe (then `Theme.timing.speed` needs to change; tell the frame rate)?
  Once per spin, mid-run, each reel's strip jumps by whole rows so it lands on its stop: is that
  jump visible? Any visible jump when a reel lands or after a quick stop?
- Fonts: readable, right size? (Theme falls back to the default game font if `ARIALN.TTF` fails.)
- Sounds: which ones play, which are silent, which fit badly. The names are placeholders in
  `GuildSlots/UI/Theme.lua` (`Theme.sounds`).
- Space key: does it ever swallow keys it should not, especially around combat?
- Frame rate while spinning compared to the window closed.

All colours, sizes, timings, icons and sounds are in `GuildSlots/UI/Theme.lua`.
