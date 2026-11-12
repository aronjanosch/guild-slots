# guild-slots

A slot machine addon for World of Warcraft (WoW Forever client) where **the guild is the house**.
It plays with tokens only. The addon never moves gold or items.

- **Solo mode:** play money, local, no messages. Works without a guild.
- **Guild mode:** officers issue tokens, every spin is derived from a committed secret and can be
  recalculated, an officer's client checks the whole account before a payout.

Play money only. No payout claim. The house always wins.

## The game

Five reels, three rows, ten fixed lines. The tome is wild and scatter; three tomes start ten free
games with an expanding symbol. After a win you can take it or gamble it on a card, double or
nothing, up to a set number of steps. Return rate 95.0 %, free games about every 175 rounds.
Rules, strips and pays: [docs/table-t2-spec.md](docs/table-t2-spec.md).

`/gs` opens the window. `/gs demo` makes the next solo spin a free-game round.

## Guild mode

1. An officer pastes one settings line into the guild info, for example
   `GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T2` (the officer window builds it).
2. **Purchase.** The officer grants tokens. The clients run a commit / nonce / reveal exchange; the
   result is a secret key that decides all spins of that purchase. Neither side can choose it alone.
3. **Spins.** Each spin is one entry in the player's account, a hash chain. The spin number, stake
   and chain head are broadcast to the guild.
4. **Payout.** The player asks an officer. The officer's client fetches the account, replays every
   entry and shows a traffic light, findings, a luck index and a look-ahead. The officer settles by
   hand outside the addon and confirms, or rejects. The addon blocks nothing; it informs.

Exchanging gold for tokens happens by hand between players and is their own business. Blizzard
calls player-run casinos "not supported" rather than banned, and gold as a paid entry can lead to
account actions; that is why the addon itself never touches gold.

## Status

| Milestone | State |
|---|---|
| 0 API probe in the live client | done ([results](docs/forever-api-probe.md)) |
| 1 Pure Lua core (hashing, engine, ledger, verification) | done |
| 2 Solo mode | done, tested in game |
| 3 Guild mode, security level 0 | done, tested in game with one character |
| 4 Payout, anchors | built, not yet tested in game |
| 5 Security levels 1 and 2 (witnesses) | open |
| 6 Polish | open |

Security level 0 means: the key of a purchase is known to the player's client, so a modified
client can look ahead. Stake limits, the luck index and the look-ahead shown to officers are the
counterweight until witnesses (levels 1 and 2) exist. Officers are trusted in version 1; see
"Known limits" in [docs/payout-spec.md](docs/payout-spec.md).

## Layout

```
GuildSlots/        the addon (Core: pure Lua; Game: solo and guild session; Net, Guild: client glue; UI)
probe/             dev-only probe addon used for milestone 0
tests/             LuaJIT test runner, WoW API stub, smoke tests, reference vectors
tools/ref/         independent Python reference that generates the test vectors and table statistics
tools/             install script, sound and media builders
design/            the visual design: parts, state images, measurements
docs/              specs and in-game checklists
```

Specs: [core](docs/core-spec.md), [table T2](docs/table-t2-spec.md), [guild mode](docs/guild-spec.md),
[payout](docs/payout-spec.md).

## Develop

```
make test                      # unit tests, with LuaJIT's signed and the client's unsigned bit results
luajit tests/smoke_ui.lua      # the windows against a WoW API stub (also smoke_net, smoke_guild, smoke_payout)
make vectors                   # regenerate test vectors from the Python reference
make media                     # rebuild textures and fonts from design/
tools/install.sh "<WoW Forever>/Interface/AddOns"   # symlink the addon into the client
```

New files need a full client restart; `/reload` is enough for changed Lua.

## Credits

Fonts: Cinzel Decorative, Marcellus, Archivo Narrow (SIL Open Font License, see
`GuildSlots/Media/Fonts/OFL.txt`). Sounds are synthesised by `tools/gen_sounds.py`.
