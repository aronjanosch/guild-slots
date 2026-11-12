# Python reference for docs/core-spec.md (sections 4-6); standard library only.
Regenerate the Lua test vectors: `python3 tools/ref/gen_vectors.py` (writes `tests/vectors.lua`, byte-identical on every run).
Self-check of the reference (table stats, account replay, invalid cases): `python3 tools/ref/test_ref.py`.
