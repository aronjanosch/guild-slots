# In-game test: guild mode, level 0 (milestone 3)

One character is enough: with the self test switch an officer grants tokens to themself and the
whole purchase runs over the GUILD echo.

1. Enable Lua errors: `/console scriptErrors 1`, then `/reload`.
2. As officer, paste a settings line into the guild info, e.g. `GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T2`,
   then `/reload`. (`R` is the highest rank index that counts as officer; the guild leader is 0.)
3. `/gs officer`: the settings status shows the parsed values, the form is prefilled, the line box
   gives the same line; clicking the line selects it and Ctrl+C copies it.
4. In the form, type `10,abc` into Stakes: a red line names the field and the line box is empty.
   Type `5,100`: a warning about the stake spread appears. Level 2: a note says this version only
   plays level 0.
5. After a few seconds your own name appears in the online list. Click it, enter 500, press Grant:
   the self grant is refused with a line.
6. Switch Self test on, press Grant again: within about 2 s, Recent purchases shows two "done" rows
   (officer and player side).
7. `/gs`, click the "Solo" button: it reads "Guild", the label reads TOKENS, the balance is 500,
   there is no Refill button, and "+500 tokens from <you>" appears.
8. Spin a few times: the balance follows. Stop a spin early and spin again at once: a short
   "one moment" line, no error.
9. Win, gamble, take. Switch to Solo and back: both balances are unchanged.
10. Close the window mid-spin and reopen it: the result is settled.
11. `/reload`: guild mode and the token balance come back once the roster has loaded.
12. A character without a guild: the mode button says guild mode needs a guild; no Officer button.

Report back: any Lua error text, whether step 6 completes, and whether the officer button and the
online list appear (they depend on client calls not measured by the probe: `GetGuildInfo`,
`PLAYER_GUILD_UPDATE`, `GetGuildRosterInfo` field order).

With a second client (still open in `docs/forever-api-probe.md`): grant from the officer to the
other character without the self test switch.
