"""Generate tests/vectors.lua from the Python reference (gsref.py). Deterministic.

Usage: python3 tools/ref/gen_vectors.py [output]   (default tests/vectors.lua)
"""
import copy
import json
import os
import sys
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsref as R  # noqa: E402
from gsref import Err  # noqa: E402

# ---------------------------------------------------------------- deterministic counter


class Rng:
    def __init__(self, label):
        self.label = label
        self.i = 0

    def _h(self):
        self.i += 1
        return R.sha_hex("gsvec|%s|%d" % (self.label, self.i))

    def hex(self, nbytes):
        return self._h()[:2 * nbytes]

    def int(self, m):
        return int(self._h()[:12], 16) % m


# ---------------------------------------------------------------- Lua serializer

_ESC = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}


def lua_str(s):
    out = ['"']
    for ch in s:
        if ch in _ESC:
            out.append(_ESC[ch])
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append("\\%03d" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def lua(v, ind=0):
    pad = "  " * ind
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        raise ValueError("None")
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        if not v:
            return "{}"
        if all(isinstance(x, (int, str, bool)) for x in v) and sum(len(str(x)) for x in v) < 70:
            return "{" + ", ".join(lua(x) for x in v) + "}"
        return "{\n" + "".join(pad + "  " + lua(x, ind + 1) + ",\n" for x in v) + pad + "}"
    if isinstance(v, dict):
        if not v:
            return "{}"
        flat = all(isinstance(x, (int, str, bool)) for x in v.values())
        if flat and sum(len(str(x)) + len(k) for k, x in v.items()) < 100:
            return "{" + ", ".join("%s = %s" % (k, lua(x)) for k, x in v.items()) + "}"
        return "{\n" + "".join(pad + "  %s = %s,\n" % (k, lua(x, ind + 1)) for k, x in v.items()) + pad + "}"
    raise TypeError(type(v))


# ---------------------------------------------------------------- witness pool

POOL = ["Zeuge%02d" % i for i in range(1, 41)] + [
    "Ünal", "Åse", "Bjørn", "Çağla", "Łukasz", "Mira", "Zed", "abe", "Ärger", "Íñigo",
    "Thorgrim the Elder", "Nox", "Éowyn", "Ölaf", "Sól", "ßtrahl", "Yuki", "Ørjan", "Pia", "Quill"]


class _Secrets(dict):
    def __missing__(self, nm):
        return R.sha_hex("gsvec|secret|" + nm)[:32]


SECRET = _Secrets()

GUILD = "Die Nachtwächter"
PLAYER = "Örn Ångström"
OFFICER = "Gildenmeister Ägir"
OFFICER2 = "Vizemeisterin Sól"
T0 = 1700000000

LINE0 = "GSLOTS1;L=0;W=2;R=1;E=10,50,100;G=3;C=0;T=T1;X=1000"
LINE0_SHUF = "X=1000;GSLOTS1".replace("X=1000;GSLOTS1", "GSLOTS1;X=2000;E=100,10,50;L=0;Q=unknown")
LINE_DEF = "GSLOTS1"
LINE1 = "GSLOTS1;L=1;W=2;R=1;E=10,50,100;G=3;C=0;T=T1;X=1000"
LINE2 = "GSLOTS1;L=2;E=10,50,100;G=3"

# ---------------------------------------------------------------- account builder


class Acct:
    def __init__(self, name, guild=GUILD, player=PLAYER):
        self.name = name
        self.guild = guild
        self.player = player
        self.st = R.start(guild, player)
        self.h0 = self.st.head
        self.texts = []
        self.heads = []
        self.steps = []

    def head_short(self):
        return self.st.head[:32]

    def add(self, e):
        info = R.apply(self.st, e)
        self.texts.append(R.encode(e))
        self.heads.append(self.st.head[:32])
        step = {"type": e["type"], "balance": info["balance"], "pending": info["pending"]}
        if e["type"] == "S" and "stops" in info:
            step.update(stops=list(info["stops"]), multiplier=info["multiplier"], win=info["win"])
        if e["type"] == "G" and "won" in info:
            step["won"] = info["won"]
        self.steps.append(step)
        return info

    def final(self):
        s = self.st
        return {"balance": s.balance, "n": s.n, "g": s.g, "pending": s.pending, "count": s.count,
                "anchors": s.anchors}


def mk_buy(r, tokens, line, officer=OFFICER, time=T0, buy_id=None, seed=None, nonce=None):
    seed = seed or r.hex(16)
    return {"type": "B", "buyId": buy_id or r.hex(8), "officer": officer, "tokens": tokens,
            "commit": R.commit(seed), "seed": seed, "nonce": nonce or r.hex(16), "time": time, "line": line}


def mk_pay(r, amount, balance, officer=OFFICER, time=T0 + 5000, pay_id=None):
    return {"type": "P", "payId": pay_id or r.hex(8), "officer": officer, "amount": amount,
            "balanceAfter": balance - amount, "time": time}


def make_contribs(ac, kind, n, g, amount, A, count, salt):
    """Contribution text for the current request (head = head before the entry)."""
    st = ac.st
    player = st.player
    head = ac.head_short()
    Z = st.settings["Z"]
    level = st.settings["L"]
    order = sorted(POOL, key=lambda nm: R.sha_hex("%s|%s|%d|%d|%s" % (salt, nm, n, g, kind)))
    cands = []
    for nm in order:
        if nm == player:
            continue
        lt = R.lot(nm, player, kind, n, g)
        if level == 1 and not R.drawn(lt, A, Z):
            continue
        cands.append({"name": nm, "lot": lt,
                      "value": R.witness_value(SECRET[nm], player, kind, n, g, amount, head)})
        if len(cands) >= count:
            break
    return R.contribs(cands), len(cands)


def spin(ac, stake, A=0, count=0, status="ok", contr=None):
    st = ac.st
    n = st.n + 1
    if contr is None:
        contr = make_contribs(ac, "spin", n, 0, stake, A, count, ac.name)[0] if st.settings["L"] > 0 else ""
    return ac.add({"type": "S", "n": n, "stake": stake, "A": A, "status": status, "contribs": contr})


def gamble(ac, A=0, count=0, status="ok", contr=None):
    st = ac.st
    n, g = st.n, st.g + 1
    if contr is None:
        contr = make_contribs(ac, "gam", n, g, st.pending, A, count, ac.name)[0] if st.settings["L"] > 0 else ""
    return ac.add({"type": "G", "n": n, "g": g, "A": A, "status": status, "contribs": contr})


# ---------------------------------------------------------------- the valid accounts


def build_a(t):
    r = Rng("a%d" % t)
    ac = Acct("a")
    ac.add(mk_buy(r, 2000, LINE0_SHUF))
    feats = set()
    stakes = set()
    spins = 0
    paid1 = paid2 = False
    E = [10, 50, 100]
    while spins < 62:
        if spins == 22 and not paid1:
            ac.add(mk_pay(r, ac.st.balance // 2, ac.st.balance, time=T0 + 100))
            paid1 = True
        if spins == 40 and not paid2:
            ac.add(mk_pay(r, ac.st.balance, ac.st.balance, officer=OFFICER2, time=T0 + 200))
            paid2 = True
            ac.add(mk_buy(r, 1500, LINE0, officer=OFFICER2, time=T0 + 300))
        stake = E[r.int(3)]
        if ac.st.balance < stake:
            stake = 10
        if ac.st.balance < stake:
            return None, set()
        stakes.add(stake)
        info = spin(ac, stake)
        spins += 1
        if info["win"] > 0:
            feats.add("win")
        while ac.st.pending > 0 and r.int(10) < 8:
            g = ac.st.g + 1
            gi = gamble(ac)
            if gi["won"]:
                feats.add("gwon")
                if g == 3:
                    feats.add("G_won")
            else:
                feats.add("lost")
    ok = {"win", "gwon", "lost", "G_won"} <= feats and stakes == set(E)
    # a payout while a gamble was pending would also be fine; nothing required
    return (ac if ok else None), feats


def build_b(t):
    r = Rng("b%d" % t)
    line = "GSLOTS1;L=0;E=10,50,100;G=3;C=300;T=T1;X=1000"
    ac = Acct("b", guild="Gilde Ä-B", player="Zoë")
    ac.add(mk_buy(r, 6000, line))
    feats = set()
    for i in range(45):
        stake = [100, 100, 50, 10, 50][r.int(5)]
        if ac.st.balance < stake:
            return None, feats
        info = spin(ac, stake)
        if info["win"] > 0:
            m = info["multiplier"]
            if stake * m > 300:
                feats.add("cut")
            if info["win"] > 0 and 2 * info["win"] > 300:
                feats.add("blocked")
        while ac.st.pending > 0:
            g = ac.st.g + 1
            gi = gamble(ac)
            if gi["won"]:
                feats.add("gwon")
                if ac.st.pending == 0 and g < 3:
                    feats.add("cap_after_gwon")
            else:
                feats.add("lost")
    ok = {"cut", "blocked", "cap_after_gwon", "lost"} <= feats
    return (ac if ok else None), feats


def build_c(t):
    r = Rng("c%d" % t)
    ac = Acct("c", guild="Gilde Eins", player="Björn Þórsson")
    ac.add(mk_buy(r, 3000, LINE1))
    feats = set()
    As = [1, 5, 7, 12, 30, 100, 40, 8]
    void_spin = void_gam = False
    for i in range(32):
        stake = [10, 50, 100][r.int(3)]
        A = As[i % len(As)]
        if i == 5 and not void_spin:
            spin(ac, stake, A=A, count=1, status="void")
            void_spin = True
            feats.add("void_spin")
            continue
        info = spin(ac, stake, A=A, count=2 + r.int(5) if A > 7 else 2 + r.int(3))
        if A > 7:
            feats.add("drawn")
        while ac.st.pending > 0:
            A2 = As[(i + 3) % len(As)]
            if not void_gam:
                gamble(ac, A=A2, count=0 if r.int(2) else 1, status="void")
                void_gam = True
                feats.add("void_gam")
                continue
            gi = gamble(ac, A=A2, count=2 + r.int(3))
            if gi["won"]:
                feats.add("gwon")
            else:
                feats.add("lost")
    # one spin with more than 8 candidates (trimmed to 8)
    spin(ac, 10, A=12, count=14)
    items = R.parse_contribs(ac.texts[-1].split("|")[5])
    if len(items) == 8:
        feats.add("trim")
    ok = {"void_spin", "void_gam", "drawn", "gwon", "lost", "trim"} <= feats
    return (ac if ok else None), feats


def build_d(t, several):
    r = Rng("d%d%d" % (several, t))
    ac = Acct("d2" if several else "d1", guild="Gilde Zwei", player="Ørvar" if several else "Åsa Lindqvist")
    ac.add(mk_buy(r, 3000, LINE2))
    feats = set()
    for i in range(30):
        stake = [10, 50, 100][r.int(3)]
        if several:
            cnt = [1, 2, 3, 5, 8, 11][i % 6]
            if i == 7:
                spin(ac, stake, status="void", count=0)
                feats.add("void")
                continue
        else:
            cnt = 1
        spin(ac, stake, count=cnt)
        while ac.st.pending > 0:
            gi = gamble(ac, count=cnt if not several else [2, 1, 4][ac.st.g % 3])
            feats.add("gwon" if gi["won"] else "lost")
    if several:
        ok = {"gwon", "lost", "void"} <= feats
    else:
        ok = {"gwon", "lost"} <= feats
    return (ac if ok else None), feats


def build_e(t):
    r = Rng("e%d" % t)
    ac = Acct("e", guild="Gilde Ω", player="x")
    ac.add(mk_buy(r, 1000, "GSLOTS1;G=0"))
    feats = set()
    for i in range(25):
        info = spin(ac, [10, 50, 100][r.int(3)])
        if info["win"] > 0 and ac.st.pending == 0:
            feats.add("win_nopending")
    return (ac if "win_nopending" in feats else None), feats


def search(fn, *args):
    for t in range(2000):
        ac, _ = fn(t, *args)
        if ac is not None:
            return ac
    raise RuntimeError("no account found for %s" % fn.__name__)


def account_record(ac):
    return {"name": ac.name, "guild": ac.guild, "player": ac.player, "entries": ac.texts, "heads": ac.heads,
            "h0": ac.h0, "final": ac.final(), "steps": ac.steps}


# ---------------------------------------------------------------- invalid cases

INVALID = []
AMBIG = []


def prefix_case(store, ac, bad, code, note):
    """ac = prefix account (not mutated); bad = dict or raw text."""
    texts = list(ac.texts) + [bad if isinstance(bad, str) else R.encode(bad)]
    store.append({"guild": ac.guild, "player": ac.player, "entries": texts, "index": len(texts),
                  "code": code, "note": note})


def fresh(line, tokens=1000, seed_label="inv", guild="Gilde Test", player="Testspieler Äh", name="inv"):
    r = Rng("%s|%s|%s" % (seed_label, line, tokens))
    ac = Acct(name, guild, player)
    ac.add(mk_buy(r, tokens, line))
    return ac, r


def spin_until(ac, pred, stake=10, limit=200):
    for _ in range(limit):
        info = spin(ac, stake)
        if pred(ac.st, info):
            return info
    raise RuntimeError("spin_until")


def S_(n, stake, A=0, status="ok", contr=""):
    return {"type": "S", "n": n, "stake": stake, "A": A, "status": status, "contribs": contr}


def G_(n, g, A=0, status="ok", contr=""):
    return {"type": "G", "n": n, "g": g, "A": A, "status": status, "contribs": contr}


def build_invalid():
    I = INVALID
    # ---- bad_entry
    ac, r = fresh(LINE0)
    empty = Acct("x")
    I.append({"guild": GUILD, "player": PLAYER, "entries": ["X|1|2"], "index": 1, "code": "bad_entry",
              "note": "unknown tag"})
    prefix_case(I, ac, "S|1|0|0|ok|", "bad_entry", "stake 0")
    prefix_case(I, ac, "S|01|10|0|ok|", "bad_entry", "leading zero")
    prefix_case(I, ac, "S|1|10|0|maybe|", "bad_entry", "bad status")
    prefix_case(I, ac, "S|1|10|0|ok", "bad_entry", "missing field")
    prefix_case(I, ac, "", "bad_entry", "empty text")
    prefix_case(I, ac, mk_pay(r, 0, 1000), "bad_entry", "payout amount 0")
    prefix_case(I, ac, S_(5, 0), "bad_entry", "bad_entry beats bad_number (n wrong and stake 0)")
    prefix_case(I, ac, S_(1, 10, A=10001), "bad_entry", "A above 10000")
    b = mk_buy(r, 1000, LINE0)
    b["seed"] = b["seed"][:30]
    I.append({"guild": GUILD, "player": PLAYER, "entries": [R.encode(b)], "index": 1, "code": "bad_entry",
              "note": "seed too short"})
    b = mk_buy(r, 0, LINE0)
    b["commit"] = "0" * 64
    I.append({"guild": GUILD, "player": PLAYER, "entries": [R.encode(b)], "index": 1, "code": "bad_entry",
              "note": "bad_entry beats bad_commit (tokens 0 and commit wrong)"})
    I.append({"guild": GUILD, "player": PLAYER, "entries": ["S|1|0|0|ok|"], "index": 1, "code": "bad_entry",
              "note": "bad_entry beats no_purchase"})
    # ---- no_purchase
    for e, note in ((S_(1, 10), "spin first"), (G_(1, 1), "gamble first"), (S_(7, 20), "spin first, also bad n/stake"),
                    ({"type": "P", "payId": r.hex(8), "officer": OFFICER, "amount": 5, "balanceAfter": 0,
                      "time": T0}, "payout first")):
        I.append({"guild": GUILD, "player": PLAYER, "entries": [R.encode(e)], "index": 1, "code": "no_purchase",
                  "note": note})
    # ---- bad_commit
    b = mk_buy(r, 1000, LINE0)
    b["commit"] = R.commit(b["seed"] + "x")
    I.append({"guild": GUILD, "player": PLAYER, "entries": [R.encode(b)], "index": 1, "code": "bad_commit",
              "note": "first purchase"})
    b = mk_buy(r, 500, LINE0)
    b["commit"] = R.commit(b["nonce"])
    prefix_case(I, ac, b, "bad_commit", "commit of nonce instead of seed")
    b = mk_buy(r, 500, "NOPE", buy_id=ac.st.buyIds and next(iter(ac.st.buyIds)))
    b["commit"] = "f" * 64
    prefix_case(I, ac, b, "bad_commit", "order: bad_commit before dup_buy and bad_settings")
    # ---- dup_buy
    first = next(iter(ac.st.buyIds))
    prefix_case(I, ac, mk_buy(r, 500, LINE0, buy_id=first), "dup_buy", "same buyId again")
    prefix_case(I, ac, mk_buy(r, 500, "GSLOTS1;L=9", buy_id=first), "dup_buy", "order: dup_buy before bad_settings")
    ac2 = copy.deepcopy(ac)
    spin(ac2, 10)
    ac2.add(mk_pay(r, 5, ac2.st.balance))
    ac2.add(mk_buy(r, 700, LINE0))
    prefix_case(I, ac2, mk_buy(r, 500, LINE0, buy_id=first), "dup_buy", "after spin, payout and second purchase")
    # ---- bad_settings
    for line, note in (("GSLOTS1;L=3", "L out of range"), ("GSLOTS1;L=1;L=1", "repeated key"), ("NOPE", "no prefix"),
                       ("GSLOTS1;E=10,10", "duplicate stakes"), ("GSLOTS1;W=0", "W out of range"),
                       ("GSLOTS1;W=6", "W out of range"), ("GSLOTS1;T=T9", "unknown table"),
                       ("GSLOTS1;foo", "field without ="), ("GSLOTS1;E=1,2,3,4,5,6", "six stakes"),
                       ("GSLOTS1;E=0", "stake 0"), ("GSLOTS1;E=1000001", "stake too large"),
                       ("GSLOTS1;G=6", "G out of range"), ("GSLOTS1;R=10", "R out of range"),
                       ("GSLOTS1;C=1000000001", "C out of range"), ("GSLOTS1;X=0", "X out of range"),
                       ("GSLOTS1;Q=1;Q=2", "repeated unknown key"), ("GSLOTS1;L=abc", "non numeric"),
                       ("GSLOTS1;E=", "empty E"), ("GSLOTS1;E=10,,20", "empty stake item")):
        b = mk_buy(r, 500, line)
        I.append({"guild": GUILD, "player": PLAYER, "entries": [R.encode(b)], "index": 1, "code": "bad_settings",
                  "note": note})
    prefix_case(I, ac, mk_buy(r, 500, "GSLOTS1;L=3"), "bad_settings", "second purchase with bad line")
    # ---- bad_number
    ac3 = copy.deepcopy(ac)
    spin(ac3, 10)
    n = ac3.st.n
    prefix_case(I, ac3, S_(n, 10), "bad_number", "repeat the last n")
    prefix_case(I, ac3, S_(n + 2, 10), "bad_number", "skip a number")
    prefix_case(I, ac, S_(2, 10), "bad_number", "first spin is 2")
    prefix_case(I, ac3, S_(n + 2, 20), "bad_number", "order: bad_number before bad_stake")
    prefix_case(I, ac3, S_(n + 2, 20, A=3), "bad_number", "order: bad_number before bad_contribs")
    # ---- bad_stake
    prefix_case(I, ac, S_(1, 20), "bad_stake", "stake not in E")
    prefix_case(I, ac, S_(1, 20, A=3), "bad_stake", "order: bad_stake before bad_contribs")
    prefix_case(I, ac, S_(1, 20, status="void"), "bad_stake", "void spin still checks the stake")
    low, rl = fresh(LINE0, tokens=5)
    prefix_case(I, low, S_(1, 20), "bad_stake", "order: bad_stake before no_funds")
    ac4 = copy.deepcopy(ac)
    ac4.add(mk_buy(r, 500, "GSLOTS1;E=50,100"))
    prefix_case(I, ac4, S_(1, 10), "bad_stake", "new purchase changes E")
    # ---- bad_contribs, level 0
    prefix_case(I, ac, S_(1, 10, A=3), "bad_contribs", "level 0: A must be 0")
    prefix_case(I, ac, S_(1, 10, contr="Mira:0123456789abcdef"), "bad_contribs", "level 0: contributions")
    prefix_case(I, ac, S_(1, 10, status="void"), "bad_contribs", "level 0: void not allowed")
    prefix_case(I, low, S_(1, 10, A=3), "bad_contribs", "order: bad_contribs before no_funds")
    # ---- level 1
    a1, r1 = fresh(LINE1, tokens=2000, seed_label="l1")
    n = 1
    A = 40
    Z = a1.st.settings["Z"]
    und = [nm for nm in POOL if not R.drawn(R.lot(nm, a1.player, "spin", n, 0), A, Z)]
    drw = [nm for nm in POOL if R.drawn(R.lot(nm, a1.player, "spin", n, 0), A, Z)]
    assert len(drw) >= 3 and und
    val = lambda nm: R.witness_value(SECRET[nm], a1.player, "spin", n, 0, 10, a1.head_short())

    def ctext(names, player_ok=True):
        return R.contribs([{"name": nm, "value": val(nm), "lot": R.lot(nm, a1.player, "spin", n, 0)}
                           for nm in names])

    good = ctext(drw[:2])
    spin(copy.deepcopy(a1), 10, A=A, contr=good)  # sanity: valid
    prefix_case(I, a1, S_(1, 10, A=A, contr=ctext(drw[:1])), "bad_contribs", "level 1: fewer than W for ok")
    prefix_case(I, a1, S_(1, 10, A=0, contr=good), "bad_contribs", "level 1: A = 0")
    prefix_case(I, a1, S_(1, 10, A=10001, contr=good), "bad_entry", "level 1: A above 10000 is malformed")
    prefix_case(I, a1, S_(1, 10, A=A, contr=ctext([drw[0], und[0]])), "bad_contribs", "level 1: undrawn contributor")
    prefix_case(I, a1, S_(1, 10, A=A, contr=ctext([drw[0], a1.player])), "bad_contribs", "level 1: player contributes")
    prefix_case(I, a1, S_(1, 10, A=A, status="void", contr=ctext([und[0]])), "bad_contribs",
                "level 1: void with an undrawn contributor")
    prefix_case(I, a1, S_(1, 10, A=0, status="void"), "bad_contribs", "level 1: void with A = 0")
    prefix_case(I, a1, S_(1, 10, A=A), "bad_contribs", "level 1: ok with no contributions")
    prefix_case(I, a1, S_(1, 10, A=A, contr=ctext(drw[:1])), "bad_contribs",
                "level 1: one contributor, W = 2 (same as above, other A)")
    # level 1 with 9 distinct contributors lives in AMBIG (count limit placement)
    # ---- level 2
    a2, r2 = fresh(LINE2, tokens=2000, seed_label="l2")
    v2 = lambda nm: R.witness_value(SECRET[nm], a2.player, "spin", 1, 0, 10, a2.head_short())
    c2 = "%s:%s" % ("Mira", v2("Mira"))
    spin(copy.deepcopy(a2), 10, contr=c2)  # sanity: valid
    prefix_case(I, a2, S_(1, 10, A=5, contr=c2), "bad_contribs", "level 2: A must be 0")
    prefix_case(I, a2, S_(1, 10), "bad_contribs", "level 2: ok without contributions")
    prefix_case(I, a2, S_(1, 10, contr="%s:%s" % (a2.player, "0123456789abcdef")), "bad_contribs",
                "level 2: player contributes")
    prefix_case(I, a2, S_(1, 10, A=1, status="void"), "bad_contribs", "level 2: void with A != 0")
    # ---- no_funds
    prefix_case(I, low, S_(1, 10), "no_funds", "stake above balance")
    prefix_case(I, ac, dict(mk_pay(r, 1001, 1002), balanceAfter=1), "no_funds", "payout above balance")
    pz, rz = fresh(LINE0, tokens=100)
    pz.add(mk_pay(rz, 100, 100))
    prefix_case(I, pz, dict(mk_pay(rz, 1, 1), balanceAfter=0), "no_funds", "payout from balance 0")
    prefix_case(I, pz, S_(1, 10), "no_funds", "spin from balance 0 after payout")
    pid = next(iter(pz.st.payIds))
    prefix_case(I, pz, {"type": "P", "payId": pid, "officer": OFFICER, "amount": 1, "balanceAfter": 5, "time": T0},
                "dup_pay", "order: dup_pay before no_funds and bad_balance")
    prefix_case(I, ac, {"type": "P", "payId": r.hex(8), "officer": OFFICER, "amount": 2000, "balanceAfter": 5,
                        "time": T0}, "no_funds", "order: no_funds before bad_balance")
    # ---- dup_pay
    d1, rd = fresh(LINE0, tokens=1000, seed_label="dp")
    d1.add(mk_pay(rd, 100, 1000))
    pid = next(iter(d1.st.payIds))
    prefix_case(I, d1, mk_pay(rd, 100, 900, pay_id=pid), "dup_pay", "same payId again")
    # ---- bad_balance
    prefix_case(I, ac, {"type": "P", "payId": r.hex(8), "officer": OFFICER, "amount": 100, "balanceAfter": 901,
                        "time": T0}, "bad_balance", "balanceAfter too high")
    prefix_case(I, ac, {"type": "P", "payId": r.hex(8), "officer": OFFICER, "amount": 100, "balanceAfter": 899,
                        "time": T0}, "bad_balance", "balanceAfter too low")
    prefix_case(I, ac, {"type": "P", "payId": r.hex(8), "officer": OFFICER, "amount": 100, "balanceAfter": 1000,
                        "time": T0}, "bad_balance", "balanceAfter unchanged")
    # ---- bad_gamble
    g0, rg = fresh(LINE0, tokens=5000, seed_label="gam")
    prefix_case(I, g0, G_(1, 1), "bad_gamble", "gamble before any spin")
    lost = copy.deepcopy(g0)
    spin_until(lost, lambda st, i: i["win"] == 0)
    prefix_case(I, lost, G_(lost.st.n, 1), "bad_gamble", "no win, nothing pending")
    pend = copy.deepcopy(g0)
    spin_until(pend, lambda st, i: st.pending > 0)
    n = pend.st.n
    prefix_case(I, pend, G_(n + 1, 1), "bad_gamble", "gamble with n + 1")
    prefix_case(I, pend, G_(n - 1, 1), "bad_gamble", "gamble with n - 1")
    prefix_case(I, pend, G_(n, 2), "bad_gamble", "first step is 2")
    prefix_case(I, pend, G_(n, 2, A=5), "bad_gamble", "order: bad_gamble before bad_contribs")
    # void steps keep pending, so steps beyond G become reachable only at level >= 1
    v1, rv = fresh(LINE1, tokens=5000, seed_label="void")
    for _ in range(300):
        spin(v1, 10, A=1, count=2)
        if v1.st.pending > 0:
            break
    assert v1.st.pending > 0
    for k in range(3):
        gamble(v1, A=1, count=0, status="void")
    prefix_case(I, v1, G_(v1.st.n, 4, A=1, status="void"), "bad_gamble", "g above G (G = 3) with pending")
    prefix_case(I, v1, G_(v1.st.n, 3, A=1, status="void"), "bad_gamble", "repeat step 3")
    # after a lost or won chain
    done = copy.deepcopy(g0)
    while True:
        spin_until(done, lambda st, i: st.pending > 0)
        while done.st.pending > 0:
            gamble(done)
        break
    prefix_case(I, done, G_(done.st.n, done.st.g + 1), "bad_gamble", "gamble after the chain ended")
    pp = copy.deepcopy(pend)
    pp.add(mk_pay(rg, 1, pp.st.balance))
    prefix_case(I, pp, G_(pp.st.n, 1), "bad_gamble", "gamble after payout")
    pcap, rc = fresh("GSLOTS1;L=0;E=10,50,100;G=3;C=300", tokens=5000, seed_label="cap")
    spin_until(pcap, lambda st, i: i["win"] > 0 and 2 * i["win"] > 300, stake=100, limit=400)
    prefix_case(I, pcap, G_(pcap.st.n, 1), "bad_gamble", "cap blocks gambling")
    pg0, rr = fresh("GSLOTS1;G=0", tokens=2000, seed_label="g0")
    spin_until(pg0, lambda st, i: i["win"] > 0)
    prefix_case(I, pg0, G_(pg0.st.n, 1), "bad_gamble", "G = 0")
    # ---- bad_contribs for gamble
    gc = copy.deepcopy(pend)
    prefix_case(I, gc, G_(n, 1, A=4), "bad_contribs", "level 0 gamble: A must be 0")
    prefix_case(I, gc, G_(n, 1, status="void"), "bad_contribs", "level 0 gamble: void not allowed")
    # level 1 gamble with undrawn contributor
    w1 = copy.deepcopy(v1)
    w1_names = None
    # find undrawn name for gam step 4? use a fresh level-1 account with pending
    l1g, rl1 = fresh(LINE1, tokens=5000, seed_label="l1g")
    for _ in range(300):
        spin(l1g, 10, A=1, count=2)
        if l1g.st.pending > 0:
            break
    n, gg = l1g.st.n, 1
    A = 40
    Zv = l1g.st.settings["Z"]
    und = [nm for nm in POOL if not R.drawn(R.lot(nm, l1g.player, "gam", n, gg), A, Zv)]
    drw = [nm for nm in POOL if R.drawn(R.lot(nm, l1g.player, "gam", n, gg), A, Zv)]
    vv = lambda nm: R.witness_value(SECRET[nm], l1g.player, "gam", n, gg, l1g.st.pending, l1g.head_short())
    cl = lambda names: R.contribs([{"name": x, "value": vv(x), "lot": R.lot(x, l1g.player, "gam", n, gg)}
                                   for x in names])
    gamble(copy.deepcopy(l1g), A=A, contr=cl(drw[:2]))  # sanity
    prefix_case(I, l1g, G_(n, 1, A=A, contr=cl([drw[0], und[0]])), "bad_contribs", "level 1 gamble: undrawn")
    prefix_case(I, l1g, G_(n, 1, A=A, contr=cl(drw[:1])), "bad_contribs", "level 1 gamble: too few")
    prefix_case(I, l1g, G_(n, 1, A=A, contr=cl([drw[0], l1g.player])), "bad_contribs",
                "level 1 gamble: player contributes")
    # level 2 gamble without contributions
    l2g, rl2 = fresh(LINE2, tokens=5000, seed_label="l2g")
    for _ in range(300):
        spin(l2g, 10, count=1)
        if l2g.st.pending > 0:
            break
    prefix_case(I, l2g, G_(l2g.st.n, 1), "bad_contribs", "level 2 gamble: no contributions")
    prefix_case(I, l2g, G_(l2g.st.n, 1, A=2, contr="Mira:0123456789abcdef"), "bad_contribs",
                "level 2 gamble: A != 0")

    # ------------------------------------------------ ambiguous placements (my reading chosen)
    A9 = AMBIG
    names9 = drw[:2]
    spinA, _ = fresh(LINE2, tokens=2000, seed_label="amb")
    nine = ",".join("%s:%s" % (nm, "0123456789abcdef") for nm in sorted(
        ["Zeuge%02d" % i for i in range(1, 10)], key=R.nbytes))
    prefix_case(A9, spinA, S_(1, 10, contr=nine), "bad_contribs", "9 contributions: count limit seen as level shape")
    prefix_case(A9, spinA, S_(1, 10, contr="Zed:0123456789abcdef,Mira:0123456789abcdef"), "bad_entry",
                "unsorted contributions rejected at decode (parseContribs)")
    prefix_case(A9, spinA, S_(1, 10, contr="Mira:0123456789abcdef,Mira:0123456789abcdef"), "bad_entry",
                "duplicate contribution rejected at decode")
    prefix_case(A9, spinA, S_(1, 10, contr="Mira:0123456789abcde"), "bad_entry", "contribution value too short")
    prefix_case(A9, spinA, S_(1, 10, contr="Mira0123456789abcdef"), "bad_entry", "contribution without colon")
    prefix_case(A9, spinA, S_(1, 10, contr="Mira:0123456789abcdef,"), "bad_entry", "trailing comma")
    prefix_case(A9, spinA, G_(1, 0), "bad_entry", "g = 0 treated as malformed (g >= 1)")
    prefix_case(A9, ac, {"type": "B", "buyId": "0" * 16, "officer": OFFICER, "tokens": 5, "commit": R.commit("0" * 32),
                         "seed": "0" * 32, "nonce": "0" * 32, "time": T0, "line": "G" * 121}, "bad_entry",
                "settings line longer than 120 bytes is malformed")


def build_decode_bad():
    r = Rng("decode_bad")
    b = mk_buy(r, 100, LINE0)

    def bmod(**kw):
        x = dict(b)
        x.update(kw)
        return R.encode(x)

    ok_c = "Mira:0123456789abcdef"
    cases = [
        ("", "empty"), ("S", "tag only"), ("X|1|2|3|4|5", "unknown tag"), ("s|1|10|0|ok|", "lowercase tag"),
        ("B|", "short purchase"), ("S|1|10|0|ok", "five fields"), ("S|1|10|0|ok||", "seven fields"),
        ("G|1|1|0|ok", "five fields gamble"), ("P|0123456789abcdef|Ägir|5|0", "five fields payout"),
        ("S|01|10|0|ok|", "leading zero n"), ("S|+1|10|0|ok|", "sign"), ("S|1.5|10|0|ok|", "decimal"),
        ("S| 1|10|0|ok|", "space"), ("S|1|10|0|ok |", "status with space"), ("S|1|10|0|OK|", "status case"),
        ("S|1|10|0||", "empty status"), ("S|0|10|0|ok|", "n 0"), ("S|2147483649|10|0|ok|", "n above 2^31"),
        ("S|1|0|0|ok|", "stake 0"), ("S|1|1000001|0|ok|", "stake above limit"), ("S|1|-5|0|ok|", "negative stake"),
        ("S|1|10|10001|ok|", "A above 10000"), ("S|1|10||ok|", "empty A"), ("S|1|10|00|ok|", "A leading zero"),
        ("S|1|10|0|ok|" + ok_c + ",", "trailing comma"), ("S|1|10|0|ok|" + ok_c + ",Zed", "item without value"),
        ("S|1|10|0|ok|Mira", "no colon"), ("S|1|10|0|ok|Mira:0123456789abcde", "value too short"),
        ("S|1|10|0|ok|Mira:0123456789abcdeg", "value not hex"), ("S|1|10|0|ok|Mira:0123456789ABCDEF", "value uppercase"),
        ("S|1|10|0|ok|:0123456789abcdef", "empty name"), ("S|1|10|0|ok|Mi;ra:0123456789abcdef", "name with ;"),
        ("S|1|10|0|ok|Mi:ra:0123456789abcdef", "name with :"),
        ("S|1|10|0|ok|" + "N" * 49 + ":0123456789abcdef", "name 49 bytes"),
        ("S|1|10|0|ok|Mira:0123456789abcdef:1", "three parts"),
        ("G|1|1|0|ok|x", "gamble contribs malformed"), ("G|1|-1|0|ok|", "negative g"), ("G|1|1.0|0|ok|", "decimal g"),
        ("G|01|1|0|ok|", "gamble n leading zero"), ("G|1|1|0|maybe|", "gamble bad status"),
        ("G|0|1|0|ok|", "gamble n 0"),
        ("P|0123456789abcdef|Ägir|0|0|5", "amount 0"), ("P|0123456789abcdef|Ägir|5|-1|5", "negative balanceAfter"),
        ("P|0123456789abcde|Ägir|5|0|5", "payId 15 chars"), ("P|0123456789ABCDEF|Ägir|5|0|5", "payId uppercase"),
        ("P|0123456789abcdef||5|0|5", "empty officer"), ("P|0123456789abcdef|Ä|gir|5|0|5", "extra field"),
        ("P|0123456789abcdef|Ä:gir|5|0|5", "officer with colon"), ("P|0123456789abcdef|Ägir|5|0|", "empty time"),
        ("P|0123456789abcdef|Ägir|5|0|05", "time leading zero"), ("P|0123456789abcdef|Ägir|5.0|0|5", "decimal amount"),
        ("P|0123456789abcdef|" + "O" * 49 + "|5|0|5", "officer 49 bytes"),
        (bmod(buyId=b["buyId"][:15]), "buyId 15 chars"), (bmod(buyId=b["buyId"].upper() + "G"), "buyId bad"),
        (bmod(buyId=b["buyId"] + "0"), "buyId 17 chars"), (bmod(officer=""), "empty officer"),
        (bmod(officer="Ägir;"), "officer with ;"), (bmod(officer="Ägir,x"), "officer with ,"),
        (bmod(officer="Ägir\x01"), "officer with control byte"), (bmod(tokens=0), "tokens 0"),
        (bmod(tokens=10 ** 9 + 1), "tokens above limit"), (bmod(tokens="05"), "tokens leading zero"),
        (bmod(commit=b["commit"][:63]), "commit 63 chars"), (bmod(commit=b["commit"].upper()), "commit uppercase"),
        (bmod(seed=b["seed"] + "0"), "seed 33 chars"), (bmod(seed="z" * 32), "seed not hex"),
        (bmod(nonce=b["nonce"][:31]), "nonce 31 chars"), (bmod(time=""), "empty time"),
        (bmod(time="1e9"), "time not decimal"), (bmod(time=-1), "negative time"), (bmod(line=""), "empty line"),
        (bmod(line="GSLOTS1\x07"), "line with control byte"),
        (bmod() + "|extra", "ten fields"), (bmod() + "\n", "trailing newline in line field"),
    ]
    return [{"text": t, "code": "bad_entry", "note": n} for t, n in cases]


# ---------------------------------------------------------------- engine vectors


def build_engine():
    out = {}
    r = Rng("keys")
    out["keys"] = []
    for _ in range(8):
        buy, seed, nonce = r.hex(8), r.hex(16), r.hex(16)
        out["keys"].append({"buyId": buy, "seed": seed, "nonce": nonce, "commit": R.commit(seed),
                            "K": R.purchase_key(buy, seed, nonce)})
    # witness values
    r = Rng("witness")
    names = ["Örn Ångström", "Anna Maria", "x", "Zoë", "Ünal Çağla", "a b c", "N" * 48, "Ölaf der Rote",
             "Thorgrim the Elder", "Åse", "Ørjan Bjørn", "Éowyn  Doppelleerzeichen"]
    out["witness"] = []
    for i, nm in enumerate(names + names[:4]):
        kind = "spin" if i % 2 == 0 else "gam"
        n = [1, 2, 57, 1000, 2 ** 31, 123456, 9][i % 7]
        g = 0 if kind == "spin" else 1 + i % 5
        amount = [1, 10, 50, 100, 1000000, 12345, 3][i % 7]
        S, head = r.hex(16), r.hex(16)
        out["witness"].append({"S": S, "player": nm, "kind": kind, "n": n, "g": g, "amount": amount,
                               "head": head, "value": R.witness_value(S, nm, kind, n, g, amount, head)})
    # lots
    r = Rng("lots")
    out["lots"] = []
    ln = names + POOL[:10]
    for i in range(32):
        w = ln[r.int(len(ln))]
        p = ln[r.int(len(ln))]
        kind = "spin" if i % 2 == 0 else "gam"
        n = 1 + r.int(5000) if i % 5 else 2 ** 31
        g = 0 if kind == "spin" else 1 + r.int(5)
        out["lots"].append({"witness": w, "player": p, "kind": kind, "n": n, "g": g,
                            "lot": R.lot(w, p, kind, n, g)})
    # drawn
    out["drawn"] = []
    for Z in (5, 7, 9, 11, 13):
        for A in (1, Z - 1, Z, Z + 1, Z + 2, 2 * Z, 100, 999, 10000):
            if A < 1:
                continue
            thr = (Z * 2 ** 32) // A
            cand = {thr, thr - 1, thr + 1, 0, 2 ** 32 - 1, 2 ** 31}
            for lt in sorted(cand):
                if 0 <= lt < 2 ** 32:
                    out["drawn"].append({"lot": lt, "A": A, "Z": Z, "drawn": R.drawn(lt, A, Z)})
    # contribs
    out["contribs"] = contrib_cases()
    # spins
    r = Rng("spins")
    Ks = [R.sha_hex("K|%d" % i) for i in range(12)]
    out["spins"] = []
    tbl = R.Tables.get("T1")
    for i in range(240):
        K = Ks[i % 12]
        n = [1, 2, 3, 2 ** 31, 2 ** 31 - 1][i % 5] if i < 10 else 1 + r.int(100000)
        if i % 4 == 3:
            k = 1 + r.int(4)
            cs = R.contribs([{"name": POOL[r.int(len(POOL))] + str(j), "value": r.hex(8), "lot": r.int(2 ** 32)}
                             for j in range(k)])
        else:
            cs = ""
        s = R.spin_stops(K, n, cs, tbl)
        out["spins"].append({"K": K, "n": n, "contribs": cs, "s1": s[0], "s2": s[1], "s3": s[2],
                             "multiplier": R.Tables.multiplier(tbl, *s)})
    # make sure there are some wins
    assert sum(1 for c in out["spins"] if c["multiplier"] > 0) > 20
    r = Rng("gambles")
    out["gambles"] = []
    for i in range(130):
        K = Ks[i % 12]
        n = 1 + r.int(100000) if i else 1
        g = 1 + i % 5
        if i % 4 == 3:
            cs = R.contribs([{"name": POOL[r.int(len(POOL))] + str(j), "value": r.hex(8), "lot": r.int(2 ** 32)}
                             for j in range(1 + r.int(3))])
        else:
            cs = ""
        out["gambles"].append({"K": K, "n": n, "g": g, "contribs": cs, "won": R.gamble_won(K, n, g, cs)})
    w = sum(1 for c in out["gambles"] if c["won"])
    assert 30 < w < 100
    return out


def contrib_cases():
    r = Rng("contribs")

    def mk(name, lot):
        return {"name": name, "value": r.hex(8), "lot": lot}

    def case(lst):
        return {"list": lst, "text": R.contribs(lst)}

    cases = [case([]), case([mk("Mira", 5)]),
             case([mk("Zed", 1), mk("Mira", 2), mk("abe", 3)]),
             case([mk("Örn", 9), mk("Ärger", 1), mk("Zeuge", 4), mk("zeuge", 7), mk("Ünal", 3)]),
             case([mk("Mira %d" % i, 100 - i) for i in range(8)]),
             # nine entries, tie between 8th and 9th by lot: smaller name (byte order) kept
             case([mk("Zed", 9), mk("n1", 1), mk("n2", 2), mk("n3", 3), mk("abe", 9), mk("n4", 4), mk("n5", 5),
                   mk("n6", 6), mk("n7", 7)]),
             case([mk("Zed", 9), mk("abe", 9), mk("Mira", 9), mk("n1", 1), mk("n2", 2), mk("n3", 3), mk("n4", 4),
                   mk("n5", 5), mk("n6", 6), mk("n7", 7)]),
             case([mk("abe", 9), mk("Ärger", 9), mk("n1", 1), mk("n2", 2), mk("n3", 3), mk("n4", 4), mk("n5", 5),
                   mk("n6", 6), mk("n7", 7)]),
             case([mk("Gast%02d" % i, (i * 7919) % 1000) for i in range(12)]),
             case([mk("Gast%02d" % i, 0) for i in range(11, -1, -1)]),
             case([mk("Ünal", 2 ** 32 - 1), mk("Bjørn", 0)])]
    return cases


# ---------------------------------------------------------------- table T2 vectors (docs/table-t2-spec.md)

T2_LINE = "GSLOTS1;L=0;W=2;R=1;E=10,50,100;G=3;C=0;T=T2;X=1000"
T2_STAKES = [10, 20, 50, 100, 250, 1000, 10000, 1000000]
T2_CONTRIBS = ["", "", "", "Mira:0123456789abcdef", "Zed:fedcba9876543210,abe:0011223344556677"]
SEARCH_LIMIT = 6000000


def _t2_books(tbl):
    """Per-reel table: number of books in the window for every stop (a cheap pre-filter for searches)."""
    out = []
    for st in tbl["reels"]:
        n = len(st)
        out.append([sum(1 for r in (-1, 0, 1) if st[(s + r) % n] == "B") for s in range(n)])
    return out


def _line_cells(rd, line):
    return [rd["window"][r][R.T2_LINES[line - 1][r]] for r in range(5)]


def _games(rd):
    return rd["free"]["games"] if "free" in rd else []


def _is_five_wild(rd):
    return any(x["count"] == 5 and "B" in _line_cells(rd, x["line"]) for x in rd["lines"])


def _is_five_plain(rd):
    return any(x["count"] == 5 and "B" not in _line_cells(rd, x["line"]) for x in rd["lines"])


def _is_lead_wild(rd):
    return any(x["count"] >= 3 and _line_cells(rd, x["line"])[0] == "B" for x in rd["lines"])


def _is_five_books_line(rd):
    return any(_line_cells(rd, li) == ["B"] * 5 for li in range(1, 11))


def _expand_gap(rd):
    for g in _games(rd):
        if "expand" in g:
            rs = g["expand"]["reels"]
            if rs != list(range(rs[0], rs[0] + len(rs))):
                return True
    return False


# name -> (predicate on the round, number wanted, minimum books in the base window for a cheap pre-filter)
T2_RARE = [
    ("free", lambda rd: "free" in rd, 6, 3),
    ("scatter4", lambda rd: rd["scatter"]["count"] == 4, 2, 4),
    ("scatter5", lambda rd: rd["scatter"]["count"] >= 5, 1, 5),
    ("retrigger", lambda rd: any(g["retrigger"] for g in _games(rd)), 3, 3),
    ("retrigger_more", lambda rd: rd.get("free", {}).get("awarded", 0) >= 30, 1, 3),
    ("expand", lambda rd: any("expand" in g for g in _games(rd)), 5, 3),
    ("expand_gap", _expand_gap, 2, 3),
    ("expand_big", lambda rd: any("expand" in g and g["expand"]["count"] >= 4 for g in _games(rd)), 1, 3),
    ("five_wild", _is_five_wild, 3, 0),
    ("five_plain", _is_five_plain, 2, 0),
    ("lead_wild", _is_lead_wild, 3, 0),
    ("five_books_line", _is_five_books_line, 1, 5),
    ("limit50", lambda rd: rd.get("free", {}).get("awarded", 0) >= 50, 1, 3),
    ("big", lambda rd: rd["win"] >= 200 * rd["stake"], 1, 3),
]


def t2_search(name, pred, want, min_books, tbl, books, limit=SEARCH_LIMIT):
    """Try spin numbers 1.. with a fixed key until `want` rounds satisfy pred; -> (K, [n..], tries)."""
    K = R.sha_hex("gsvec|t2|" + name)
    found = []
    tries = 0
    for n in range(1, limit):
        tries = n
        if min_books:
            st = R._stops5(R.hmac_raw(K, "spin|%d|" % n), tbl["reels"])
            if sum(books[r][st[r]] for r in range(5)) < min_books:
                continue
        rd = R.t2_round(K, n, "", tbl, 10, 0)
        if pred(rd):
            found.append(n)
            if len(found) >= want:
                break
    return K, found, tries


def build_t2_rounds():
    tbl = R.Tables.get("T2")
    books = _t2_books(tbl)
    rounds = []
    report = {}

    def add(K, n, contr, stake, cap):
        rd = R.t2_round(K, n, contr, tbl, stake, cap)
        rounds.append({"K": K, "n": n, "contribs": contr, "stake": stake, "cap": cap, "round": rd})
        return rd

    for name, pred, want, min_books in T2_RARE:
        K, found, tries = t2_search(name, pred, want, min_books, tbl, books)
        report[name] = (len(found), want, tries)
        for i, n in enumerate(found):
            add(K, n, "", T2_STAKES[(i + 1) % len(T2_STAKES)], 0)
    # capped wins: a plain line win and a free-game round, cut by caps around the win
    for name, pick, min_books in (("cap_base", lambda rd: "free" not in rd and rd["win"] >= 100, 0),
                                  ("cap_free", lambda rd: "free" in rd and rd["win"] >= 200, 3)):
        K, found, tries = t2_search(name, pick, 2, min_books, tbl, books)
        report[name] = (len(found), 2, tries)
        for j, n in enumerate(found):
            stake = T2_STAKES[j]
            full = R.t2_round(K, n, "", tbl, stake, 0)["win"]
            for cap in (full // 2, full - 1, full, full + 1):
                add(K, n, "", stake, cap)
    # bulk: varied keys, stakes, contributions, a few caps
    r = Rng("t2bulk")
    i = 0
    while len(rounds) < 240:
        K = r.hex(32)
        n = [1, 2, 3, 2 ** 31, 2 ** 31 - 1][i % 5] if i < 10 else 1 + r.int(100000)
        contr = T2_CONTRIBS[i % len(T2_CONTRIBS)]
        stake = T2_STAKES[r.int(len(T2_STAKES))]
        cap = [0, 0, 0, 0, 100, 500, 5000][r.int(7)]
        add(K, n, contr, stake, cap)
        i += 1
    return rounds, report


def build_t2_account(t, which):
    r = Rng("t2acc%d%d" % (which, t))
    feats = set()
    if which == 0:
        ac = Acct("t2a", guild="Gilde Fünf-Walzen", player="Sören Ähre")
        ac.add(mk_buy(r, 5000, T2_LINE))
        E = [10, 50, 100]
        rounds_n = 70
    else:
        ac = Acct("t2b", guild="Gilde Ω-T2", player="Zoë")
        ac.add(mk_buy(r, 40000, "GSLOTS1;L=1;W=2;R=1;E=10,100,1000;G=2;C=3000;T=T2;X=500", officer=OFFICER2))
        E = [10, 100, 1000]
        rounds_n = 50
    for i in range(rounds_n):
        if which == 0 and i == 30:
            ac.add(mk_pay(r, ac.st.balance // 3, ac.st.balance, time=T0 + 100))
            ac.add(mk_buy(r, 1500, "GSLOTS1;L=0;E=10,50,100;G=3;C=800;T=T2", officer=OFFICER2, time=T0 + 200))
            feats.add("second_buy")
        stake = E[r.int(3)] if which == 0 else E[[0, 1, 1, 2, 0][r.int(5)]]
        if ac.st.balance < stake:
            stake = E[0]
        if ac.st.balance < stake:
            return None, feats
        A = 20 if which else 0
        info = spin(ac, stake, A=A, count=3 if which else 0)
        rd = info["round"]
        if "free" in rd:
            feats.add("free")
        if info["win"] > 0:
            feats.add("win")
        while ac.st.pending > 0 and r.int(10) < 8:
            gi = gamble(ac, A=A, count=3 if which else 0)
            feats.add("gwon" if gi["won"] else "lost")
    need = {"win", "gwon", "lost", "free"} | ({"second_buy"} if which == 0 else set())
    return (ac if need <= feats else None), feats


def t2_account_record(ac):
    return {"guild": ac.guild, "player": ac.player, "entries": ac.texts, "balance": ac.st.balance,
            "head": ac.st.head}


def build_t2_invalid():
    out = []
    r = Rng("t2inv")
    base = {"guild": GUILD, "player": PLAYER}
    for line, note in (("GSLOTS1;E=10,15;T=T2", "T2 with a stake that is not a multiple of 10"),
                       ("GSLOTS1;E=5;T=T2", "T2 with stake 5"), ("GSLOTS1;T=T2;E=10,20,35", "T before E, same rule")):
        out.append(dict(base, entries=[R.encode(mk_buy(r, 1000, line))], index=1, code="bad_settings", note=note))
    ac, _ = fresh(T2_LINE, tokens=1000, seed_label="t2inv")
    for stake, note in ((5, "stake 5 is not in E"), (20, "stake 20 is not in E (E = 10,50,100)"),
                        (15, "stake 15 is not in E")):
        prefix_case(out, ac, S_(1, stake), "bad_stake", note)
    ac2, _ = fresh("GSLOTS1;E=10,20;T=T2;G=0", tokens=1000, seed_label="t2inv2")
    prefix_case(out, ac2, S_(1, 30), "bad_stake", "stake 30 is a multiple of 10 but not in E")
    prefix_case(out, ac2, S_(1, 20, A=2), "bad_contribs", "level 0: A must be 0, also for T2")
    return out


def load_t2_stats():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "t2_stats.json")
    if not os.path.exists(path):
        raise SystemExit("tools/ref/t2_stats.json missing: run python3 tools/ref/t2_stats.py first")
    with open(path) as f:
        j = json.load(f)
    return {"rtp": j["rtp"], "hit": j["hit"], "variance": j["variance"], "freeRate": j["freeRate"]}, j


def build_t2_all():
    stats, j = load_t2_stats()
    rounds, report = build_t2_rounds()
    assert len(rounds) >= 200
    accounts = []
    for which in (0, 1):
        for t in range(3000):
            ac, _ = build_t2_account(t, which)
            if ac is not None:
                accounts.append(t2_account_record(ac))
                break
        else:
            raise RuntimeError("no T2 account %d" % which)
    invalid = build_t2_invalid()
    for c in invalid:
        st, code, idx = R.replay(c["guild"], c["player"], c["entries"])
        assert st is None and (code, idx) == (c["code"], c["index"]), (c, code, idx)
    for a in accounts:
        st, code, idx = R.replay(a["guild"], a["player"], a["entries"])
        assert st is not None and st.balance == a["balance"] and st.head == a["head"]
    return {"stats": stats, "rounds": rounds, "accounts": accounts, "invalid": invalid}, report, j


T2_HEADER = """-- Generated by tools/ref/gen_vectors.py from the Python reference. Do not edit.
-- stats: rtp and freeRate exact (tools/ref/t2_stats.py); hit and variance simulated over %(rounds)d rounds,
--   standard error hit %(hit_se).3g, variance %(var_se).3g.
-- rounds[*]: K (64 hex), n, contribs, stake, cap, round = Engine.round(K, n, contribs, T2, stake, cap).
-- accounts[*]: replay(guild, player, entries) gives `balance` and the full 64-hex `head`.
-- invalid[*]: replay must fail at `index` with `code`.
"""


# ---------------------------------------------------------------- main


def selfcheck_tables():
    tbl = R.Tables.get("T1")
    st = R.Tables.stats(tbl, 10, 0)
    assert st["rtp"] == Fraction(4594, 4913), st["rtp"]
    assert abs(float(st["hit"]) - 0.198962) < 1e-6
    assert abs(float(st["variance"]) - 22.057864) < 1e-6
    assert st["combos"] == 39304
    assert len(R.STRIP) == 34


def selfcheck_accounts(accounts, invalid, ambig, bad):
    for a in accounts:
        st, code, idx = R.replay(a["guild"], a["player"], a["entries"])
        assert st is not None, (a["name"], code, idx)
        # replay heads again
        s2 = R.start(a["guild"], a["player"])
        assert s2.head == a["h0"]
        for i, t in enumerate(a["entries"]):
            R.apply(s2, R.decode(t))
            assert s2.head[:32] == a["heads"][i]
            assert R.encode(R.decode(t)) == t
        assert st.balance == a["final"]["balance"] and st.n == a["final"]["n"]
        assert st.pending == a["final"]["pending"] and st.count == a["final"]["count"]
    for c in invalid + ambig:
        st, code, idx = R.replay(c["guild"], c["player"], c["entries"])
        assert st is None and (code, idx) == (c["code"], c["index"]), (c, code, idx)
    for c in bad:
        try:
            R.decode(c["text"])
        except Err:
            continue
        raise AssertionError("decode accepted %r" % c["text"])


def build_all():
    selfcheck_tables()
    accounts = [search(build_a), search(build_b), search(build_c), search(build_d, False),
                search(build_d, True), search(build_e)]
    recs = [account_record(a) for a in accounts]
    INVALID.clear()
    AMBIG.clear()
    build_invalid()
    bad = build_decode_bad()
    codes = {c["code"] for c in INVALID}
    need = {"bad_entry", "no_purchase", "bad_commit", "dup_buy", "bad_settings", "bad_number", "bad_stake",
            "bad_contribs", "no_funds", "bad_gamble", "dup_pay", "bad_balance"}
    assert need <= codes, need - codes
    selfcheck_accounts(recs, INVALID, AMBIG, bad)
    eng = build_engine()
    return {"engine": eng, "ledger": {"accounts": recs, "invalid": INVALID, "ambiguous": AMBIG,
                                      "decode_bad": bad}}


HEADER = """-- Generated by tools/ref/gen_vectors.py from the Python reference. Do not edit.
-- All indexes are 1-based. Hex is lowercase. s1..s3 are 0-based stops.
-- ledger.accounts[*]: h0 is the full 64-char head, heads[i] the short head after entry i.
-- ledger.invalid / ledger.ambiguous: replay(guild, player, entries) must fail at `index` with `code`.
-- ledger.decode_bad: Ledger.decode(text) must return nil, code.
"""


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "..", "tests", "vectors.lua")
    data = build_all()
    body = HEADER + "return " + lua(data) + "\n"
    with open(out, "wb") as f:
        f.write(body.encode("utf-8"))
    e = data["engine"]
    L = data["ledger"]
    print("engine:", {k: len(v) for k, v in e.items()})
    print("ledger:", {k: len(v) for k, v in L.items()})
    if len(sys.argv) > 1:
        return  # an explicit output path writes only the T1 vectors
    out2 = os.path.join(here, "..", "..", "tests", "vectors_t2.lua")
    d2, report, j = build_t2_all()
    hdr = T2_HEADER % {"rounds": j["sim"]["rounds"], "hit_se": j["se"]["hit"], "var_se": j["se"]["variance"]}
    with open(out2, "wb") as f:
        f.write((hdr + "return " + lua(d2) + "\n").encode("utf-8"))
    print("t2:", {k: len(v) for k, v in d2.items()})
    for k, (got, want, tries) in report.items():
        print("  rare %-16s found %d of %d (tried %d)" % (k, got, want, tries))


if __name__ == "__main__":
    main()
