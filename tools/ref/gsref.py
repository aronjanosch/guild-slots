"""Independent reference implementation of docs/core-spec.md, sections 4-6, and of docs/table-t2-spec.md
(tables T2 and T3: the same rules, T3 has other strips, docs/table-t3-spec.md).

Python 3 standard library only. Written strictly from the spec text.
Names are `str`; every hash input is the UTF-8 encoding of the text.
"""
import copy as _copy
import hashlib
import hmac
import re
from fractions import Fraction

# ---------------------------------------------------------------- helpers


class Err(Exception):
    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


def sha_hex(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def hmac_hex(key, msg):
    return hmac.new(key.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest()


def hmac_raw(key, msg):
    return hmac.new(key.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).digest()


def nbytes(s):
    return s.encode("utf-8")


def name_ok(s):
    b = nbytes(s)
    if not 1 <= len(b) <= 48:
        return False
    for c in "|,:;":
        if c in s:
            return False
    return all(x >= 32 for x in b)


_NUM = re.compile(r"(0|[1-9][0-9]*)\Z")
_HEX = re.compile(r"[0-9a-f]*\Z")


def num(s, lo, hi):
    """Parse canonical decimal text; raise bad_entry when malformed or outside lo..hi."""
    if not isinstance(s, str) or not _NUM.match(s) or len(s) > 16:
        raise Err("bad_entry")
    v = int(s)
    if v < lo or v > hi:
        raise Err("bad_entry")
    return v


def hexn(s, n):
    if not isinstance(s, str) or len(s) != n or not _HEX.match(s):
        raise Err("bad_entry")
    return s


# ---------------------------------------------------------------- tables

STRIP = "K,S,G,K,T,S,K,W,G,S,K,M,T,K,S,G,W,K,S,D,G,K,T,S,K,G,M,S,K,W,T,G,K,S".split(",")
PAIR = {"K": 1, "S": 2, "G": 3, "T": 5, "W": 10, "M": 20, "D": 50}
TRIPLE = {"K": 5, "S": 10, "G": 15, "T": 30, "W": 60, "M": 150, "D": 500}


# ---- table T2 (docs/table-t2-spec.md)

T2_BASE = ("KTMKDSGTCDTGWTGWSKMSKDGSWKDWLMSCTKDGSTWCB "
           "KTGWSKWGKTWGKSWGMKSTWGSMGKTDSLCWKMTBCDWG "
           "WGDSMTWDSMWSKTSDTGKWCSTGMWSGTKGCDKMDLGWCSWMLKTGKWTLSBDM "
           "TGSWMGTMWTKWSGWKTGSTKSMWKGSMKGWKGWSMKTWGTWGBMLSTCD "
           "WKSBKGSWTGMWKTMGWTGKDSBLTCGKM").split()
T2_FREE = ("SKGTWGKSTWKGWKSMTKGWDSMKDTGMSWDTKBTWLSGKC "
           "SWKSDKSTWGTKGMKTCSKWSMWCTKGWTDMGSTWGLSDMGSKWLTGKMLKSCWTB "
           "GTDGSKWTSWKSGTKSGTLWSGWKTWDGTMKDTKSDGLSGKTDCTWKGWMBTDKBMWSC "
           "SDGSKMWGTKGSWDKTGDCMSWTGWKTWKCGSTDWMGWCKSBGDMSLDWCTKL "
           "WGSTWSTGKSTGWTGKWGSKTSKGTBKWSMTGSTWDKTSKWGCMDSCKBDWLGST").split()
T2_LINES = [[1, 1, 1, 1, 1], [0, 0, 0, 0, 0], [2, 2, 2, 2, 2], [0, 1, 2, 1, 0], [2, 1, 0, 1, 2],
            [1, 2, 2, 2, 1], [1, 0, 0, 0, 1], [2, 2, 1, 0, 0], [0, 0, 1, 2, 2], [0, 1, 1, 1, 0]]
T2_PAYS = {
    "K": {3: 5, 4: 25, 5: 100}, "S": {3: 5, 4: 25, 5: 100}, "G": {3: 5, 4: 25, 5: 100},
    "T": {3: 5, 4: 40, 5: 150}, "W": {3: 5, 4: 40, 5: 150},
    "M": {2: 5, 3: 30, 4: 100, 5: 750}, "D": {2: 5, 3: 30, 4: 100, 5: 750},
    "C": {2: 5, 3: 40, 4: 400, 5: 2000}, "L": {2: 10, 3: 100, 4: 1000, 5: 5000},
}
T2_SCATTER = {3: 2, 4: 20, 5: 200}
# ---- table T3 (docs/table-t3-spec.md): every rule of T2, retuned strips (tools/ref/t3_tune.py)
T3_BASE = ("KTMKDSGTCDTGWTGWSKMSKDGSWKDWLMSCTKDGSTWCB "
           "KTGWSKWGKTWGKSWGMKSTWGSMGKTDSLCWKMTBCKWG "
           "WGDSMTWDSMWSKTSDTGKWCSTGMWSGTKGCDKMDLGWCSWMLKTGKWTLSBDM "
           "TGSWMGTMWTKWSGWKTGSTKSMWKGSMKGWKGWSMKTWGTWGBMLSTCD "
           "WKSBKGSWTGMWKTMGWTGKDSBLTCGKM").split()
T3_FREE = ("SKGTWGKSTWKGWKSMTKGWDSMKDTGMSWKTKBTWLSGKC "
           "SWKSDKSTWGTKGMKTCSKWSMWCTKGWTDMGSTWGLSDMGSKWLTGKMLKSCWTB "
           "GTDGSKWTSWKSGTKSGTLWSGWKTWDGTMKDTKSDGLSGKTDCTWKGWMBTDKBMWSC "
           "SDGSKMWGTKGSWDKTGDCMSWTGWKTWKCGSTDWMGWCKSBGDMSLDWCTKL "
           "WGSTWSTGKSTGWTGKWGSKTSKGTBKWSMTGSTWDKTSKWGCMDSCKBDWLGST").split()
T2_EXPAND = "KSGTWMDCL"
T2_MAX_FREE = 50
T2_AWARD = 10


class Tables:
    _stats = {}

    @staticmethod
    def get(tid):
        strips = {"T2": (T2_BASE, T2_FREE), "T3": (T3_BASE, T3_FREE)}.get(tid)
        if strips:
            return {"id": tid, "kind": "lines", "reels": strips[0], "freeReels": strips[1], "rows": 3,
                    "lines": T2_LINES, "pays": T2_PAYS, "scatter": T2_SCATTER, "lineCount": 10}
        if tid != "T1":
            return None
        return {"id": "T1", "kind": "classic", "reels": [STRIP, STRIP, STRIP], "pair": PAIR, "triple": TRIPLE}

    @staticmethod
    def symbols(tbl, s1, s2, s3):
        r = tbl["reels"]
        return r[0][s1], r[1][s2], r[2][s3]

    @staticmethod
    def multiplier(tbl, s1, s2, s3):
        a, b, c = Tables.symbols(tbl, s1, s2, s3)
        if a == b == c:
            return tbl["triple"][a]
        if a == b:
            return tbl["pair"][a]
        return 0

    @staticmethod
    def window(tbl, reel, stop):
        st = tbl["reels"][reel - 1]
        n = len(st)
        return st[(stop - 1) % n], st[stop % n], st[(stop + 1) % n]

    @staticmethod
    def win(tbl, stake, cap, s1, s2, s3):
        w = stake * Tables.multiplier(tbl, s1, s2, s3)
        if cap > 0 and w > cap:
            w = cap
        return w

    @staticmethod
    def stats(tbl, stake, cap):
        key = (tbl["id"], stake, cap)
        if key in Tables._stats:
            return Tables._stats[key]
        n1, n2, n3 = (len(x) for x in tbl["reels"])
        combos = n1 * n2 * n3
        hist = {}
        for a in range(n1):
            for b in range(n2):
                for c in range(n3):
                    m = Tables.multiplier(tbl, a, b, c)
                    hist[m] = hist.get(m, 0) + 1
        s = Fraction(0)
        s2 = Fraction(0)
        hit = 0
        for m, cnt in hist.items():
            w = stake * m
            if cap > 0 and w > cap:
                w = cap
            eff = Fraction(w, stake)
            s += eff * cnt
            s2 += eff * eff * cnt
            if w > 0:
                hit += cnt
        rtp = s / combos
        var = s2 / combos - rtp * rtp
        res = {"rtp": rtp, "hit": Fraction(hit, combos), "variance": var, "combos": combos}
        Tables._stats[key] = res
        return res


# ---------------------------------------------------------------- settings


def settings_defaults():
    return {"L": 0, "W": 2, "R": 1, "E": [10, 50, 100], "G": 3, "C": 0, "T": "T1", "X": 1000, "Z": 7}


def settings_find(info):
    for ln in info.split("\n"):
        t = ln.strip(" \t\r")
        if t == "GSLOTS1" or t.startswith("GSLOTS1;"):
            return t
    return None


def settings_parse(line):
    b = nbytes(line)
    if len(b) > 120 or "|" in line or any(x < 32 for x in b):
        raise Err("bad_settings")
    parts = line.split(";")
    if parts[0] != "GSLOTS1":
        raise Err("bad_settings")
    s = settings_defaults()
    seen = set()

    def number(v, lo, hi):
        if not _NUM.match(v) or len(v) > 16 or not lo <= int(v) <= hi:
            raise Err("bad_settings")
        return int(v)

    for f in parts[1:]:
        if "=" not in f:
            raise Err("bad_settings")
        k, v = f.split("=", 1)
        if k in seen:
            raise Err("bad_settings")
        seen.add(k)
        if k == "L":
            s["L"] = number(v, 0, 2)
        elif k == "W":
            s["W"] = number(v, 1, 5)
        elif k == "R":
            s["R"] = number(v, 0, 9)
        elif k == "E":
            items = [number(x, 1, 1000000) for x in v.split(",")]
            if not 1 <= len(items) <= 5 or len(set(items)) != len(items):
                raise Err("bad_settings")
            s["E"] = sorted(items)
        elif k == "G":
            s["G"] = number(v, 0, 5)
        elif k == "C":
            s["C"] = number(v, 0, 1000000000)
        elif k == "T":
            if Tables.get(v) is None:
                raise Err("bad_settings")
            s["T"] = v
        elif k == "X":
            s["X"] = number(v, 1, 1000000000)
    tbl = Tables.get(s["T"])
    if tbl["kind"] == "lines" and any(x % tbl["lineCount"] for x in s["E"]):
        raise Err("bad_settings")
    s["Z"] = 2 * s["W"] + 3
    return s


def settings_format(s):
    return "GSLOTS1;L=%d;W=%d;R=%d;E=%s;G=%d;C=%d;T=%s;X=%d" % (
        s["L"], s["W"], s["R"], ",".join(str(x) for x in s["E"]), s["G"], s["C"], s["T"], s["X"])


# ---------------------------------------------------------------- engine


def commit(seed):
    return sha_hex(seed)


def purchase_key(buy_id, seed, nonce):
    return sha_hex("|".join(["GS1|K", buy_id, seed, nonce]))


def witness_value(S, player, kind, n, g, amount, head):
    return hmac_hex(S, "|".join([player, kind, str(n), str(g), str(amount), head]))[:16]


def lot(witness, player, kind, n, g):
    return int(sha_hex("|".join([witness, player, kind, str(n), str(g)]))[:8], 16)


def drawn(lt, A, Z):
    return A <= Z or lt < (Z * 2 ** 32) // A


def contribs(lst):
    """lst = [{name, value, lot}]; keep 8 lowest lots (tie: smaller name), sort by name."""
    keep = sorted(lst, key=lambda c: (c["lot"], nbytes(c["name"])))[:8]
    keep.sort(key=lambda c: nbytes(c["name"]))
    return ",".join("%s:%s" % (c["name"], c["value"]) for c in keep)


def parse_contribs(text):
    """-> [(name, value)]. Raises bad_entry on malformed/unsorted/duplicate. No count limit."""
    if text == "":
        return []
    out = []
    prev = None
    for item in text.split(","):
        p = item.split(":")
        if len(p) != 2 or not name_ok(p[0]):
            raise Err("bad_entry")
        hexn(p[1], 16)
        k = nbytes(p[0])
        if prev is not None and not prev < k:
            raise Err("bad_entry")
        prev = k
        out.append((p[0], p[1]))
    return out


def spin_stops(K, n, contr, tbl):
    R = hmac_raw(K, "|".join(["spin", str(n), contr]))
    ns = [len(x) for x in tbl["reels"]]
    return tuple(int.from_bytes(R[4 * i:4 * i + 4], "big") % ns[i] for i in range(3))


def t2_window(strips, stops):
    """Window of five reels: per reel [top, middle, bottom], wrapping around the strip."""
    out = []
    for st, s in zip(strips, stops):
        n = len(st)
        out.append([st[(s - 1) % n], st[s % n], st[(s + 1) % n]])
    return out


def t2_line(syms, pays):
    """One line of five symbols -> (target, count, pay in line bets); target None for all books."""
    target = None
    for c in syms:
        if c != "B":
            target = c
            break
    if target is None:
        return None, 0, 0
    count = 0
    for c in syms:
        if c == target or c == "B":
            count += 1
        else:
            break
    pay = pays[target].get(count, 0) if count >= 2 else 0
    return target, count, pay


def t2_evaluate(tbl, stops, stake, X=None):
    """Window result (spec section 4). X None = base game; else free game on tbl['freeReels']."""
    if stake % tbl["lineCount"]:
        raise Err("bad_stake")
    line_bet = stake // tbl["lineCount"]
    win_ = t2_window(tbl["freeReels"] if X is not None else tbl["reels"], stops)
    lines = []
    for li, rows in enumerate(tbl["lines"], 1):
        target, count, pay = t2_line([win_[r][rows[r]] for r in range(5)], tbl["pays"])
        if pay > 0:
            lines.append({"line": li, "symbol": target, "count": count, "win": pay * line_bet})
    b = sum(col.count("B") for col in win_)
    scatter = {"count": b, "win": tbl["scatter"].get(min(b, 5), 0) * stake}
    res = {"stops": list(stops), "window": win_, "lines": lines, "scatter": scatter}
    total = sum(x["win"] for x in lines) + scatter["win"]
    if X is not None:
        reels = [r + 1 for r in range(5) if X in win_[r]]
        pay = tbl["pays"][X].get(len(reels), 0)
        if pay > 0:
            res["expand"] = {"reels": reels, "count": len(reels), "win": pay * line_bet * tbl["lineCount"]}
            total += res["expand"]["win"]
    res["win"] = total
    res["retrigger"] = b >= 3
    return res


def _stops5(R, strips):
    return [int.from_bytes(R[4 * i:4 * i + 4], "big") % len(strips[i]) for i in range(5)]


def t2_round(K, n, contr, tbl, stake, cap):
    """One round (spec section 5/6). K text or keyed function f(msg, raw) -> bytes."""
    def h(msg):
        return K(msg, True) if callable(K) else hmac_raw(K, msg)

    R = h("|".join(["spin", str(n), contr]))
    stops = _stops5(R, tbl["reels"])
    base = t2_evaluate(tbl, stops, stake)
    base_win = base["win"]
    rd = {"kind": "lines", "n": n, "stake": stake, "lineBet": stake // tbl["lineCount"], "stops": stops,
          "window": base["window"], "lines": base["lines"], "scatter": base["scatter"], "base": base_win}
    total = base_win
    if base["scatter"]["count"] >= 3:
        X = T2_EXPAND[int.from_bytes(R[20:24], "big") % 9]
        awarded = T2_AWARD
        games = []
        i = 0
        fwin = 0
        while i < awarded:
            i += 1
            F = h("|".join(["free", str(n), str(i), contr]))
            g = t2_evaluate(tbl, _stops5(F, tbl["freeReels"]), stake, X)
            games.append(g)
            fwin += g["win"]
            if g["retrigger"]:
                awarded = min(awarded + T2_AWARD, T2_MAX_FREE)
        rd["free"] = {"symbol": X, "awarded": len(games), "win": fwin, "games": games}
        total += fwin
    if cap > 0 and total > cap:
        total = cap
    rd["win"] = total
    return rd


def gamble_won(K, n, g, contr):
    R = hmac_raw(K, "|".join(["gam", str(n), str(g), contr]))
    return R[0] < 128


# ---------------------------------------------------------------- ledger

MAXN = 2 ** 31
MAXV = 2 ** 53 - 1


def encode(e):
    t = e["type"]
    if t == "B":
        f = ["B", e["buyId"], e["officer"], e["tokens"], e["commit"], e["seed"], e["nonce"], e["time"], e["line"]]
    elif t == "S":
        f = ["S", e["n"], e["stake"], e["A"], e["status"], e["contribs"]]
    elif t == "G":
        f = ["G", e["n"], e["g"], e["A"], e["status"], e["contribs"]]
    elif t == "P":
        f = ["P", e["payId"], e["officer"], e["amount"], e["balanceAfter"], e["time"]]
    else:
        raise ValueError("type")
    return "|".join(str(x) for x in f)


def decode(text):
    """-> entry; raises Err('bad_entry')."""
    p = text.split("|")
    t = p[0]
    if t == "B" and len(p) == 9:
        e = {"type": "B", "buyId": hexn(p[1], 16), "officer": p[2], "tokens": num(p[3], 1, 10 ** 9),
             "commit": hexn(p[4], 64), "seed": hexn(p[5], 32), "nonce": hexn(p[6], 32),
             "time": num(p[7], 0, MAXV), "line": p[8]}
        if not name_ok(e["officer"]):
            raise Err("bad_entry")
        lb = nbytes(p[8])
        if not 1 <= len(lb) <= 120 or any(x < 32 for x in lb):
            raise Err("bad_entry")
    elif t in ("S", "G") and len(p) == 6:
        if t == "S":
            e = {"type": "S", "n": num(p[1], 1, MAXN), "stake": num(p[2], 1, 1000000)}
        else:
            e = {"type": "G", "n": num(p[1], 1, MAXN), "g": num(p[2], 1, MAXN)}
        e["A"] = num(p[3], 0, 10000)
        if p[4] not in ("ok", "void"):
            raise Err("bad_entry")
        e["status"] = p[4]
        parse_contribs(p[5])
        e["contribs"] = p[5]
    elif t == "P" and len(p) == 6:
        e = {"type": "P", "payId": hexn(p[1], 16), "officer": p[2], "amount": num(p[3], 1, MAXV),
             "balanceAfter": num(p[4], 0, MAXV), "time": num(p[5], 0, MAXV)}
        if not name_ok(e["officer"]):
            raise Err("bad_entry")
    else:
        raise Err("bad_entry")
    if encode(e) != text:
        raise Err("bad_entry")
    return e


class State:
    pass


def start(guild, player):
    st = State()
    st.guild = guild
    st.player = player
    st.head = sha_hex("|".join(["GS1|KONTO", guild, player]))
    st.count = 0
    st.anchors = 0
    st.balance = 0
    st.n = 0
    st.g = 0
    st.pending = 0
    st.K = None
    st.settings = None
    st.line = None
    st.tbl = None
    st.buyIds = set()
    st.payIds = set()
    return st


def copy(st):
    return _copy.deepcopy(st)


def short_head(st):
    return st.head[:32]


def _check_contribs(st, e, kind, n, g):
    S = st.settings
    L = S["L"]
    ok = e["status"] == "ok"
    items = parse_contribs(e["contribs"])
    A = e["A"]
    if L == 0:
        if not (ok and A == 0 and e["contribs"] == ""):
            raise Err("bad_contribs")
        return
    if len(items) > 8:
        raise Err("bad_contribs")
    if any(nm == st.player for nm, _ in items):
        raise Err("bad_contribs")
    if L == 1:
        if not 1 <= A <= 10000:
            raise Err("bad_contribs")
        for nm, _ in items:
            if not drawn(lot(nm, st.player, kind, n, g), A, S["Z"]):
                raise Err("bad_contribs")
        if ok and len(items) < S["W"]:
            raise Err("bad_contribs")
    else:
        if A != 0:
            raise Err("bad_contribs")
        if ok and len(items) < 1:
            raise Err("bad_contribs")


def apply(st, e):
    """-> info dict; raises Err(code); mutates st only on success."""
    text = encode(e)
    decode(text)  # well-formedness: bad_entry
    t = e["type"]
    if st.K is None and t != "B":
        raise Err("no_purchase")
    info = {"type": t}
    upd = {}
    add_buy = add_pay = None
    if t == "B":
        if e["commit"] != sha_hex(e["seed"]):
            raise Err("bad_commit")
        if e["buyId"] in st.buyIds:
            raise Err("dup_buy")
        settings = settings_parse(e["line"])
        upd = {"balance": st.balance + e["tokens"], "K": purchase_key(e["buyId"], e["seed"], e["nonce"]),
               "settings": settings, "line": e["line"], "tbl": Tables.get(settings["T"]), "pending": 0}
        add_buy = e["buyId"]
    elif t == "S":
        S = st.settings
        if e["n"] != st.n + 1:
            raise Err("bad_number")
        if e["stake"] not in S["E"] or (st.tbl["kind"] == "lines" and e["stake"] % st.tbl["lineCount"]):
            raise Err("bad_stake")
        _check_contribs(st, e, "spin", e["n"], 0)
        upd = {"n": e["n"], "g": 0}
        if e["status"] == "ok":
            if st.balance < e["stake"]:
                raise Err("no_funds")
            if st.tbl["kind"] == "lines":
                rd = t2_round(st.K, e["n"], e["contribs"], st.tbl, e["stake"], S["C"])
                win = rd["win"]
                info.update(round=rd, multiplier=Fraction(win, e["stake"]), win=win)
            else:
                stops = spin_stops(st.K, e["n"], e["contribs"], st.tbl)
                win = Tables.win(st.tbl, e["stake"], S["C"], *stops)
                info.update(stops=stops, multiplier=Tables.multiplier(st.tbl, *stops), win=win)
            upd["balance"] = st.balance - e["stake"] + win
            can = S["G"] > 0 and win > 0 and (S["C"] == 0 or 2 * win <= S["C"])
            upd["pending"] = win if can else 0
        else:
            upd["pending"] = 0
    elif t == "G":
        S = st.settings
        if not (e["n"] == st.n and e["g"] == st.g + 1 and e["g"] <= S["G"] and st.pending > 0):
            raise Err("bad_gamble")
        _check_contribs(st, e, "gam", e["n"], e["g"])
        upd = {"g": e["g"]}
        if e["status"] == "ok":
            won = gamble_won(st.K, e["n"], e["g"], e["contribs"])
            if won:
                upd["balance"] = st.balance + st.pending
                p = 2 * st.pending
                upd["pending"] = 0 if (e["g"] == S["G"] or (S["C"] > 0 and 2 * p > S["C"])) else p
            else:
                upd["balance"] = st.balance - st.pending
                upd["pending"] = 0
            info["won"] = won
    else:
        if e["payId"] in st.payIds:
            raise Err("dup_pay")
        if not 1 <= e["amount"] <= st.balance:
            raise Err("no_funds")
        if e["balanceAfter"] != st.balance - e["amount"]:
            raise Err("bad_balance")
        upd = {"balance": e["balanceAfter"], "pending": 0}
        add_pay = e["payId"]
    for k, v in upd.items():
        setattr(st, k, v)
    if add_buy:
        st.buyIds.add(add_buy)
        st.anchors += 1
    if add_pay:
        st.payIds.add(add_pay)
        st.anchors += 1
    st.head = sha_hex(st.head + "|" + text)
    st.count += 1
    info.update(balance=st.balance, pending=st.pending, head=st.head)
    return info


def replay(guild, player, texts):
    """-> (state, None, None) or (None, code, index) with index 1-based."""
    st = start(guild, player)
    for i, t in enumerate(texts, 1):
        try:
            apply(st, decode(t))
        except Err as ex:
            return None, ex.code, i
    return st, None, None
