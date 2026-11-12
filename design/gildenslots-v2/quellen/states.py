# Composes the state previews from the generated textures (9-slices via border-image = WoW 9-slice).
import asyncio, os
from playwright.async_api import async_playwright

A = "file:///home/claude/gs2/out/assets/"
F = "file:///home/claude/gs2/fonts/"
OUT = "/home/claude/gs2/out/states"
os.makedirs(OUT, exist_ok=True)

W, H = 600, 672
FIELD_X, FIELD_Y, CELL = 60, 154, 96
LINES = [[1,1,1,1,1],[0,0,0,0,0],[2,2,2,2,2],[0,1,2,1,0],[2,1,0,1,2],[1,0,0,0,1],[1,2,2,2,1],[0,0,1,2,2],[2,2,1,0,0],[1,2,1,0,1]]
LCOL = ["#ffd23f","#ff6b6b","#4dabf7","#69db7c","#da77f2","#ffa94d","#38d9a9","#f783ac","#a9e34b","#74c0fc"]

FONTS = f"""
@font-face{{font-family:CinzelD;src:url({F}CinzelDecorative-Black.ttf);font-weight:900}}
@font-face{{font-family:CinzelD;src:url({F}CinzelDecorative-Bold.ttf);font-weight:700}}
@font-face{{font-family:Marc;src:url({F}Marcellus-Regular.ttf)}}
@font-face{{font-family:ArchN;src:url({F}ArchivoNarrow-Bold.ttf);font-weight:700}}
@font-face{{font-family:ArchN;src:url({F}ArchivoNarrow-Medium.ttf);font-weight:500}}
*{{box-sizing:border-box}} body{{margin:0;background:transparent}}
.a{{position:absolute}}
.t{{position:absolute;white-space:nowrap;text-shadow:1px 1px 0 #000}}
.lab{{font-family:Marc;font-size:11px;letter-spacing:1.2px;color:#c9ad7c}}
.num{{font-family:ArchN;font-weight:700;color:#fff1cc}}
"""

def img(name, x, y, w, h, extra=""):
    return f'<img class="a" src="{A}{name}.png" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;{extra}">'

def nine(name, sl, disp, x, y, w, h, extra="", inner=""):
    return (f'<div class="a" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-style:solid;border-width:0;'
            f'border-image-source:url({A}{name}.png);border-image-slice:{sl} fill;border-image-width:{disp}px;{extra}">{inner}</div>')

import base64
_D = {}
def tint(name, x, y, w, h, color, extra=""):
    if name not in _D:
        _D[name] = base64.b64encode(open(f"/home/claude/gs2/out/assets/{name}.png", "rb").read()).decode()
    u = f"url(data:image/png;base64,{_D[name]})"
    return f'<div class="a" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;background:{color};-webkit-mask:{u} center/100% 100% no-repeat;{extra}"></div>'

def text(s, x, y, w, h, font, size, color, align="left", weight=400, extra=""):
    fam = {"title": "CinzelD", "label": "Marc", "num": "ArchN"}[font]
    return (f'<div class="t" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;line-height:{h}px;font-family:{fam};'
            f'font-size:{size}px;font-weight:{weight};color:{color};text-align:{align};{extra}">{s}</div>')

def button(kind, state, x, y, w, h, label="", lcolor="#f3e2b8", size=14, font="num", icon=None):
    sl, disp = {"primary": (40, 20), "secondary": (20, 10), "danger": (20, 10), "toggle": (20, 10), "icon": (16, 8)}[kind]
    dy = 2 if state == "pressed" else 0
    out = nine(f"button_{kind}_{state}", sl, disp, x, y, w, h)
    op = .45 if state == "disabled" else 1
    if icon and label:
        out += tint(icon, x + 12, y + (h - 18) // 2 + dy - 1, 18, 18, lcolor, f"opacity:{op}")
        out += text(label, x + 34, y + dy - 2, w - 40, h, font, size, lcolor, "left", 700 if font != "label" else 400, f"opacity:{op}")
    elif icon:
        s = int(h * .52)
        out += tint(icon, x + (w - s) // 2, y + (h - s) // 2 + dy - 1, s, s, lcolor, f"opacity:{op}")
    else:
        out += text(label, x, y + dy - 2, w, h, font, size, lcolor, "center", 900 if font == "title" else 700, f"opacity:{op};text-shadow:{'none' if kind == 'primary' else '1px 1px 0 #000'}")
    return out

def panel(x, y, w, h, label, value, vcolor="#fff1cc", icon=None, sub=None):
    out = nine("panel_inset", 16, 12, x, y, w, h)
    out += text(label, x + 12, y + 5, w - 24, 14, "label", 11, "#c9ad7c", extra="letter-spacing:1.2px")
    vx = x + 12
    if icon:
        out += tint(icon, x + 12, y + 24, 18, 18, "#f2c14e")
        vx += 24
    out += text(value, vx, y + 20, w - 24, 26, "num", 24, vcolor, weight=700)
    if sub:
        out += text(sub, x + w - 92, y + 26, 80, 18, "num", 13, "#c9ad7c", "right", 500)
    return out

def markers(lit=()):
    out = ""
    for side in (0, 1):
        groups = {0: [], 1: [], 2: []}
        for i, ln in enumerate(LINES):
            groups[ln[0] if side == 0 else ln[4]].append(i)
        for row, ids in groups.items():
            n = len(ids)
            for j, li in enumerate(ids):
                cy = FIELD_Y + row * CELL + (j + .5) * CELL / n
                cx = 33 if side == 0 else 567
                if li in lit:
                    out += tint("linemarker_lit", cx - 14, cy - 14, 28, 28, LCOL[li])
                    out += text(str(li + 1), cx - 11, cy - 11, 22, 22, "num", 12, "#1a0f05", "center", 700, "text-shadow:none")
                else:
                    out += img("linemarker_normal", cx - 11, cy - 11, 22, 22)
                    out += text(str(li + 1), cx - 11, cy - 11, 22, 22, "num", 11, "#c9ad7c", "center", 700)
    return out

def marker_y(li, side):
    groups = {0: [], 1: [], 2: []}
    for i, ln in enumerate(LINES):
        groups[ln[0] if side == 0 else ln[4]].append(i)
    row = LINES[li][0] if side == 0 else LINES[li][4]
    ids = groups[row]
    return FIELD_Y + row * CELL + (ids.index(li) + .5) * CELL / len(ids)

def paylines(ids, opacity=1):
    s = f'<svg class="a" style="left:0;top:0;opacity:{opacity}" width="{W}" height="{H}">'
    for li in ids:
        pts = [(44, marker_y(li, 0))] + [(FIELD_X + c * CELL + 48, FIELD_Y + LINES[li][c] * CELL + 48) for c in range(5)] + [(556, marker_y(li, 1))]
        p = " ".join(f"{x:.0f},{y:.0f}" for x, y in pts)
        s += f'<polyline points="{p}" fill="none" stroke="{LCOL[li]}" stroke-width="16" stroke-opacity=".35" stroke-linejoin="round"/>'
        s += f'<polyline points="{p}" fill="none" stroke="#fff" stroke-width="7" stroke-opacity=".9" stroke-linejoin="round"/>'
        s += f'<polyline points="{p}" fill="none" stroke="{LCOL[li]}" stroke-width="4" stroke-linejoin="round"/>'
    return s + "</svg>"

def grid(rows, win=None, dim=False, expand=(), shift=None):
    """rows: 3 lists of 5 symbol keys. win: set of (r,c). dim: dim all non-win cells."""
    out = ""
    for c in range(5):
        if c in expand:
            out += img("expand_column", FIELD_X + c * CELL, FIELD_Y, CELL, CELL * 3)
            for r in range(3):
                out += img("symbol_crown_win", FIELD_X + c * CELL, FIELD_Y + r * CELL, CELL, CELL)
            out += nine("glow_cell", 32, 22, FIELD_X + c * CELL - 4, FIELD_Y - 4, CELL + 8, CELL * 3 + 8, "opacity:.95;filter:sepia(1) saturate(4) hue-rotate(-12deg) brightness(1.1)")
            continue
        off = (shift or {}).get(c, 0)
        clip = f"clip-path:inset({FIELD_Y}px {W - FIELD_X - (c + 1) * CELL}px {H - FIELD_Y - 3 * CELL}px {FIELD_X + c * CELL}px)"
        col = f'<div class="a" style="left:0;top:0;width:{W}px;height:{H}px;{clip}">'
        rr = range(-1, 3) if off else range(3)
        for r in rr:
            k = rows[r % 3] [c] if r >= 0 else rows[2][(c + 2) % 5]
            iswin = win and (r, c) in win
            name = f"symbol_{k}_win" if iswin else f"symbol_{k}"
            st = "opacity:.8" if off else ""
            col += img(name, FIELD_X + c * CELL, FIELD_Y + r * CELL + off, CELL, CELL, st)
            if dim and not iswin and r >= 0:
                col += f'<div class="a" style="left:{FIELD_X + c * CELL}px;top:{FIELD_Y + r * CELL}px;width:{CELL}px;height:{CELL}px;background:rgba(0,0,0,.6)"></div>'
        out += col + "</div>"
    return out

def window(body, free=False, title_right=None):
    bg = "bg_window_freespin" if free else "bg_window_wood"
    fr = "frame_window_freespin" if free else "frame_window"
    return (f'<div class="a" style="left:0;top:0;width:{W}px;height:{H}px;background:url({A}{bg}.png) repeat"></div>'
            + body + nine(fr, 48, 48, 0, 0, W, H))

def header(mode="gilde", sound=True, toggles_enabled=True):
    o = text("Gildenslots", 30, 22, 260, 44, "title", 28, "#f2c14e", weight=900, extra="text-shadow:2px 2px 0 #1a0d05")
    st = "disabled" if not toggles_enabled else None
    o += button("toggle", st or ("selected" if mode == "solo" else "normal"), 318, 29, 78, 32, "Solo", "#fff1cc" if mode == "solo" else "#c9ad7c", 14, "label")
    o += button("toggle", st or ("selected" if mode == "gilde" else "normal"), 398, 29, 78, 32, "Gilde", "#fff1cc" if mode == "gilde" else "#c9ad7c", 14, "label")
    o += button("icon", "normal", 492, 29, 34, 32, icon="icon_sound_on" if sound else "icon_sound_off", lcolor="#ffd76a")
    o += button("icon", "normal", 534, 29, 34, 32, icon="icon_close", lcolor="#ffd76a")
    o += img("divider", 22, 68, 556, 12) if False else nine("divider", 32, 32, 22, 70, 556, 12, "border-image-slice:0 32 fill;border-image-width:0 32px")
    return o

def reels_frame(free=False):
    bgr = "bg_reels_freespin" if free else "bg_reels"
    fr = "frame_reels_freespin" if free else "frame_reels"
    return img(bgr, FIELD_X, FIELD_Y, 480, 288) + "{GRID}" + "".join(img("reel_shade", FIELD_X + c * CELL, FIELD_Y, CELL, 288, "opacity:.8") for c in range(5)) + nine(fr, 32, 24, 48, 142, 504, 312)

def hint(s, tone="muted"):
    c = {"muted": "#c9ad7c", "win": "#ffd76a", "lose": "#ff8a9a", "free": "#c6fbff"}[tone]
    return text(s, 22, 460, 556, 24, "label", 15, c, "center")

def footer():
    return text("Nur Spielwährung. Kein Anspruch auf Auszahlung. Die Bank gewinnt immer.", 22, 616, 556, 16, "label", 11, "#a88e62", "center")

def stakes(sel=1, enabled=True):
    o = text("EINSATZ · GILT FÜR 10 LINIEN", 22, 488, 300, 14, "label", 11, "#c9ad7c", extra="letter-spacing:1.2px")
    for i, v in enumerate([10, 50, 100]):
        stt = "disabled" if not enabled else ("selected" if i == sel else "normal")
        o += button("toggle", stt, 22 + i * 102, 506, 96, 46, str(v), "#fff1cc" if i == sel else "#e2cfa3", 20)
    return o

def offer(amount):
    return (button("secondary", "normal", 22, 494, 148, 58, f"NEHMEN {amount}", "#ffe08a", 17)
            + button("danger", "hover", 176, 494, 148, 58, "RISIKO ×2", "#ffffff", 17))

def spin(label="DREHEN", state="normal"):
    col = "#2a1606" if state != "disabled" else "#d8cbb2"
    return button("primary", state, 334, 488, 244, 64, label, col, 28, "title")

def secondary(officer=True, extra=""):
    o = button("secondary", "normal", 22, 562, 156, 38, "Gewinnplan", "#ffd76a", 14, "label", icon="icon_paytable")
    if officer:
        o += button("secondary", "normal", 184, 562, 156, 38, "Officer", "#ffd76a", 14, "label", icon="icon_officer")
    return o + extra

def page(content, w=W, h=H):
    return f'<html><head><style>{FONTS}</style></head><body><div style="position:relative;width:{w}px;height:{h}px;overflow:hidden">{content}</div></body></html>'

def compose(top, grid_html, below, free=False, overlay=""):
    rf = reels_frame(free).replace("{GRID}", grid_html)
    return page(window(top + rf + below + overlay + footer(), free))

IDLE = [["copper", "crown", "potion", "gold", "sword"], ["silver", "sword", "kraken", "copper", "dragon"], ["potion", "gold", "copper", "tome", "silver"]]
WINR = [["copper", "crown", "potion", "gold", "silver"], ["dragon", "dragon", "dragon", "copper", "sword"], ["potion", "gold", "silver", "tome", "kraken"]]
WIN1 = {(1, 0), (1, 1), (1, 2)}
def panels(bal, last, lastc="#fff1cc", stake=50):
    return (panel(22, 86, 180, 50, "GUTHABEN", bal, icon="icon_coin")
            + panel(210, 86, 180, 50, "LETZTER GEWINN", last, lastc)
            + panel(398, 86, 180, 50, "GESAMTEINSATZ", str(stake), sub=f"10 × {stake // 10}"))

S = {}
# 1 idle
S["01_ruhe"] = compose(header() + panels("2.000", "–", "#7d6a4c"), grid(IDLE), markers() + hint("Viel Glück! 10 Linien aktiv.") + stakes() + spin() + secondary())
# 2 line win
S["02_liniengewinn"] = compose(header() + panels("1.950", "150", "#ffd76a"), grid(WINR, WIN1, True) + paylines([0]),
    markers({0}) + hint("Linie 1 · 3 × Drache · 150", "win") + stakes(enabled=False) + spin("WEITER") + secondary())
# 3 take / gamble
S["03_nehmen_risiko"] = compose(header() + panels("1.950", "150", "#ffd76a"), grid(WINR, WIN1, True) + paylines([0], .55),
    markers({0}) + hint("150 gewonnen – nehmen oder riskieren?", "win") + offer("150") + spin() + secondary())
# 4 gamble
mini = "".join(img("card_front_red" if i % 3 != 1 else "card_front_black", 196 + i * 44, 376, 44, 44) for i in range(5))
gamble = (f'<div class="a" style="left:60px;top:154px;width:480px;height:288px;background:rgba(10,6,3,.88)"></div>'
          + text("RISIKO", 60, 160, 480, 30, "title", 22, "#f2c14e", "center", 900)
          + text("Auf dem Spiel: <span style='color:#fff1cc;font-family:ArchN;font-weight:700;font-size:18px'>150</span> &nbsp;→&nbsp; bei Treffer <span style='color:#ffd76a;font-family:ArchN;font-weight:700;font-size:18px'>300</span>", 60, 190, 480, 24, "label", 14, "#e2cfa3", "center")
          + img("card_back", 230, 214, 140, 140)
          + button("danger", "normal", 92, 262, 120, 52, "ROT", "#ffffff", 20)
          + button("secondary", "hover", 388, 262, 120, 52, "SCHWARZ", "#ffffff", 20)
          + text("LETZTE KARTEN", 60, 360, 130, 16, "label", 10, "#c9ad7c", "right") + mini.replace("top:376px", "top:352px"))
S["04_risiko_karte"] = compose(header(toggles_enabled=False) + panels("1.950", "150", "#ffd76a"), grid(WINR), markers() + gamble
    + hint("Rot oder Schwarz? Richtig verdoppelt, falsch ist alles weg.", "win")
    + button("secondary", "normal", 22, 494, 300, 58, "NEHMEN 150", "#ffe08a", 18) + spin(state="disabled") + secondary())
# 5 three tomes
TOMER = [["tome", "crown", "potion", "gold", "sword"], ["silver", "sword", "tome", "copper", "dragon"], ["potion", "gold", "copper", "kraken", "tome"]]
ann = (f'<div class="a" style="left:0;top:0;width:{W}px;height:{H}px;background:rgba(5,2,10,.55)"></div>'
       + img("glow_soft", 150, 170, 300, 300, "opacity:.55;filter:hue-rotate(230deg)")
       + img("banner_freespins", 64, 132, 472, 118)
       + text("10 FREISPIELE", 64, 150, 472, 66, "title", 34, "#ffffff", "center", 900, "text-shadow:2px 2px 0 #1a0630")
       + f'<div class="a" style="left:172px;top:246px;width:256px;height:200px;overflow:hidden"><div style="width:256px;height:256px;margin-top:-30px;background:url({A}sprite_book_open_4x2.png) -768px -256px / 1024px 512px"></div></div>'
       + img("symbol_crown_win", 240, 226, 120, 120)
       + nine("panel_overlay", 16, 12, 190, 448, 220, 34)
       + text("Sondersymbol: <span style='color:#ffd76a'>Krone</span>", 190, 448, 220, 34, "label", 16, "#f3e2b8", "center"))
S["05_drei_folianten"] = compose(header(toggles_enabled=False) + panels("1.950", "100", "#ffd76a"), grid(TOMER, {(0, 0), (1, 2), (2, 4)}, True),
    markers() + hint("3 Folianten – 10 Freispiele!", "free") + stakes(enabled=False) + spin("START") + secondary(), overlay=ann)
# 6 free spin running
def fpanels(n, total, sym="crown", symname="Krone"):
    return (panel(22, 86, 180, 50, "FREISPIEL", f"{n} / 10", "#c6fbff")
            + panel(210, 86, 180, 50, "FREISPIEL-GEWINN", total, "#ffd76a")
            + nine("panel_inset", 16, 12, 398, 86, 180, 50) + text("SONDERSYMBOL", 410, 91, 120, 14, "label", 11, "#c9ad7c")
            + text(symname, 410, 106, 110, 26, "num", 22, "#fff1cc", weight=700) + img(f"symbol_{sym}", 526, 87, 48, 48))
FREE = [["sword", "gold", "potion", "copper", "kraken"], ["copper", "silver", "dragon", "sword", "gold"], ["kraken", "potion", "silver", "tome", "crown"]]
fs_footer_bal = text("GUTHABEN <span style='font-family:ArchN;font-weight:700;color:#fff1cc;font-size:16px'>1.950</span>", 360, 562, 218, 38, "label", 12, "#c9ad7c", "right")
S["06_freispiel_laeuft"] = compose(header(toggles_enabled=False) + fpanels(3, "240"), grid(FREE, shift={3: 40, 4: 70}),
    markers() + hint("Freispiel 3 von 10 – Einsatz wie beim Auslösen (50)", "free") + stakes(enabled=False) + spin("STOPP") + secondary(extra=fs_footer_bal), free=True)
# 7 expanding symbol
EXP = [["sword", "crown", "potion", "copper", "kraken"], ["copper", "silver", "dragon", "crown", "gold"], ["kraken", "potion", "silver", "tome", "sword"]]
S["07_sondersymbol_breitet_aus"] = compose(header(toggles_enabled=False) + fpanels(5, "740"), grid(EXP, set(), True, expand=(1, 3)) + paylines([0, 1, 2], .8),
    markers(set(range(10))) + hint("Krone breitet sich aus · 2 Walzen · alle 10 Linien · 250", "win") + stakes(enabled=False) + spin("WEITER") + secondary(extra=fs_footer_bal), free=True)
# 8 big win
BIG = [["gold", "crown", "potion", "copper", "kraken"], ["legendary"] * 5, ["kraken", "potion", "silver", "tome", "sword"]]
coins = ""
import random
random.seed(7)
for i in range(26):
    while True:
        x, y, s, k = random.randint(-10, 570), random.randint(60, 640), random.choice([26, 32, 40]), random.randint(0, 7)
        if not (70 < x < 520 and 180 < y < 410) and not (60 < x < 540 and 450 < y < 490):
            break
    coins += f'<div class="a" style="left:{x}px;top:{y}px;width:{s}px;height:{s}px;background:url({A}sprite_coin_spin_8x1.png) {-k * s}px 0 / {8 * s}px {s}px"></div>'
for i in range(9):
    x, y, k = random.randint(40, 540), random.randint(150, 450), random.randint(1, 5)
    coins += f'<div class="a" style="left:{x}px;top:{y}px;width:40px;height:40px;background:url({A}sprite_sparkle_8x1.png) {-k * 40}px 0 / 320px 40px"></div>'
big = (f'<div class="a" style="left:60px;top:154px;width:480px;height:288px;background:rgba(10,4,2,.45)"></div>'
       + f'<div class="a" style="left:60px;top:154px;width:480px;height:288px;overflow:hidden">{img("rays", -60, -156, 600, 600, "opacity:.85")}</div>'
       + img("banner_bigwin", 54, 196, 492, 123)
       + text("GROSSER GEWINN", 54, 214, 492, 70, "title", 34, "#ffe08a", "center", 900, "text-shadow:2px 2px 0 #3a0610")
       + text("25.000", 60, 318, 480, 80, "num", 72, "#ffffff", "center", 700, "text-shadow:3px 3px 0 #5a2a00")
       + img("shine", 150, 196, 40, 123, "opacity:.6") + coins)
S["08_grosser_gewinn"] = compose(header(toggles_enabled=False) + panels("1.950", "25.000", "#ffd76a"), grid(BIG, {(1, c) for c in range(5)}, True) + paylines([0], .6),
    markers({0}) + hint("Linie 1 · 5 × Legendäre Waffe", "win") + stakes(enabled=False) + spin("WEITER") + secondary(), overlay=big)
# 9 paytable
PAY = [("legendary", "Legendäre Waffe", ["5000", "1000", "100", "10"]), ("crown", "Krone", ["2000", "400", "40", "5"]),
       ("dragon", "Drache", ["750", "100", "30", "5"]), ("kraken", "Tiefenkrake", ["750", "100", "30", "5"]),
       ("sword", "Schwert", ["150", "40", "5", "–"]), ("potion", "Heiltrank", ["150", "40", "5", "–"]),
       ("gold", "Goldmünze", ["100", "25", "5", "–"]), ("silver", "Silbermünze", ["100", "25", "5", "–"]),
       ("copper", "Kupfermünze", ["100", "25", "5", "–"]), ("tome", "Foliant", ["200", "20", "2", "–"])]
pt = nine("panel_overlay", 16, 12, 22, 84, 556, 520) + text("GEWINNPLAN", 40, 92, 300, 32, "title", 20, "#f2c14e", weight=900)
pt += button("icon", "normal", 536, 94, 30, 28, icon="icon_close", lcolor="#ffd76a")
cols = [330, 390, 450, 510]
for j, h_ in enumerate(["5×", "4×", "3×", "2×"]):
    pt += text(h_, cols[j], 126, 52, 16, "label", 12, "#c9ad7c", "right")
pt += text("SYMBOL", 82, 126, 120, 16, "label", 11, "#c9ad7c")
for i, (k, n, v) in enumerate(PAY):
    y = 144 + i * 31
    if i % 2 == 0:
        pt += f'<div class="a" style="left:32px;top:{y}px;width:536px;height:31px;background:rgba(255,215,106,.05)"></div>'
    pt += img(f"symbol_{k}", 40, y, 31, 31) + text(n, 82, y, 200, 31, "label", 15, "#ffd76a" if i < 4 or k == "tome" else "#f3e2b8")
    for j, val in enumerate(v):
        pt += text(val, cols[j], y, 52, 31, "num", 16, "#fff1cc" if val != "–" else "#6b5a40", "right", 700)
pt += text("Werte × Linieneinsatz (Gesamteinsatz ÷ 10). Foliant: × Gesamteinsatz, überall auf dem Feld, ersetzt jedes Symbol, ab 3 = 10 Freispiele. <span style='color:#ff8a9a'>Beispielwerte</span>",
           32, 456, 536, 34, "label", 11, "#c9ad7c", extra="white-space:normal;line-height:15px")
for li, ln in enumerate(LINES):
    bx, by = 40 + (li % 5) * 106, 498 + (li // 5) * 50
    pt += text(str(li + 1), bx, by + 8, 14, 18, "num", 13, LCOL[li], weight=700)
    for r in range(3):
        for c in range(5):
            on = ln[c] == r
            pt += f'<div class="a" style="left:{bx + 18 + c * 15}px;top:{by + 4 + r * 13}px;width:12px;height:10px;background:{LCOL[li] if on else "#3a2a1a"}"></div>'
S["09_gewinnplan"] = compose(header() + panels("2.000", "–", "#7d6a4c"), grid(IDLE), markers() + stakes() + spin() + secondary(), overlay=pt)
# 10 guild without tokens
nt = (f'<div class="a" style="left:60px;top:154px;width:480px;height:288px;background:rgba(10,6,3,.78)"></div>'
      + nine("panel_overlay", 16, 12, 150, 226, 300, 144)
      + tint("icon_officer", 280, 240, 40, 40, "#f2c14e")
      + text("Noch keine Tokens.", 150, 284, 300, 34, "title", 22, "#f3e2b8", "center", 900)
      + text("Frag einen Officer.", 150, 318, 300, 26, "label", 16, "#c9ad7c", "center"))
S["10_gilde_ohne_tokens"] = compose(header("gilde") + panels("0", "–", "#7d6a4c").replace(">0<", ">0<"), grid(IDLE),
    markers() + nt + hint("Noch keine Tokens", "lose") + stakes(enabled=False) + spin(state="disabled") + secondary(officer=False))

# ---------------------------------------------------------------- officer window
OW, OH = 448, 728
def officer():
    o = f'<div class="a" style="left:0;top:0;width:{OW}px;height:{OH}px;background:url({A}bg_window_wood.png) repeat"></div>'
    o += text("Officer-Ansicht", 30, 22, 300, 42, "title", 22, "#f2c14e", weight=900, extra="text-shadow:2px 2px 0 #1a0d05")
    o += button("icon", "normal", 384, 29, 34, 32, icon="icon_close", lcolor="#ffd76a")
    o += nine("divider", 32, 32, 22, 68, 404, 12, "border-image-slice:0 32 fill;border-image-width:0 32px")
    o += text("TOKENS FREIGEBEN", 26, 86, 300, 16, "label", 12, "#ffd76a", extra="letter-spacing:1.5px")
    o += nine("panel_inset", 16, 12, 22, 106, 404, 170)
    for j, (h_, x, w, al) in enumerate([("SPIELER", 36, 140, "left"), ("RANG", 176, 100, "left"), ("GUTHABEN", 300, 110, "right")]):
        o += text(h_, x, 114, w, 16, "label", 10, "#c9ad7c", al)
    rows = [("Spieler 1", "Officer", "4.200"), ("Spieler 2", "Mitglied", "350"), ("Spieler 3", "Mitglied", "0"), ("Spieler 4", "Rekrut", "1.000"), ("Spieler 5", "Mitglied", "75")]
    for i, (n, r, b) in enumerate(rows):
        y = 134 + i * 27
        if i == 2:
            o += f'<div class="a" style="left:30px;top:{y}px;width:388px;height:27px;background:#4a3218"></div>'
            o += f'<div class="a" style="left:30px;top:{y}px;width:388px;height:1px;background:#ffd76a"></div><div class="a" style="left:30px;top:{y + 26}px;width:388px;height:1px;background:#ffd76a"></div>'
        o += text(n, 36, y, 140, 27, "label", 14, "#fff1cc" if i == 2 else "#f3e2b8")
        o += text(r, 176, y, 110, 27, "label", 13, "#c9ad7c")
        o += text(b, 300, y, 110, 27, "num", 15, "#fff1cc", "right", 700)
    o += img("scroll_thumb", 410, 132, 12, 60)
    o += text("Token-Anzahl", 26, 286, 110, 36, "label", 13, "#c9ad7c")
    o += nine("input_field_focus", 16, 10, 132, 286, 120, 36) + text("500", 144, 286, 96, 36, "num", 18, "#fff1cc", weight=700)
    o += f'<div class="a" style="left:184px;top:294px;width:2px;height:20px;background:#ffd76a"></div>'
    o += button("primary", "normal", 262, 282, 164, 44, "Freigeben", "#2a1606", 18, "title")
    o += text("an Spieler 3", 26, 324, 300, 18, "label", 12, "#a88e62")
    o += text("LETZTE KÄUFE", 26, 352, 300, 16, "label", 12, "#ffd76a", extra="letter-spacing:1.5px")
    o += nine("panel_inset", 16, 12, 22, 372, 404, 104)
    st = [("Spieler 2", "500", "vor 5 Min.", "Bestätigt", "#2f9e44", "#ffffff"), ("Spieler 4", "200", "vor 22 Min.", "Offen", "#e8a33a", "#1a0f05"), ("Spieler 1", "1.000", "gestern", "Abgelehnt", "#c0283a", "#ffffff")]
    for i, (n, a, t, s, bc, tc) in enumerate(st):
        y = 382 + i * 30
        o += text(n, 36, y, 110, 28, "label", 14, "#f3e2b8") + text(a, 140, y, 60, 28, "num", 15, "#fff1cc", "right", 700)
        o += text(t, 214, y, 90, 28, "label", 12, "#c9ad7c")
        o += tint("badge_status", 314, y + 3, 100, 22, bc) + text(s, 314, y + 3, 100, 22, "num", 13, tc, "center", 700, "text-shadow:none")
    o += text("GILDENEINSTELLUNGEN", 26, 490, 300, 16, "label", 12, "#ffd76a", extra="letter-spacing:1.5px")
    form = [("Sicherheitsstufe", "Officer online", True), ("Maximaleinsatz", "100", False), ("Mindestzahl online", "3", False)]
    for i, (l, v, dd) in enumerate(form):
        y = 512 + i * 42
        o += text(l, 26, y, 150, 36, "label", 13, "#c9ad7c")
        if dd:
            o += button("toggle", "normal", 182, y, 244, 36, "", "#fff", 14) + text(v, 194, y, 200, 34, "label", 14, "#f3e2b8") + tint("icon_chevron_down", 398, y + 9, 18, 18, "#ffd76a")
        else:
            o += nine("input_field_normal", 16, 10, 182, y, 110, 36) + text(v, 194, y, 90, 36, "num", 17, "#fff1cc", weight=700)
    o += text("Einstellungen als Textzeile (zum Teilen kopieren)", 26, 638, 400, 16, "label", 11, "#c9ad7c")
    o += nine("input_field_disabled", 16, 10, 22, 656, 360, 32) + text("GS2;stufe=officer;max=100;min=3;tab=T1", 32, 656, 340, 32, "num", 14, "#e2cfa3", weight=500)
    o += button("icon", "normal", 390, 656, 36, 32, icon="icon_copy", lcolor="#ffd76a")
    o += nine("frame_window", 48, 48, 0, 0, OW, OH)
    return page(o, OW, OH)

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        for scale, suffix in ((2, ""),):
            pg = await b.new_page(device_scale_factor=scale, viewport={"width": W, "height": H})
            for name, html in S.items():
                path = f"/home/claude/gs2/out/_{name}.html"
                open(path, "w").write(html)
                await pg.goto("file://" + path)
                await pg.wait_for_timeout(150)
                await pg.screenshot(path=f"{OUT}/zustand_{name}.png", clip={"x": 0, "y": 0, "width": W, "height": H}, omit_background=True)
            await pg.set_viewport_size({"width": OW, "height": OH})
            path = "/home/claude/gs2/out/_officer.html"
            open(path, "w").write(officer())
            await pg.goto("file://" + path)
            await pg.wait_for_timeout(150)
            await pg.screenshot(path=f"{OUT}/zustand_11_officer_ansicht.png", clip={"x": 0, "y": 0, "width": OW, "height": OH}, omit_background=True)
        await b.close()

asyncio.run(main())
print("ok")
