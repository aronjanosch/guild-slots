# Python reference for docs/core-spec.md (sections 4-6); standard library only.
Regenerate the Lua test vectors: `python3 tools/ref/gen_vectors.py` (writes `tests/vectors.lua`, `tests/vectors_t2.lua` and `tests/vectors_t3.lua`, byte-identical on every run).
Self-check of the reference (table stats, account replay, invalid cases): `python3 tools/ref/test_ref.py`.
Tables T2 and T3 (docs/table-t2-spec.md, docs/table-t3-spec.md): `gsref.py` has `t2_evaluate`/`t2_round` for both (T3 only adds strips); `python3 tools/ref/t2_stats.py [rounds] [seed] [table]` computes the statistics of a lines table (exact rtp, freeRate and bought-series value, simulated hit and variance, about 2 minutes for 10^9 rounds) into `tools/ref/t2_stats.json` or `tools/ref/t3_stats.json`; `gen_vectors.py` reads those files.
`python3 tools/ref/t3_tune.py` reproduces the T3 strips from T2 (deterministic search, rules in its docstring). numpy is needed for `t2_stats.py` and `t3_tune.py`.
