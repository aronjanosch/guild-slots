# guild-slots

A dead-simple slot machine addon for World of Warcraft where **the guild is the house**.

Three reels, one SPIN button. Players play whenever they like (even mid-flight), and every
spin moves a **virtual gold** balance between the player and the guild. The addon never moves
real gold: officers settle balances by hand (mail or trade) and mark them as paid.

## Concept

- **One window, one button.** Reels, SPIN, balance, stake. No menus, no chips, no leaderboards.
- **Stakes** are a few fixed levels set by the guild, fixed per day (not per spin).
- **Optional gamble** after a win: red or black, double or nothing.
- **Account per player:** positive = the guild owes the player, negative = the player owes the guild.
- **Asynchronous and verifiable:** each spin's outcome is derived from a guild seed, the player
  name and a sequential spin number. Every spin is broadcast over the guild addon channel and
  every guild member running the addon keeps a copy of the ledger. Forged outcomes and skipped
  spin numbers are detectable.
- **House edge** is a fixed, public return-to-player rate (e.g. 92%).
- **Daily limit** set by the guild caps what a modified client could gain.
- **Settlement:** only officers (guild rank checked) can mark a balance as paid.

## Status

Idea stage. Target client: WoW Forever (Lua 5.1).

## Notes from research (2026-11-11)

- Blizzard calls casinos/deathrolls "not supported" (no help with scams) rather than banned;
  paid entry was historically the line. Hence virtual amounts only.
- Many gambling addons exist on CurseForge; this one aims to be far simpler.
- Risk: WoW Forever's economy holds may flag frequent officer payouts.
