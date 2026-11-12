# In-game test: guild bank deposits, guild rate, officer button (0.8.0)

What to try in the Forever client after installing 0.8.0. The add-on only reads the guild bank
money log; it never moves gold or items.

## Setup

- A guild with a valid settings line, `X=1000` (1000 tokens per gold), and you at officer rank.
- Self test on (officer window, Tokens tab) so one character can grant to itself.

## Officer button

1. `/gs`: the shield button sits in the header left of the sound button; session, Solo, Guild,
   shield, sound and close do not overlap (check English and German).
2. Hovering it shows the tooltip "Officer view"; a click opens the officer window.
3. A member below officer rank sees no shield button; `/gs officer` still opens the Settings tab.
4. Bottom row: solo shows Paytable, Refill and Buy evenly across the window; guild mode shows
   Paytable and Cash out evenly. During free games the balance still shows next to Paytable.

## First read

5. On a client that never read this guild's log: open the vault. Deposits older than 24 hours
   are not listed (recorded as handled); deposits from the last 24 hours are.
6. A second officer's client does the same on its own first read.

## Deposits

7. Deposit 1 gold, close the vault, open it again: within about 2 s one chat line about new
   deposits appears and the shield button shows a count badge.
8. Officer window, Tokens tab: the deposit shows "1g", "1,000 tokens", its age and "online";
   the tab has a count badge. Withdrawals are not listed.
9. Grant on your own deposit: player and tokens are filled into the grant form, the purchase
   completes, the slot window balance rises by 1,000 and the row disappears.
10. Deposit again, Dismiss: the row disappears, no tokens.
11. With two or more open deposits: "Dismiss all" asks "Dismiss N deposits? Click again"; the
    second click dismisses them all.
12. Reopen the vault an hour later: nothing new, no chat line. The same deposit again shows up
    as new.
13. A deposit from someone not online with the add-on: Grant is disabled with "add-on offline".
14. Start a grant and `/reload` before it completes: after reopening the vault the deposit is
    open again.
15. A non-officer opening the vault: no chat line, no `bank` entry in SavedVariables.

## Guild rate

16. Grant form: typing 1250 tokens shows "= 1g 25s at the guild rate"; typing `12.5` in the
    Gold field fills 12500 tokens.
17. Cash out: the panel shows the gold equivalent at the guild's rate above the "pays you by
    hand" note.
18. Payout review: "N tokens = …" next to the review heading; the confirm question shows the
    same gold.

## The client's bank log (please write down)

- Does `GUILDBANKLOG_UPDATE` fire while the vault is open (for example after a deposit made at
  the vault)? Does the new deposit show up without closing the vault?
- Is the read 2 s after opening complete, or does the list only fill on a later update?
- The age shown for a deposit less than one hour old: 0 h or 1 h? And for one 1.5 h old?
- The maximum number of entries the money log keeps (deposit until old ones drop off).
