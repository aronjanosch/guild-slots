# Generates every texture of the Gildenslots v2 design as PNG (power-of-two sizes, transparent).
import math, os, json, asyncio
from playwright.async_api import async_playwright

OUT = "/home/claude/gs2/out/assets"
os.makedirs(OUT, exist_ok=True)
ASSETS = {}  # name -> (w, h, svg)

def add(name, w, h, body, defs=""):
    ASSETS[name] = (w, h, f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><defs>{defs}</defs>{body}</svg>')

def blur(id_, sd):
    return f'<filter id="{id_}" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="{sd}"/></filter>'

def lin(id_, stops, x2=0, y2=1):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<linearGradient id="{id_}" x1="0" y1="0" x2="{x2}" y2="{y2}">{s}</linearGradient>'

def rad(id_, stops, cx=.5, cy=.5, r=.5):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<radialGradient id="{id_}" cx="{cx}" cy="{cy}" r="{r}">{s}</radialGradient>'

# ------------------------------------------------------------------ symbols
def coin(face, rim, dark, hi, emblem):
    defs = rad("cf", [(0, hi, 1), (.55, face, 1), (1, dark, 1)], .38, .32, .75) + blur("b2", 2)
    body = f'''
<ellipse cx="128" cy="222" rx="70" ry="10" fill="#000" opacity=".35" filter="url(#b2)"/>
<circle cx="128" cy="124" r="88" fill="{dark}"/>
<circle cx="128" cy="124" r="82" fill="{rim}"/>
<circle cx="128" cy="124" r="74" fill="url(#cf)"/>
<circle cx="128" cy="124" r="56" fill="none" stroke="{dark}" stroke-width="5" opacity=".8"/>
<g fill="{dark}" opacity=".85">{emblem}</g>
<path d="M70 92 A64 64 0 0 1 112 56" stroke="#fff" stroke-width="7" fill="none" stroke-linecap="round" opacity=".7"/>
<path d="M186 66 l5 13 13 5 -13 5 -5 13 -5 -13 -13 -5 13 -5z" fill="#fff" opacity=".9"/>'''
    return body, defs

def sym_copper():
    return coin("#d58a55", "#a95e31", "#5e2a10", "#f7c6a0", '<path d="M128 90 L152 124 L128 158 L104 124Z"/>')
def sym_silver():
    return coin("#d7dee5", "#9aa6b1", "#46505a", "#ffffff",
                '<path d="M128 88 L138 113 L165 114 L144 131 L151 158 L128 143 L105 158 L112 131 L91 114 L118 113Z"/>')
def sym_gold():
    rays = "".join(f'<rect x="125" y="84" width="6" height="16" rx="3" transform="rotate({a} 128 124)"/>' for a in range(0, 360, 45))
    return coin("#f6c64f", "#d39a26", "#7a4a08", "#fff2b8", f'<circle cx="128" cy="124" r="18"/>{rays}')

def sym_potion():
    defs = lin("liq", [(0, "#ff5a6e", 1), (1, "#9e1024", 1)]) + rad("gl", [(0, "#ffffff", .35), (1, "#bfe1ec", .12)], .4, .35, .7) + blur("b2", 2)
    body = '''
<ellipse cx="128" cy="226" rx="62" ry="9" fill="#000" opacity=".35" filter="url(#b2)"/>
<rect x="108" y="30" width="40" height="26" rx="6" fill="#8a5a2b" stroke="#3a220e" stroke-width="3"/>
<rect x="104" y="54" width="48" height="12" rx="4" fill="#d6c6a0" stroke="#3a220e" stroke-width="3"/>
<path d="M112 66 h32 v30 a66 66 0 1 1 -32 0z" fill="url(#gl)" stroke="#e9f7fb" stroke-width="5"/>
<path d="M64 150 a64 64 0 0 0 128 0 z" fill="url(#liq)"/>
<path d="M64 150 h128" stroke="#ff9aa8" stroke-width="3"/>
<circle cx="104" cy="176" r="8" fill="#ffb3bf" opacity=".8"/><circle cx="142" cy="192" r="5" fill="#ffb3bf" opacity=".8"/><circle cx="150" cy="166" r="4" fill="#ffb3bf" opacity=".8"/>
<path d="M78 128 a52 52 0 0 1 24 -26" stroke="#fff" stroke-width="7" fill="none" stroke-linecap="round" opacity=".85"/>
<path d="M124 112 h8 v12 h12 v8 h-12 v12 h-8 v-12 h-12 v-8 h12z" fill="#fff" opacity=".85"/>'''
    return body, defs

def sym_sword():
    defs = lin("bl", [(0, "#ffffff", 1), (.5, "#c9d3dc", 1), (1, "#7d8a96", 1)], 1, 0) + blur("b2", 2)
    body = '''
<ellipse cx="128" cy="228" rx="60" ry="8" fill="#000" opacity=".35" filter="url(#b2)"/>
<g transform="rotate(40 128 128)">
<path d="M116 158 V44 L128 18 L140 44 V158Z" fill="url(#bl)" stroke="#3a434c" stroke-width="3"/>
<path d="M128 26 V156" stroke="#7d8a96" stroke-width="3"/>
<rect x="84" y="154" width="88" height="16" rx="7" fill="#d6a23e" stroke="#5a3708" stroke-width="3"/>
<rect x="119" y="170" width="18" height="40" rx="3" fill="#5a3a22" stroke="#2a1606" stroke-width="3"/>
<path d="M119 180 l18 8 M119 192 l18 8" stroke="#8a5a3a" stroke-width="3"/>
<circle cx="128" cy="218" r="12" fill="#d6a23e" stroke="#5a3708" stroke-width="3"/>
</g>'''
    return body, defs

def medallion(inner_hi, inner_lo, rim="#f2c14e", rimdark="#7a4a08"):
    defs = rad("md", [(0, inner_hi, 1), (1, inner_lo, 1)], .5, .4, .7) + lin("rim", [(0, "#fff2b8", 1), (.5, rim, 1), (1, rimdark, 1)]) + blur("b2", 2) + blur("b6", 6)
    studs = "".join(f'<circle cx="{128 + 98 * math.cos(math.radians(a)):.1f}" cy="{128 + 98 * math.sin(math.radians(a)):.1f}" r="4.5" fill="#fff2b8" stroke="{rimdark}" stroke-width="1.5"/>' for a in range(0, 360, 45))
    body = f'''
<ellipse cx="128" cy="236" rx="80" ry="9" fill="#000" opacity=".4" filter="url(#b2)"/>
<circle cx="128" cy="128" r="108" fill="#1a0d05"/>
<circle cx="128" cy="128" r="104" fill="url(#rim)"/>
<circle cx="128" cy="128" r="90" fill="#1a0d05"/>
<circle cx="128" cy="128" r="87" fill="url(#md)"/>
{studs}'''
    return body, defs

def sym_kraken():
    mb, md = medallion("#2c6f7a", "#0b2a33")
    body = mb + '''
<g stroke="#0b3b36" stroke-width="4" stroke-linecap="round" fill="none">
<path d="M96 146 C80 172 70 192 88 206 C98 212 108 202 100 194" stroke="#2fae9b" stroke-width="15"/>
<path d="M116 154 C110 182 106 200 122 210" stroke="#2fae9b" stroke-width="15"/>
<path d="M140 154 C146 182 150 200 134 210" stroke="#2fae9b" stroke-width="15"/>
<path d="M160 146 C176 172 186 192 168 206 C158 212 148 202 156 194" stroke="#2fae9b" stroke-width="15"/>
</g>
<g fill="#bff5ea"><circle cx="84" cy="184" r="3"/><circle cx="110" cy="190" r="3"/><circle cx="146" cy="190" r="3"/><circle cx="172" cy="184" r="3"/></g>
<path d="M70 120 C70 62 186 62 186 120 C186 150 160 160 128 160 C96 160 70 150 70 120Z" fill="#2fae9b" stroke="#0b3b36" stroke-width="4"/>
<circle cx="96" cy="88" r="7" fill="#6b3fa0"/><circle cx="160" cy="86" r="9" fill="#6b3fa0"/><circle cx="128" cy="74" r="6" fill="#6b3fa0"/><circle cx="176" cy="110" r="5" fill="#6b3fa0"/>
<circle cx="106" cy="120" r="17" fill="#ffe9a0" stroke="#0b3b36" stroke-width="3"/><circle cx="150" cy="120" r="17" fill="#ffe9a0" stroke="#0b3b36" stroke-width="3"/>
<ellipse cx="108" cy="122" rx="7" ry="10" fill="#120a04"/><ellipse cx="148" cy="122" rx="7" ry="10" fill="#120a04"/>
<circle cx="101" cy="113" r="3" fill="#fff"/><circle cx="145" cy="113" r="3" fill="#fff"/>
<path d="M86 84 C96 70 112 64 124 64" stroke="#a6fff2" stroke-width="6" fill="none" stroke-linecap="round" opacity=".8"/>'''
    return body, md

def sym_dragon():
    mb, md = medallion("#8e2a1a", "#2a0805")
    body = mb + '''
<path d="M112 104 C100 80 92 62 72 46 C96 54 114 72 128 98Z" fill="#efe1b8" stroke="#3a0905" stroke-width="3"/>
<path d="M130 96 C126 74 124 56 112 36 C134 52 142 74 146 96Z" fill="#efe1b8" stroke="#3a0905" stroke-width="3"/>
<path d="M66 206 C62 164 74 128 102 108 C118 96 136 90 154 92 C172 94 188 100 202 110 L216 118 C222 123 221 132 213 134 L196 137 C200 143 198 151 190 153 L168 151 C156 166 140 178 118 186 C104 198 92 208 66 206Z" fill="#c8402e" stroke="#3a0905" stroke-width="4" stroke-linejoin="round"/>
<path d="M90 120 L74 112 L84 132Z M80 146 L62 142 L76 160Z M74 172 L56 172 L70 186Z" fill="#7a1a12" stroke="#3a0905" stroke-width="2"/>
<path d="M168 151 C176 142 188 139 196 137" stroke="#3a0905" stroke-width="3" fill="none"/>
<path d="M176 147 l4 9 4 -9 M186 144 l3 7 3 -8" fill="#fff" stroke="#3a0905" stroke-width="1.5"/>
<path d="M96 192 C104 178 110 166 112 152 M110 186 C120 176 128 166 132 156" stroke="#f08a6a" stroke-width="4" fill="none" stroke-linecap="round"/>
<ellipse cx="152" cy="112" rx="11" ry="7" fill="#ffd05a" stroke="#3a0905" stroke-width="2.5"/>
<ellipse cx="152" cy="112" rx="2.5" ry="6" fill="#1a0905"/>
<path d="M136 103 L168 99" stroke="#3a0905" stroke-width="5" stroke-linecap="round"/>
<circle cx="206" cy="120" r="3" fill="#3a0905"/>
<path d="M112 112 C126 100 146 96 164 98" stroke="#ff9a7a" stroke-width="4" fill="none" stroke-linecap="round" opacity=".8"/>'''
    return body, md

def sym_crown():
    mb, md = medallion("#5a2e8a", "#1c0b30")
    md += lin("cg", [(0, "#fff2b8", 1), (.45, "#f2c14e", 1), (1, "#9a6516", 1)])
    body = mb + '''
<path d="M62 156 L54 88 L94 118 L128 66 L162 118 L202 88 L194 156Z" fill="url(#cg)" stroke="#5a3708" stroke-width="4" stroke-linejoin="round"/>
<circle cx="54" cy="86" r="10" fill="url(#cg)" stroke="#5a3708" stroke-width="3"/><circle cx="128" cy="62" r="11" fill="url(#cg)" stroke="#5a3708" stroke-width="3"/><circle cx="202" cy="86" r="10" fill="url(#cg)" stroke="#5a3708" stroke-width="3"/>
<rect x="58" y="152" width="140" height="32" rx="6" fill="url(#cg)" stroke="#5a3708" stroke-width="4"/>
<path d="M128 106 L140 122 L128 138 L116 122Z" fill="#b04cff" stroke="#3a0d5a" stroke-width="2.5"/>
<circle cx="128" cy="168" r="10" fill="#e0304a" stroke="#5a0a14" stroke-width="2.5"/>
<circle cx="92" cy="168" r="8" fill="#3a8cff" stroke="#0a2a5a" stroke-width="2.5"/>
<circle cx="164" cy="168" r="8" fill="#2fcf6a" stroke="#0a4a20" stroke-width="2.5"/>
<path d="M72 146 L68 104" stroke="#fff" stroke-width="5" stroke-linecap="round" opacity=".75"/>
<circle cx="124" cy="164" r="3" fill="#fff" opacity=".9"/>'''
    return body, md

def sym_legendary():
    mb, md = medallion("#5a1e05", "#1a0702", "#ffb347", "#7a3000")
    md += lin("blade", [(0, "#ff8a1f", 1), (.5, "#fff6d0", 1), (1, "#ff8a1f", 1)], 1, 0) + blur("aura", 9)
    blade = "M128 30 L146 62 L150 92 L142 168 L114 168 L106 92 L110 62Z"
    body = mb + f'''
<g transform="rotate(32 128 128)">
<path d="{blade}" fill="#ff7a00" filter="url(#aura)" opacity=".95"/>
<path d="{blade}" fill="#ff7a00" filter="url(#aura)" opacity=".7" transform="translate(0 0) scale(1)"/>
<path d="{blade}" fill="url(#blade)" stroke="#7a2a00" stroke-width="3"/>
<path d="M128 44 V160" stroke="#ff9a2e" stroke-width="3"/>
<path d="M122 76 l6 6 6 -6 M122 104 l6 6 6 -6 M122 132 l6 6 6 -6" stroke="#c84a00" stroke-width="3" fill="none"/>
<path d="M82 166 C96 152 112 162 128 164 C144 162 160 152 174 166 C164 180 144 178 128 178 C112 178 92 180 82 166Z" fill="#f2b632" stroke="#5a2a00" stroke-width="3"/>
<circle cx="128" cy="170" r="7" fill="#ff5a00" stroke="#5a2a00" stroke-width="2"/>
<rect x="121" y="178" width="14" height="30" rx="3" fill="#5a1a10" stroke="#2a0a04" stroke-width="2.5"/>
<circle cx="128" cy="214" r="9" fill="#f2b632" stroke="#5a2a00" stroke-width="2.5"/><circle cx="128" cy="214" r="4" fill="#ff5a00"/>
</g>
<g fill="#ffe0a0"><path d="M70 70 l3 8 8 3 -8 3 -3 8 -3 -8 -8 -3 8 -3z"/><path d="M188 178 l2.5 6 6 2.5 -6 2.5 -2.5 6 -2.5 -6 -6 -2.5 6 -2.5z"/></g>'''
    return body, md

def sym_tome():
    defs = rad("burst", [(0, "#c08bff", .9), (.5, "#7b3fe0", .45), (1, "#7b3fe0", 0)]) + lin("cov", [(0, "#6a2fa0", 1), (1, "#2c0f4a", 1)], 1, 1) + blur("b5", 5) + blur("b2", 2)
    rays = "".join(f'<path d="M128 128 L{128 + 114 * math.cos(math.radians(a - 6)):.1f} {128 + 114 * math.sin(math.radians(a - 6)):.1f} L{128 + 114 * math.cos(math.radians(a + 6)):.1f} {128 + 114 * math.sin(math.radians(a + 6)):.1f}Z" fill="#e0c6ff" opacity=".22"/>' for a in range(0, 360, 30))
    rune = "".join(f'<path d="M{128 + 22 * math.cos(math.radians(a)):.1f} {128 + 22 * math.sin(math.radians(a)):.1f} L{128 + 34 * math.cos(math.radians(a)):.1f} {128 + 34 * math.sin(math.radians(a)):.1f}" />' for a in range(0, 360, 60))
    body = f'''
<circle cx="128" cy="128" r="116" fill="url(#burst)"/>{rays}
<ellipse cx="132" cy="226" rx="70" ry="8" fill="#000" opacity=".45" filter="url(#b2)"/>
<rect x="66" y="50" width="144" height="168" rx="8" fill="#efe2bf" stroke="#3a2a10" stroke-width="3"/>
<path d="M76 56 V212 M84 56 V212" stroke="#c9b68a" stroke-width="2"/>
<rect x="52" y="40" width="144" height="172" rx="10" fill="url(#cov)" stroke="#1a0630" stroke-width="4"/>
<rect x="52" y="40" width="22" height="172" rx="8" fill="#2c0f4a" stroke="#1a0630" stroke-width="3"/>
<path d="M52 58 h22 M52 194 h22" stroke="#f2c14e" stroke-width="5"/>
<path d="M196 40 L172 40 L196 64Z M196 212 L172 212 L196 188Z" fill="#f2c14e" stroke="#5a3708" stroke-width="2"/>
<rect x="186" y="112" width="22" height="32" rx="4" fill="#f2c14e" stroke="#5a3708" stroke-width="2.5"/>
<g transform="translate(6 0)">
<circle cx="128" cy="128" r="40" fill="none" stroke="#6ff0ff" stroke-width="9" filter="url(#b5)"/>
<circle cx="128" cy="128" r="40" fill="none" stroke="#c6fbff" stroke-width="4"/>
<circle cx="128" cy="128" r="14" fill="#c6fbff"/>
<g stroke="#c6fbff" stroke-width="4" stroke-linecap="round">{rune}</g>
</g>
<path d="M66 56 C80 50 96 48 110 48" stroke="#b98ae6" stroke-width="5" fill="none" stroke-linecap="round" opacity=".8"/>'''
    return body, defs

SYMBOLS = {
    "copper": sym_copper, "silver": sym_silver, "gold": sym_gold, "potion": sym_potion, "sword": sym_sword,
    "kraken": sym_kraken, "dragon": sym_dragon, "crown": sym_crown, "legendary": sym_legendary, "tome": sym_tome,
}
WIN_COLOR = {"legendary": "#ff8a1f", "tome": "#c08bff"}

for key, fn in SYMBOLS.items():
    body, defs = fn()
    add(f"symbol_{key}", 256, 256, body, defs)
    c = WIN_COLOR.get(key, "#ffd76a")
    wdefs = defs + blur("wg", 9) + rad("wf", [(0, c, .5), (1, c, 0)]) + '<filter id="br"><feComponentTransfer><feFuncR type="linear" slope="1.18"/><feFuncG type="linear" slope="1.18"/><feFuncB type="linear" slope="1.12"/></feComponentTransfer></filter>'
    wbody = f'''
<rect x="10" y="10" width="236" height="236" rx="30" fill="url(#wf)"/>
<rect x="16" y="16" width="224" height="224" rx="28" fill="none" stroke="{c}" stroke-width="14" filter="url(#wg)"/>
<rect x="16" y="16" width="224" height="224" rx="28" fill="none" stroke="#fff6d8" stroke-width="5"/>
<g filter="url(#br)" transform="translate(128 128) scale(.88) translate(-128 -128)">{body}</g>'''
    add(f"symbol_{key}_win", 256, 256, wbody, wdefs)

# ------------------------------------------------------------------ window, reels, backgrounds
def frame_window(name, wood, wood2, trim, trimhi, trimdk, gem):
    d = blur("ish", 4)
    corners = ""
    for (x, y) in [(18, 18), (238, 18), (18, 238), (238, 238)]:
        corners += f'<path d="M{x} {y-15} L{x+15} {y} L{x} {y+15} L{x-15} {y}Z" fill="{trim}" stroke="{trimdk}" stroke-width="2.5"/><circle cx="{x}" cy="{y}" r="5.5" fill="{gem}" stroke="{trimdk}" stroke-width="1.5"/>'
    body = f'''
<rect x="1" y="1" width="254" height="254" rx="12" fill="none" stroke="#050302" stroke-width="2"/>
<rect x="6" y="6" width="244" height="244" rx="9" fill="none" stroke="{wood}" stroke-width="8"/>
<rect x="11" y="11" width="234" height="234" rx="7" fill="none" stroke="{wood2}" stroke-width="4"/>
<rect x="15" y="15" width="226" height="226" rx="5" fill="none" stroke="{trimdk}" stroke-width="3"/>
<rect x="17.5" y="17.5" width="221" height="221" rx="4" fill="none" stroke="{trimhi}" stroke-width="2"/>
<rect x="20" y="20" width="216" height="216" rx="3" fill="none" stroke="{trimdk}" stroke-width="1.5"/>
<rect x="26" y="26" width="204" height="204" fill="none" stroke="#000" stroke-width="8" opacity=".55" filter="url(#ish)"/>
{corners}'''
    add(name, 256, 256, body, d)

frame_window("frame_window", "#4a2e17", "#2f1c0d", "#f2c14e", "#ffe08a", "#7a4a08", "#c0283a")
frame_window("frame_window_freespin", "#2a1f4e", "#17112e", "#b9a6ff", "#e6dcff", "#3a2a7a", "#4fd2ff")

def frame_reels(name, a, b, c, d_, glow):
    df = blur("g3", 3)
    rivets = "".join(f'<circle cx="{x}" cy="{y}" r="3.5" fill="{b}" stroke="{d_}" stroke-width="1.5"/>' for x, y in [(9, 9), (247, 9), (9, 247), (247, 247)])
    body = f'''
<rect x="1" y="1" width="254" height="254" rx="16" fill="none" stroke="#050302" stroke-width="2"/>
<rect x="3.5" y="3.5" width="249" height="249" rx="14" fill="none" stroke="{b}" stroke-width="3"/>
<rect x="7.5" y="7.5" width="241" height="241" rx="11" fill="none" stroke="{a}" stroke-width="5"/>
<rect x="11.5" y="11.5" width="233" height="233" rx="8" fill="none" stroke="{c}" stroke-width="3"/>
<rect x="14" y="14" width="228" height="228" rx="6" fill="none" stroke="{d_}" stroke-width="2"/>
<rect x="16" y="16" width="224" height="224" rx="5" fill="none" stroke="{glow}" stroke-width="4" opacity=".55" filter="url(#g3)"/>
{rivets}'''
    add(name, 256, 256, body, df)

frame_reels("frame_reels", "#d29a2e", "#ffe08a", "#8f5c10", "#2a1606", "#000000")
frame_reels("frame_reels_freespin", "#7b3fe0", "#e6dcff", "#3a1a6e", "#0e0820", "#4fd2ff")

def wood_tile(name, cols, gap, grain1, grain2, knot):
    body = ""
    for i, col in enumerate(cols):
        x = i * 64
        body += f'<rect x="{x}" y="0" width="64" height="256" fill="{col}"/>'
        for j in range(6):
            gx = x + 8 + j * 9 + (i * 3 + j * 5) % 5
            amp = 2 + (i + j) % 3
            ph = (i * 37 + j * 61) % 256
            pts = " ".join(f"{gx + amp * math.sin(2 * math.pi * (y + ph) / 256):.2f},{y}" for y in range(0, 257, 8))
            body += f'<polyline points="{pts}" fill="none" stroke="{grain1 if j % 2 else grain2}" stroke-width="{1.2 if j % 2 else .8}" opacity=".55"/>'
        body += f'<rect x="{x}" y="0" width="2" height="256" fill="{gap}"/>'
    body += f'<ellipse cx="160" cy="150" rx="7" ry="13" fill="{knot}" opacity=".8"/><ellipse cx="160" cy="150" rx="11" ry="20" fill="none" stroke="{knot}" stroke-width="1.5" opacity=".6"/>'
    body += f'<ellipse cx="38" cy="60" rx="5" ry="9" fill="{knot}" opacity=".7"/>'
    add(name, 256, 256, body)

wood_tile("bg_window_wood", ["#2c1b0e", "#26170c", "#2f1d10", "#24160b"], "#0e0804", "#1a0f06", "#3d2615", "#170d05")
wood_tile("bg_window_freespin", ["#1d1636", "#191230", "#20183b", "#171029"], "#07040f", "#0d0920", "#2f2560", "#0b0718")

def bg_reels():
    d = lin("col", [(0, "#1c120b", 1), (.5, "#3b2a1b", 1), (1, "#1c120b", 1)])
    body = ""
    w = 512 / 5
    for i in range(5):
        body += f'<rect x="{i * w:.1f}" y="0" width="{w:.1f}" height="256" fill="url(#col)"/>'
    for i in range(1, 5):
        body += f'<rect x="{i * w - 1.5:.1f}" y="0" width="3" height="256" fill="#0a0503"/><rect x="{i * w + 1.5:.1f}" y="0" width="1" height="256" fill="#8f5c10" opacity=".45"/>'
    add("bg_reels", 512, 256, body, d)
bg_reels()
add("reel_shade", 64, 256, '<rect width="64" height="256" fill="url(#s)"/>',
    lin("s", [(0, "#000", .75), (.22, "#000", 0), (.78, "#000", 0), (1, "#000", .75)]))
add("bg_reels_freespin", 512, 256, "".join(
    f'<rect x="{i * 102.4:.1f}" y="0" width="102.4" height="256" fill="url(#col)"/>' for i in range(5)) + "".join(
    f'<rect x="{i * 102.4 - 1.5:.1f}" y="0" width="3" height="256" fill="#05030c"/><rect x="{i * 102.4 + 1.5:.1f}" y="0" width="1" height="256" fill="#7b3fe0" opacity=".5"/>' for i in range(1, 5)),
    lin("col", [(0, "#120c26", 1), (.5, "#2a2050", 1), (1, "#120c26", 1)]))

# ------------------------------------------------------------------ panels, inputs, badges
def panel(name, size, r, fill, rim, inner="#000"):
    d = blur("i", 2.5)
    add(name, size, size, f'''
<rect x="1" y="1" width="{size-2}" height="{size-2}" rx="{r}" fill="{fill}" stroke="#000" stroke-width="2"/>
<rect x="2.5" y="2.5" width="{size-5}" height="{size-5}" rx="{r-1}" fill="none" stroke="{rim}" stroke-width="1.5"/>
<rect x="5" y="5" width="{size-10}" height="{size-10}" rx="{r-3}" fill="none" stroke="{inner}" stroke-width="3" opacity=".6" filter="url(#i)"/>''', d)

panel("panel_inset", 64, 12, "#0d0805", "#8f5c10")
panel("panel_overlay", 64, 12, "#120b06", "#c8932e")
panel("input_field_normal", 64, 8, "#0a0603", "#5a3f1c")
panel("input_field_focus", 64, 8, "#0d0805", "#ffd76a")
panel("input_field_disabled", 64, 8, "#1a1510", "#3a3024")
add("badge_status", 64, 32, '<rect x="1" y="1" width="62" height="30" rx="15" fill="#ffffff"/><rect x="3" y="3" width="58" height="12" rx="6" fill="#ffffff" opacity=".0"/>')
add("scroll_thumb", 32, 64, '<rect x="8" y="2" width="16" height="60" rx="8" fill="#8f5c10" stroke="#2a1606" stroke-width="2"/><rect x="12" y="8" width="4" height="48" rx="2" fill="#ffd76a" opacity=".6"/>')
add("divider", 256, 16, '''
<rect x="24" y="7" width="208" height="2" fill="#8f5c10"/>
<path d="M4 8 L18 2 L32 8 L18 14Z" fill="#f2c14e" stroke="#5a3708" stroke-width="1.5"/>
<path d="M224 8 L238 2 L252 8 L238 14Z" fill="#f2c14e" stroke="#5a3708" stroke-width="1.5"/>''')

# ------------------------------------------------------------------ buttons
def button(prefix, w, h, slice_, palette):
    r = slice_ * .55
    for state, p in palette.items():
        top, bot, rim, outline, gloss, dy, shadow = p
        d = lin("f", [(0, top, 1), (1, bot, 1)]) + lin("g", [(0, "#fff", gloss), (1, "#fff", 0)]) + blur("sh", 2.5)
        body = ""
        if shadow:
            body += f'<rect x="4" y="7" width="{w-8}" height="{h-9}" rx="{r}" fill="#000" opacity=".5" filter="url(#sh)"/>'
        body += f'''<g transform="translate(0 {dy})">
<rect x="2" y="2" width="{w-4}" height="{h-6}" rx="{r}" fill="{outline}"/>
<rect x="4" y="4" width="{w-8}" height="{h-10}" rx="{r-2}" fill="url(#f)" stroke="{rim}" stroke-width="2"/>
<rect x="8" y="7" width="{w-16}" height="{(h-10)*.42:.1f}" rx="{r-5}" fill="url(#g)"/></g>'''
        add(f"{prefix}_{state}", w, h, body, d)

button("button_primary", 256, 128, 40, {
    "normal": ("#ffdc75", "#b8700f", "#fff1b0", "#3a1f05", .55, 0, True),
    "hover": ("#fff0a8", "#d08a1c", "#ffffff", "#3a1f05", .65, 0, True),
    "pressed": ("#b8700f", "#e8a83a", "#f2c14e", "#3a1f05", .15, 3, False),
    "disabled": ("#8a7a60", "#4e4232", "#a8987c", "#1e180f", .15, 0, False)})
button("button_secondary", 128, 64, 20, {
    "normal": ("#4a3218", "#1f150b", "#c8932e", "#0a0603", .18, 0, True),
    "hover": ("#5e4020", "#2a1c0e", "#ffd76a", "#0a0603", .25, 0, True),
    "pressed": ("#160e07", "#2e1f10", "#c8932e", "#0a0603", .05, 2, False),
    "disabled": ("#2e271f", "#1c1813", "#4e4234", "#0a0806", .05, 0, False)})
button("button_danger", 128, 64, 20, {
    "normal": ("#c23345", "#5e0f1a", "#ff9aa8", "#1a0306", .3, 0, True),
    "hover": ("#de4a5c", "#76141f", "#ffd0d6", "#1a0306", .38, 0, True),
    "pressed": ("#5e0f1a", "#9a2232", "#ff9aa8", "#1a0306", .08, 2, False),
    "disabled": ("#5a4446", "#2e2324", "#6e5a5c", "#120c0c", .05, 0, False)})
button("button_toggle", 128, 64, 20, {
    "normal": ("#2e2012", "#170f08", "#6b4a1f", "#050302", .12, 0, False),
    "hover": ("#3e2b17", "#21160b", "#c8932e", "#050302", .18, 0, False),
    "pressed": ("#0f0a05", "#1d140b", "#6b4a1f", "#050302", .0, 1, False),
    "selected": ("#8a5f1c", "#3e2808", "#ffd76a", "#050302", .35, 0, False),
    "disabled": ("#221c16", "#15110d", "#3a3024", "#050302", .0, 0, False)})
button("button_icon", 64, 64, 16, {
    "normal": ("#2e2012", "#170f08", "#6b4a1f", "#050302", .12, 0, False),
    "hover": ("#3e2b17", "#21160b", "#c8932e", "#050302", .18, 0, False),
    "pressed": ("#0f0a05", "#1d140b", "#6b4a1f", "#050302", .0, 1, False),
    "disabled": ("#221c16", "#15110d", "#3a3024", "#050302", .0, 0, False)})

# ------------------------------------------------------------------ icons (white, tinted in game)
def icon(name, inner):
    add(name, 64, 64, f'<g fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round">{inner}</g>')
icon("icon_sound_on", '<path d="M10 26v12h10l12 10V16L20 26z" fill="#fff"/><path d="M40 24a11 11 0 0 1 0 16M46 17a20 20 0 0 1 0 30"/>')
icon("icon_sound_off", '<path d="M10 26v12h10l12 10V16L20 26z" fill="#fff"/><path d="M42 25l12 14M54 25l-12 14"/>')
icon("icon_close", '<path d="M18 18l28 28M46 18L18 46"/>')
icon("icon_paytable", '<path d="M18 10h28v44H18z"/><path d="M25 22h14M25 32h14M25 42h9"/>')
icon("icon_officer", '<path d="M32 8l20 8v14c0 13-9 22-20 26-11-4-20-13-20-26V16z"/><path d="M32 22l3.5 7 7.5 1-5.5 5 1.5 7.5-7-4-7 4 1.5-7.5-5.5-5 7.5-1z" fill="#fff" stroke-width="2"/>')
icon("icon_chevron_down", '<path d="M18 26l14 14 14-14"/>')
icon("icon_copy", '<rect x="20" y="20" width="30" height="34" rx="4"/><path d="M14 44V14a4 4 0 0 1 4-4h22"/>')
icon("icon_check", '<path d="M14 34l12 12 24-26"/>')
icon("icon_coin", '<circle cx="32" cy="32" r="22" fill="#fff" stroke="none"/><circle cx="32" cy="32" r="14" stroke="#000" stroke-opacity=".35" stroke-width="4"/>')

# ------------------------------------------------------------------ lines, glows, markers
add("linemarker_normal", 64, 64, '<circle cx="32" cy="32" r="27" fill="#0d0805" stroke="#000" stroke-width="2"/><circle cx="32" cy="32" r="24" fill="#2a1c11" stroke="#8f5c10" stroke-width="3"/>')
add("linemarker_lit", 64, 64, '<circle cx="32" cy="32" r="31" fill="url(#g)"/><circle cx="32" cy="32" r="24" fill="#ffffff" stroke="#000" stroke-width="2.5"/><circle cx="32" cy="32" r="20" fill="none" stroke="#000" stroke-opacity=".25" stroke-width="2"/>',
    rad("g", [(0, "#fff", .9), (.75, "#fff", .5), (1, "#fff", 0)]))
add("line_glow", 128, 32, '<rect x="0" y="0" width="128" height="32" fill="url(#g)"/><rect x="0" y="13" width="128" height="6" fill="#fff"/>',
    lin("g", [(0, "#fff", 0), (.5, "#fff", .55), (1, "#fff", 0)]))
add("glow_cell", 128, 128, '<rect x="14" y="14" width="100" height="100" rx="16" fill="none" stroke="#fff" stroke-width="14" filter="url(#b)"/><rect x="14" y="14" width="100" height="100" rx="16" fill="none" stroke="#fff" stroke-width="4"/>', blur("b", 6))
add("glow_soft", 128, 128, '<circle cx="64" cy="64" r="64" fill="url(#g)"/>', rad("g", [(0, "#fff", 1), (.4, "#fff", .45), (1, "#fff", 0)]))
add("rays", 512, 512, '<circle cx="256" cy="256" r="256" fill="url(#m)"/>' + "".join(
    f'<path d="M256 256 L{256 + 260 * math.cos(math.radians(a - 4)):.1f} {256 + 260 * math.sin(math.radians(a - 4)):.1f} L{256 + 260 * math.cos(math.radians(a + 4)):.1f} {256 + 260 * math.sin(math.radians(a + 4)):.1f}Z" fill="url(#r)"/>' for a in range(0, 360, 20)),
    rad("r", [(0, "#ffe9a8", .9), (1, "#ffe9a8", 0)]) + rad("m", [(0, "#fff3c4", .6), (.5, "#ffd76a", .15), (1, "#ffd76a", 0)]))
add("shine", 64, 256, '<path d="M24 0 h22 L40 256 h-22z" fill="url(#g)"/>', lin("g", [(0, "#fff", 0), (.5, "#fff", .8), (1, "#fff", 0)], 1, 0))
add("expand_column", 128, 512, '<rect x="0" y="0" width="128" height="512" fill="url(#g)"/><rect x="40" y="0" width="48" height="512" fill="url(#c)"/>' + "".join(
    f'<path d="M{x} {y} l3 8 8 3 -8 3 -3 8 -3 -8 -8 -3 8 -3z" fill="#fff" opacity=".8"/>' for x, y in [(30, 60), (96, 140), (52, 250), (90, 360), (34, 440)]),
    lin("g", [(0, "#ffb347", .25), (.5, "#ffd76a", .55), (1, "#ffb347", .25)], 1, 0) + lin("c", [(0, "#fff", 0), (.5, "#fff3c4", .5), (1, "#fff", 0)], 1, 0))

# ------------------------------------------------------------------ banners
def banner(name, fill1, fill2, trim, trimdk):
    d = lin("f", [(0, fill1, 1), (1, fill2, 1)]) + lin("t", [(0, "#fff2b8", 1), (.5, trim, 1), (1, trimdk, 1)])
    add(name, 512, 128, f'''
<path d="M6 40 L70 40 L70 108 L6 108 L28 74Z" fill="{fill2}" stroke="{trimdk}" stroke-width="3"/>
<path d="M506 40 L442 40 L442 108 L506 108 L484 74Z" fill="{fill2}" stroke="{trimdk}" stroke-width="3"/>
<path d="M70 108 L84 96 L84 108Z M442 108 L428 96 L428 108Z" fill="#000" opacity=".6"/>
<rect x="56" y="16" width="400" height="82" rx="8" fill="url(#t)" stroke="#1a0d05" stroke-width="3"/>
<rect x="64" y="23" width="384" height="68" rx="5" fill="url(#f)"/>
<rect x="70" y="28" width="372" height="22" rx="4" fill="#fff" opacity=".12"/>
<circle cx="78" cy="57" r="5" fill="#fff2b8"/><circle cx="434" cy="57" r="5" fill="#fff2b8"/>''', d)
banner("banner_bigwin", "#b72a3a", "#4a0a14", "#f2c14e", "#7a4a08")
banner("banner_freespins", "#7b3fe0", "#22104a", "#b9a6ff", "#3a2a7a")

# ------------------------------------------------------------------ cards
def card(name, inner):
    d = blur("sh", 3) + lin("cf", [(0, "#fbf3df", 1), (1, "#e8d9b0", 1)]) + lin("cb", [(0, "#8e1b2a", 1), (1, "#4a0a14", 1)]) + \
        '<pattern id="lat" width="20" height="20" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="20" height="20" fill="none"/><path d="M0 0 H20 M0 0 V20" stroke="#f2c14e" stroke-opacity=".35" stroke-width="2"/></pattern>'
    add(name, 256, 256, f'<rect x="46" y="12" width="168" height="240" rx="14" fill="#000" opacity=".5" filter="url(#sh)"/>{inner}', d)
card("card_back", '''<rect x="44" y="8" width="168" height="240" rx="14" fill="url(#cb)" stroke="#1a0306" stroke-width="3"/>
<rect x="54" y="18" width="148" height="220" rx="9" fill="none" stroke="#f2c14e" stroke-width="3"/>
<rect x="60" y="24" width="136" height="208" rx="6" fill="url(#lat)"/>
<circle cx="128" cy="128" r="34" fill="#4a0a14" stroke="#f2c14e" stroke-width="4"/>
<path d="M128 104 L138 128 L128 152 L118 128Z" fill="#f2c14e"/>''')
heart = "M128 176 C92 148 74 126 74 104 C74 86 88 74 104 74 C116 74 124 82 128 92 C132 82 140 74 152 74 C168 74 182 86 182 104 C182 126 164 148 128 176Z"
spade = "M128 66 C152 96 182 112 182 136 C182 154 168 164 154 164 C144 164 136 158 132 150 C134 166 140 176 150 184 H106 C116 176 122 166 124 150 C120 158 112 164 102 164 C88 164 74 154 74 136 C74 112 104 96 128 66Z"
def front(path, col):
    small = f'<g transform="translate(66 30) scale(.22) translate(-128 -66)"><path d="{path}" fill="{col}"/></g><g transform="translate(190 226) rotate(180) scale(.22) translate(-128 -66)"><path d="{path}" fill="{col}"/></g>'
    return f'<rect x="44" y="8" width="168" height="240" rx="14" fill="url(#cf)" stroke="#5a3708" stroke-width="3"/><rect x="52" y="16" width="152" height="224" rx="9" fill="none" stroke="#c8932e" stroke-width="2"/><g transform="translate(0 4)"><path d="{path}" fill="{col}"/></g>{small}'
card("card_front_red", front(heart, "#c0283a"))
card("card_front_black", front(spade, "#1c1a1a"))

# ------------------------------------------------------------------ sprite sheets
def coin_frame(cx, cy, k, r=26):
    ang = k * math.pi / 8
    rx = max(3.0, r * abs(math.cos(ang)))
    em = f'<circle cx="{cx}" cy="{cy}" r="{rx*.55:.1f}" ry="{r*.55}" fill="none"/>'
    face = f'<ellipse cx="{cx}" cy="{cy}" rx="{rx*.6:.1f}" ry="{r*.6:.1f}" fill="none" stroke="#8f5c10" stroke-width="2.5"/>' if rx > 9 else ""
    hi = f'<ellipse cx="{cx - rx*.35:.1f}" cy="{cy - r*.35:.1f}" rx="{max(1.5, rx*.18):.1f}" ry="{r*.18:.1f}" fill="#fff" opacity=".8"/>' if rx > 9 else ""
    return f'<ellipse cx="{cx + 2}" cy="{cy}" rx="{rx + 2:.1f}" ry="{r}" fill="#7a4a08"/><ellipse cx="{cx}" cy="{cy}" rx="{rx:.1f}" ry="{r}" fill="#f2c14e" stroke="#7a4a08" stroke-width="2"/>{face}{hi}'
add("sprite_coin_spin_8x1", 512, 64, "".join(coin_frame(32 + 64 * k, 32, k) for k in range(8)))

def sparkle(cx, cy, s, rot, op):
    p = f"M0 -26 L5 -5 L26 0 L5 5 L0 26 L-5 5 L-26 0 L-5 -5Z"
    return f'<g transform="translate({cx} {cy}) rotate({rot}) scale({s})" opacity="{op}"><circle r="14" fill="url(#sg)"/><path d="{p}" fill="#fff"/><path d="{p}" fill="#ffe08a" transform="rotate(45) scale(.55)"/></g>'
sc = [.2, .5, .9, 1, .85, .65, .4, .15]; so = [1, 1, 1, 1, .9, .7, .45, .2]
add("sprite_sparkle_8x1", 512, 64, "".join(sparkle(32 + 64 * k, 32, sc[k], k * 12, so[k]) for k in range(8)),
    rad("sg", [(0, "#fff3c4", .9), (1, "#fff3c4", 0)]))

def book_frame(ox, oy, k):
    f = [0, .18, .4, .62, .85, 1, 1, 1][k]
    light = [0, 0, .15, .35, .55, .75, .9, 1][k]
    g = f'<g transform="translate({ox} {oy})">'
    if light > 0:
        g += f'<circle cx="128" cy="118" r="{70 + 50 * light:.0f}" fill="url(#bl)" opacity="{light:.2f}"/>'
        if light >= .55:
            for a in range(-70, 71, 20):
                g += f'<path d="M128 128 L{128 + 140 * math.sin(math.radians(a - 5)):.1f} {128 - 140 * math.cos(math.radians(a - 5)):.1f} L{128 + 140 * math.sin(math.radians(a + 5)):.1f} {128 - 140 * math.cos(math.radians(a + 5)):.1f}Z" fill="#e6d4ff" opacity="{(light - .45):.2f}"/>'
    # back cover + right page block
    g += '<rect x="44" y="64" width="172" height="144" rx="8" fill="#2c0f4a" stroke="#1a0630" stroke-width="3"/>'
    g += '<path d="M128 70 L208 66 L208 200 L128 204Z" fill="#efe2bf" stroke="#5a4a2a" stroke-width="2"/><path d="M140 90 h56 M140 104 h56 M140 118 h50 M140 132 h56 M140 146 h44" stroke="#c9b68a" stroke-width="2.5"/>'
    c = math.cos(math.pi * f)
    lift = 18 * math.sin(math.pi * f)
    if c >= 0:
        xe = 128 + 84 * c
        g += f'<path d="M128 66 L{xe:.1f} {62 - lift:.1f} L{xe:.1f} {212 + lift:.1f} L128 208Z" fill="url(#cv)" stroke="#1a0630" stroke-width="3"/>'
        if c > .4:
            g += f'<circle cx="{128 + 42 * c:.1f}" cy="137" r="{20 * c:.1f}" fill="none" stroke="#6ff0ff" stroke-width="3"/>'
    else:
        xe = 128 + 84 * c
        g += f'<path d="M128 66 L{xe:.1f} {62 - lift:.1f} L{xe:.1f} {212 + lift:.1f} L128 208Z" fill="#3a1660" stroke="#1a0630" stroke-width="3"/>'
        g += f'<path d="M128 70 L{128 + 80 * c:.1f} {66 - lift * .9:.1f} L{128 + 80 * c:.1f} {200 + lift * .9:.1f} L128 204Z" fill="#efe2bf" stroke="#5a4a2a" stroke-width="2"/>'
        if f > .8:
            g += '<path d="M60 90 h56 M60 104 h56 M60 118 h50 M60 132 h56 M60 146 h44" stroke="#c9b68a" stroke-width="2.5"/>'
    g += '<path d="M128 66 V208" stroke="#1a0630" stroke-width="3"/>'
    if light >= .35:
        g += f'<ellipse cx="128" cy="120" rx="{60 * light:.0f}" ry="{30 * light:.0f}" fill="url(#bl2)"/>'
    return g + "</g>"
add("sprite_book_open_4x2", 1024, 512, "".join(book_frame((k % 4) * 256, (k // 4) * 256, k) for k in range(8)),
    rad("bl", [(0, "#e6d4ff", .9), (.5, "#9b5cff", .4), (1, "#7b3fe0", 0)]) + rad("bl2", [(0, "#ffffff", .95), (1, "#c6fbff", 0)]) + lin("cv", [(0, "#6a2fa0", 1), (1, "#2c0f4a", 1)], 1, 1))

# ------------------------------------------------------------------ render
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        pg = await b.new_page(device_scale_factor=1)
        for name, (w, h, svg) in ASSETS.items():
            await pg.set_viewport_size({"width": w, "height": h})
            await pg.set_content(f'<html><body style="margin:0;background:transparent">{svg}</body></html>')
            await pg.screenshot(path=f"{OUT}/{name}.png", omit_background=True, clip={"x": 0, "y": 0, "width": w, "height": h})
        await b.close()
    print(len(ASSETS), "assets")

asyncio.run(main())
