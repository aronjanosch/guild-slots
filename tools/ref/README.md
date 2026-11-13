# Python reference for docs/core-spec.md (sections 4-6); standard library only.
Regenerate the Lua test vectors: `python3 tools/ref/gen_vectors.py` (writes `tests/vectors.lua`, byte-identical on every run).
Self-check of the reference (table stats, account replay, invalid cases): `python3 tools/ref/test_ref.py`.
Table T2 (docs/table-t2-spec.md): `gsref.py` has `t2_evaluate`/`t2_round`; `python3 tools/ref/t2_stats.py` computes the statistics (exact rtp and freeRate, simulated hit and variance, about 2 minutes for 10^9 rounds) into `tools/ref/t2_stats.json`; `gen_vectors.py` also writes `tests/vectors_t2.lua` from that file.
