# AGENTS.md — guild-slots

A slot machine addon for World of Warcraft (WoW Forever client, `## Interface: 16001`)
where the guild is the house. Game rules, modes, layout and status: `README.md`.

## Invariants

- **Tokens only.** The addon never moves gold or items. Guild bank data is read at the vault,
  never written.
- **Core is pure and byte-exact.** `GuildSlots/Core/` is Lua 5.1 plus `bit`, with times, random
  bytes, names and guild data passed in; it never calls the WoW API, the clock or `math.random`.
  `docs/core-spec.md` pins every hash input byte for byte, and `tools/ref/` is an independent
  Python implementation of the same spec. A change to any hashed text, entry format or table is a
  spec change first: update the spec, the Python reference and the Lua side together, then
  regenerate the vectors.
- **Vectors are generated.** `tests/vectors*.lua` come from `make vectors`; CI fails on drift.
  Change the reference, never the vector files.
- **The addon informs, officers decide.** Verification shows findings to officers; it blocks
  nothing (`docs/payout-spec.md`).

## Client quirks

- The client's `bit` returns unsigned results and lacks `ror`, `rol`, `tobit`, `tohex` and
  `bswap`. LuaJIT's returns signed ones, so every test runs under both (`make test`).
- Which client APIs exist was measured, not assumed: `docs/forever-api-probe.md`. Check there
  before using a WoW API; add it to `read_globals` in `.luacheckrc`.
- Every file starts `local _, ns = ...` and exports through `ns.<Module>`; no globals besides
  `GuildSlotsDB`.

## Adding a file

- List it in `GuildSlots/GuildSlots.toc`. Order is load order; a file may only use modules listed
  before it.
- A new Core module also goes into the `CORE` list in `tests/run.lua`.
- A new `tests/smoke_*.lua` also goes into `.github/workflows/test.yml`.
- User-facing strings are keys in `GuildSlots/Locale/enUS.lua`, with the German text in
  `deDE.lua`.

## Verify

```sh
make test                                   # unit tests, signed and unsigned bit
for f in tests/smoke_*.lua; do luajit "$f" || break; done   # windows and protocol against a WoW API stub
python3 tools/ref/test_ref.py               # self-check of the Python reference (needs numpy)
make vectors && git diff --exit-code tests/ # vectors still match the reference
```

What only the live client can show goes into an in-game checklist,
`docs/ingame-test-<milestone>.md`, run by a human. A new file in the TOC needs a full client
restart there; `/reload` covers changed Lua.

## Releases

The TOC version ends in `-dev` during development; `make zip` refuses to build it. Set a release
version in `GuildSlots/GuildSlots.toc` to build `dist/GuildSlots-<version>.zip`.

## Git workflow

- One branch per milestone (`milestone-<n>`), merged via PR; small topics get their own branch.
- Conventional Commits with the area as scope: `core`, `game`, `guild`, `net`, `ui`, `ref`,
  `make`, `media`.
- Commits and PR bodies end without AI attribution trailers.
