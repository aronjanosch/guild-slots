# In-game test: engagement pack (0.7.0)

Restart the client (new sound files), `/console scriptErrors 1`, `/gs`.

1. Auto and Turbo sit left of the narrower spin button; labels readable in both languages.
2. Turbo: rounds are visibly shorter, all line wins flash at once, the free-game intro and the
   big-win banner are still shown, only shorter. `/gs turbo` toggles it; it survives `/reload`.
3. Two tomes: the remaining reels slow down with a rising tone that stops when the last reel lands.
   A third tome gives a bright sting, otherwise a thud.
4. Legendary weapon or crown on reels 1 to 3 of a line: reels 4 and 5 glow and land a little later.
5. Big win (`/gs demo`, then spin): the banner steps BIG WIN, HUGE WIN, LEGENDARY during the
   count-up, ticks rise in pitch, the window jolts at each step and returns exactly to its place
   (drag it elsewhere first), more coins fall. SPIN skips it.
6. `/gs fx`: no shake, one quiet tick, no ticker motion.
7. Auto (toggle left of the spin button, `/gs auto`): rounds start by themselves and the button
   stays selected. A win with an offer pauses it with "… won – take or gamble, then Auto rolls
   on": TAKE goes on; GAMBLE goes on after the card (lost, taken from the card, or the last step
   won); SPIN collects and spins and autoplay goes on. Free games play through. SPIN during an
   auto round stops the reels / skips as usual and leaves Auto on. Auto switches off on the
   button, no funds, combat, a mode switch and closing the window; close it mid-spin and reopen:
   the round is booked, nothing spins further.
8. Guild mode autoplay: at most one spin per 1.5 s; opening a cash-out request switches it off.
9. Coin button in the header: session numbers after a few rounds and a gamble; Reset clears the
   current mode only.
10. Solo "Buy free games" at stake 10: 640 is taken, the tome intro plays, ten free games follow,
    then the take / gamble offer. The button is absent in guild mode.
11. Guild mode with a second player's big win or free games: the footer shows the ticker line for a
    few seconds. `/gs ticker` turns it off. (Needs a second character with the add-on.)
12. Listen to each new sound for level and harshness, especially the riser and the tier impact.

Report back: Lua error texts, labels that do not fit, sounds that do not fit, frame-rate drops.
