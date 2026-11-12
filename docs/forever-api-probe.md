# Milestone 0: WoW Forever API probe

Goal: confirm on the live client every API the design relies on, before writing the real addon.
The probe addon lives in `probe/GuildSlotsProbe/`. It is dev-only and never ships.

## Install

Copy (or symlink) `probe/GuildSlotsProbe` into `<WoW Forever>/Interface/AddOns/`.
Results are printed in chat and stored in
`WTF/Account/<account>/SavedVariables/GuildSlotsProbe.lua` (written on logout or `/reload`).

## Test plan

Two characters in the same guild, both with the probe, ideally one officer and one member.

| # | What | How | Pass when |
|---|---|---|---|
| 1 | Local checks | `/gsprobe` | missing APIs listed; `bit` values printed; guild permissions printed |
| 2 | SavedVariables cold start | log in, `/gsprobe sv`, **quit the client completely**, start again, `/gsprobe sv` | boot counter keeps counting instead of restarting at #1 |
| 3 | SavedVariables reload | `/reload`, `/gsprobe sv` | counter keeps counting |
| 4 | GUILD addon messages | `/gsprobe ping` on character A | A prints a PONG from B with round-trip time |
| 5 | Throttle | `/gsprobe burst 15` on A | send results per message on A; B reports how many of 15 arrived (expected ~10 without own throttling) |
| 6 | Lockdown flags | `/gsprobe lock` in the open world, in combat (logged automatically), in a dungeon, in a battleground; repeat `ping` there | flags recorded per place; ping works or the flag explains why not |
| 7 | Officer note, with hardware event | officer: `/gsprobe note <member>` (member with an **empty** officer note) | note written and read back; length limit visible; original restored |
| 8 | Officer note, without hardware event | officer: `/gsprobe note <member> timer` | same as 7, or an `ADDON_ACTION_BLOCKED` entry |
| 9 | Guild info, with hardware event | rank that may edit guild info: `/gsprobe info` | settings line written; max length measured; original restored |
| 10 | Guild info, without hardware event | `/gsprobe info timer` | same as 9, or blocked |
| 11 | Own whisper | `/gsprobe self` | the whisper to yourself arrives (or not: then GUILD echo is the only one-character test) |
| 12 | Guild bank money log | open the guild bank (read automatically) or `/gsprobe bank`; deposit 1 silver, reopen | entries, amounts, "ago" granularity and name format recorded; the new deposit shows up |
| 13 | Hash speed | `/gsprobe more` | 3/3 SHA-256 test vectors; time per hash recorded |
| 14 | Encoding, clocks, ranks | `/gsprobe more` | `C_EncodingUtil` round trips, any built-in hash, server/local clock offset, rank flags and roster name format (counts only) |
| 15 | Message size and bytes | `/gsprobe bytes` | longest message that arrives; which byte values survive the GUILD echo (1..255, NUL) |
| 16 | SavedVariables size | `/gsprobe svbig`, then `/reload`, later a full restart | 5000 ledger-like rows (~440 KB) come back complete both times |

Notes:

- Test 7/8 refuse to touch an officer note that is not empty and does not start with `GS:`.
- Test 9/10 briefly fill the guild info with `x` characters to measure the length limit, then restore
  the original. The original is also kept in `GuildSlotsProbeDB.infoBackup`. Tell the guild first.
- `/gsprobe report` summarises everything collected so far.

## Results

Session 2026-11-12, build 1.60.1.70888 (Nov 9 2026), interface 16001, `WOW_PROJECT_ID` 18.
One character (officer, later guild leader) in a 30-member guild; the two-character tests (4 with a
second client, 5) are still open.

| # | Result | Notes |
|---|---|---|
| 1 | done | No `bit.ror`, no `bit.tobit`. `bit` returns **unsigned** values (`lshift(1,31)` = 2147483648, `bxor` gives 4294967295). `LibStub` / `ChatThrottleLib` only exist when another addon brings them, so bundle them. `UnitName("player")` gives only the first name; `GetUnitName("player", true)` gives "First Last". |
| 2 | **works** | Boot #10 after a full client restart (login, not reload) counted on from #9. The beta bug is fixed on live, so v1 does not need ledger recovery for its own data. |
| 3 | works | Boots #3 to #9 via `/reload`. |
| 4 | works (one client) | The server echoes your own GUILD message back (238 ms round trip). The sender in `CHAT_MSG_ADDON` is "First Last" without a realm. Sending still works while `AreOutgoingAddonChatMessagesRestricted()` returns true. PONG from a second client still open. |
| 5 | | |
| 6 | partly | Open world and in combat (16 entries): `InChatMessagingLockdown` false, `AreOutgoingAddonChatMessagesRestricted` true, messages still go out. Dungeon and battleground not recorded yet. |
| 7 | **forbidden** | `C_GuildInfo.SetNote` raises `ADDON_ACTION_FORBIDDEN`, even from a slash command. Reading officer notes works. |
| 8 | forbidden | Same as 7. |
| 9 | **forbidden** | `C_GuildInfo.SetInfoText` raises `ADDON_ACTION_FORBIDDEN`, even from a slash command and even as guild leader. Reading works (263 chars). Settings must be pasted by hand. |
| 10 | forbidden | Same as 9. |
| 11 | nothing arrives | The addon whisper to yourself is accepted (result 0) but never delivered. Use the GUILD echo for one-character tests. |
| 12 | works | 2026-11-12: `QueryGuildBankLog(MAX_GUILDBANK_TABS + 1)` then `GetGuildBankMoneyTransaction(i)`, read 2 s after opening the vault. Oldest first, newest last. Kinds `deposit` / `withdraw`. Names "First Last", no realm suffix. Age in whole hours (a fresh deposit reads 0h). 4 entries in the log, so the cap is still unknown. |
| 13 | works, slow | 2026-11-12: 3/3 test vectors. 814 µs per hash over ~170 B (3 blocks, ~270 µs per block). One spin costs about 1 ms. Re-checking 10,000 spins takes about 8 s, so that work must be spread over frames or done once per spin when it is received. |
| 14 | partly | 2026-11-12: `C_EncodingUtil` has Base64, Hex, Compress/Decompress, CBOR and JSON (de)serialisers. Base64, Hex and compression round-trip. CBOR round-trips too (17 bytes for a small table). No built-in hash, so the Lua SHA-256 stays. Server and local clock agree (offset 0 s). Roster: 30 members, every name "First Last", no realm, no duplicates, own sender name found, so a receiver can check the sender's rank. Only `C_GuildInfo.GuildControlGetRankFlags` exists, not the global `GuildControlGetRankFlags`. It returns one table of 22 booleans per rank (6 ranks). In this guild only ranks 1 and 2 have flags 3/4 (officer chat listen/speak, by the retail flag order) and flag 11 (view officer note). That makes flag 3 the officer test a receiver can run on the sender's rank; the flag order is taken from retail and not confirmed by name. |
| 15 | 255 bytes, binary-safe | 2026-11-12: 250 and 255 arrive whole. 256 is **cut to 255 without an error** (send result 0), so the addon must check lengths itself. Bytes 1..127 and 128..255 arrive intact, so raw binary works except NUL: `"a\0b"` arrives as `"a"` (cut at the NUL, no error). |
| 16 | works | 5000 rows (~440 KB) came back complete after `/reload` and after a full client restart. |

## Researched, not measured yet (tests 5 and 6)

From the Warcraft Wiki API pages (C_ChatInfo.SendAddonMessage, C_RestrictedActions), November 2026:

- **Throttle (test 5):** per prefix, 10 messages allowance, regaining 1 per second. A send beyond that fails with
  `Enum.SendAddonMessageResult.AddonMessageThrottle` (3). Applies to every chat type; whispers outside instances are
  exempt. Sending a lot on several prefixes at once "may" disconnect the client. The server can change the numbers.
  Consequence: one prefix, an own send queue (or bundled ChatThrottleLib), at most ~1 message per second sustained.
  Result 0 only means "queued", not "delivered".
- **Trial accounts:** since Forever 1.60.1 (2026-11-04) trial and veteran accounts can no longer send addon messages.
  They can receive, so such a member can watch but cannot buy, spin or witness.
- **Restrictions (test 6):** Forever has the retail restriction system (`C_RestrictedActions` with
  `IsAddOnRestrictionActive` / `GetAddOnRestrictionState`, types Combat, Encounter, ChallengeMode, PvPMatch, Map,
  Chat, event `ADDON_RESTRICTION_STATE_CHANGED`). Send result 11 is `AddOnMessageLockdown`. The wiki does not say
  when the Chat type becomes active. Retail news says the restrictions apply during boss encounters and Mythic+ runs.
  `AreOutgoingAddonChatMessagesRestricted()` read true in the open world while sends worked, so the addon should
  check the result code and the Chat restriction state, and queue messages until it ends.
- The probe now records all restriction states with every lockdown entry, logs `ADDON_RESTRICTION_STATE_CHANGED`,
  and on `ENCOUNTER_START` records the flags and sends one GUILD ping, so the next boss pull answers test 6 on its own.

## Known before the probe

From the community API baseline (forever-addon-kit `data/forever_api.json`, beta build 1.60.1.69893):

- Interface `16001`, Lua 5.1, retail UI architecture (`WOW_PROJECT_ID` 1; 18 on the live build).
- Present: `C_ChatInfo.SendAddonMessage`, `RegisterAddonMessagePrefix`, `InChatMessagingLockdown`,
  `AreOutgoingAddonChatMessagesRestricted`, `C_GuildInfo.SetNote`, `C_GuildInfo.SetInfoText`,
  `SetGuildInfoText` (deprecated since 12.0.1), `GetGuildInfoText`, `CanEditGuildInfo`,
  `C_GuildInfo.CanEditOfficerNote`, `GetGuildRosterInfo`, `bit`, `C_EncodingUtil`.
- Not present: `GuildRosterSetOfficerNote`, `LibStub`, `ChatThrottleLib`.
- Beta bug report (2026-09-17): SavedVariables are written on logout but not loaded at launch.
  Test 2 decides whether ledger recovery from other clients is needed in v1 (fixed on live, see results).
