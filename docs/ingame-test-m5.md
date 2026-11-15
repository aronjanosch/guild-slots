# In-game test: witnessed mode and payouts from a followed state (milestone 5)

Two clients in the same guild: **A** with officer rank, **B** a member (two accounts, or two
machines). Restart both clients first (new files), then `/console scriptErrors 1` on both. Below,
`<B>` is B's character name and `<Guild>` the guild's name.

1. **Settings.** On A, `/gs officer`, Settings tab: choose "Witnessed" with 1 witness and save. The
   settings line in the guild info contains `L=1;W=1`. B's `/gs officer` shows the same line.
2. **Purchase.** On A, Tokens tab: grant B 500. B's slot window (`/gs guild`) shows 500.
3. **Spins with A as witness.** B spins 10 times. The reels run until the result arrives (about
   1.5 s at most, shorter when A answers early); every spin books normally. The Turbo button is
   hidden on B's witnessed account.
4. **Void.** A logs out. Within a few minutes B's status line says "Too few players online" and
   SPIN is off. If B spins in the moment A leaves: "Spin void: too few witnesses, stake kept", the
   balance stays. A logs in again; after A's first `HELLO` (a few seconds) B can spin again.
5. **Gamble.** B wins a round, gambles 2 or 3 steps (the card stays face down until the result),
   then takes or loses. All steps book.
6. **Payout followed live.** B spins a few more times with A online, then cashes out 100 to A. On A,
   Payouts tab: the request turns ready after about 4 s, no "fetching n/m" progress, the line
   "Followed live, nothing transferred" right of the findings heading, green light, the luck rows.
   Confirm; B shows "Paid out" and the new balance. (If B got a void spin in step 4 while A was
   away, A missed that entry and the review shows the line of step 7 instead; that is correct.)
7. **Payout after A was offline.** On A, Settings: switch to "Open" (`L=0`) and grant B 200 (B's
   account is now level 0). A logs out. B spins 10 times. A logs in. B cashes out 50 to A. A's
   review shows "Followed live, only the missing part transferred", a short "fetching" phase, green.
   Confirm.
8. **Alert display.** On A, add an own alert about B by hand:
   `/run table.insert(GuildSlotsDB.guild.alerts["<Guild>"], {player="<B>", code="rewritten", n=3, g=0, time=GetServerTime()})`
   B cashes out 10 to A. A's review: yellow light, a findings row "Rewritten history reported by
   <A's name> (spin 3)". Reject it.
9. German client (optional): the same review texts read "Live mitgerechnet, nichts übertragen" and
   "Umgeschriebener Verlauf gemeldet von … (Drehung 3)".

Report back: Lua error texts, the step where a status hangs, screenshots of the reviews in steps
6, 7 and 8, and whether any review text is cut off.

Not covered by two clients: alerts sent by a third client (`ALERT` messages), the lottery with more
clients than `Z`, and a witness caught by its revealed secret.
