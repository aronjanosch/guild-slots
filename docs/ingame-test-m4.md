# In-game test: payout (milestone 4)

One character with officer rank and the self-test switch is enough. Restart the client first
(new files), then `/console scriptErrors 1`.

1. `/gs officer`: three tabs Tokens / Payouts / Settings. Turn Self test on and grant yourself 500
   (the purchase flow changed slightly in this milestone, so this re-tests it).
2. `/gs guild`, spin 3 to 5 rounds. The Cash out button sits where Refill is in solo mode.
3. Cash out: the panel covers the reels, the amount is prefilled with the balance, your own name is
   the officer. Letters are ignored; 0 or more than the balance shows a "1 to N" line. Max and
   Cancel work.
4. Request 200. The panel shows "Waiting for the officer" and about 300 s left. SPIN and the stakes
   are disabled. Hide shows the "Cash-out open" panel; Cash out shows the request again.
5. Within a few seconds: "Sending your account" with a bar, then "Waiting for the decision". With
   the officer window closed, a chat line and a sound announce the request.
6. `/gs officer`, Payouts tab: a "1" badge, the request row with a status badge and seconds left;
   the review shows a green light, calculated balance, requested amount, balance after, "No
   findings", the luck rows ("too little data" below 30 spins), the look-ahead line.
7. "Paid - confirm", then Confirm: the badge turns green.
8. Slot window: "Paid out: 200 tokens by ...", the balance counts down by 200, SPIN works again.
9. Request 50 and reject it: the player panel shows the reason.
10. Request 30 and wait 5 minutes: both windows show expired, spins are free again.
11. Request 20, then `/reload` while it waits: the window comes back locked with the request.
12. `/gs payout` from solo mode switches to guild mode and opens the panel.
13. A member below officer rank sees only the Settings tab in `/gs officer`.

Report back: Lua error texts, at which step a status hangs, and screenshots of the review (step 6)
and the paid panel (step 8).

Not covered by one character: a payout between two different characters, and a third client
ending up with the same anchor.
