# Gildenslots v2 – Maße, Farben, Schriften, 9-Slices

Alle Werte in Bildschirmpixeln bei UI-Skalierung 1. Zustandsbilder in `zustaende/` sind in doppelter Auflösung gerendert (1200 × 1344), das Fenster selbst ist **600 × 672**.

## Fenster-Layout (x, y, Breite × Höhe)

| Element | Position | Größe |
|---|---|---|
| Fenster (frei verschiebbar) | – | 600 × 672 |
| Innenrand (Rahmenband) | – | 22 rundum |
| Kopfzeile: Titel | 30, 22 | 260 × 44 |
| Umschalter Solo / Gilde | 318, 29 / 398, 29 | je 78 × 32 |
| Ton, Schließen (Icon-Knopf) | 492, 29 / 534, 29 | je 34 × 32, Icon 17 |
| Trennlinie | 22, 70 | 556 × 12 |
| Anzeigen Guthaben / Letzter Gewinn / Gesamteinsatz | 22 / 210 / 398, 86 | je 180 × 50 |
| Walzenrahmen | 48, 142 | 504 × 312 |
| Walzenfeld (5 × 3) | 60, 154 | 480 × 288, Zelle 96 × 96 |
| Linienmarken links / rechts | Mitte x 33 / 567 | 22 × 22 (leuchtend 28 × 28) |
| Hinweiszeile | 22, 460 | 556 × 24 |
| Einsatz-Beschriftung | 22, 488 | – |
| Einsatzstufen 10 / 50 / 100 | 22 / 124 / 226, 506 | je 96 × 46 |
| Nehmen / Risiko (ersetzen die Einsatzstufen) | 22 / 176, 494 | je 148 × 58 |
| Drehen / Stopp / Weiter | 334, 488 | 244 × 64 |
| Gewinnplan / Officer | 22 / 184, 562 | je 156 × 38 |
| Fußzeile | 22, 616 | 556 × 16 |

Abstände: 8 px zwischen Elementen derselben Reihe, 6–10 px zwischen Reihen, 12 px Innenabstand in Anzeigen.

Officer-Ansicht: **448 × 728**, gleiche Rahmen, Zeilenhöhe Listen 27 (Spieler) / 30 (Käufe), Formularzeilen 36 hoch im Abstand von 42.

## Gewinnlinien (Reihe 0 = oben, je Walze 1–5)

| Linie | Reihen | Farbe |
|---|---|---|
| 1 | 1 1 1 1 1 | `#ffd23f` |
| 2 | 0 0 0 0 0 | `#ff6b6b` |
| 3 | 2 2 2 2 2 | `#4dabf7` |
| 4 | 0 1 2 1 0 | `#69db7c` |
| 5 | 2 1 0 1 2 | `#da77f2` |
| 6 | 1 0 0 0 1 | `#ffa94d` |
| 7 | 1 2 2 2 1 | `#38d9a9` |
| 8 | 0 0 1 2 2 | `#f783ac` |
| 9 | 2 2 1 0 0 | `#a9e34b` |
| 10 | 1 2 1 0 1 | `#74c0fc` |

Linie = `CreateLine` mit `line_glow.png`, Dicke 16, `SetVertexColor` in Linienfarbe, Ebene über den Symbolen. Marken: `linemarker_normal.png`; bei Gewinn `linemarker_lit.png` in Linienfarbe eingefärbt, Ziffer dunkel `#1a0f05`.

## Farben

| Rolle | Hex |
|---|---|
| Fenstergrund (Holz-Kachel, Grundton) | `#2c1b0e` |
| Anzeigen, Felder | `#0d0805` |
| Rahmen dunkel | `#6b4a1f` |
| Gold | `#f2c14e` |
| Gold hell (Gewinn) | `#ffd76a` |
| Gold dunkel | `#8f5c10` |
| Text Pergament | `#f3e2b8` |
| Zahlen | `#fff1cc` |
| Beschriftung gedämpft | `#c9ad7c` |
| Fußzeile | `#a88e62` |
| Leerwert („–“) | `#7d6a4c` |
| Risiko / Rot | `#c23345` → `#5e0f1a` |
| Verlust-Hinweis | `#ff8a9a` |
| Freispiel Akzent | `#7b3fe0`, Hinweis `#c6fbff` |
| Abdunkeln Nicht-Gewinner | `#000000` mit Alpha 0,6 (Farbfläche) |
| Status Bestätigt / Offen / Abgelehnt | `#2f9e44` / `#e8a33a` / `#c0283a` |

## Schriften

Empfehlung: die mitgelieferten OFL-Schriften in `fonts/` (Lizenz in `fonts/OFL.txt`, enthalten ä ö ü ß). Ersatz im Spiel: Cinzel Decorative → Morpheus, Marcellus → Friz Quadrata, Archivo Narrow → Arial Narrow.

| Verwendung | Schrift | Größe | Farbe |
|---|---|---|---|
| Fenstertitel | Cinzel Decorative Black | 28 | `#f2c14e`, Schatten 2/−2 `#1a0d05` |
| Banner („Großer Gewinn“, „10 Freispiele“) | Cinzel Decorative Black | 34 | `#ffe08a` / `#ffffff` |
| Drehen / Stopp / Weiter | Cinzel Decorative Black | 28 | `#2a1606`, ohne Schatten |
| Überschriften in Overlays | Cinzel Decorative Black | 20–22 | `#f2c14e` |
| Anzeige-Beschriftung | Marcellus | 11, Großbuchstaben | `#c9ad7c` |
| Hinweiszeile | Marcellus | 15 | je nach Ton |
| Knopftext klein | Marcellus | 14 | `#ffd76a` |
| Zahlen in Anzeigen | Archivo Narrow Bold | 24 | `#fff1cc` |
| Einsatzstufen | Archivo Narrow Bold | 20 | `#fff1cc` |
| Großer Gewinnbetrag | Archivo Narrow Bold | 72 | `#ffffff`, Schatten 3/−3 `#5a2a00` |
| Fußzeile | Marcellus | 11 | `#a88e62` |

Alle Texte mit `SetShadowOffset(1, -1)`, Schattenfarbe schwarz, außer auf Goldknöpfen.

## 9-Slices (Ränder in Texturpixeln → angezeigt)

Knöpfe sind in doppelter Auflösung gezeichnet und werden mit halber Eckgröße angezeigt. Umsetzung: 9 Texturen mit `SetTexCoord` (läuft in jedem Client) oder `SetTextureSliceMargins`.

| Datei | Textur | Rand | angezeigt |
|---|---|---|---|
| `frame_window(_freespin).png` | 256 × 256 | 48 | 48 |
| `frame_reels(_freespin).png` | 256 × 256 | 32 | 24 |
| `panel_inset.png`, `panel_overlay.png` | 64 × 64 | 16 | 12 |
| `input_field_{normal,focus,disabled}.png` | 64 × 64 | 16 | 10 |
| `button_primary_*.png` | 256 × 128 | 40 | 20 |
| `button_secondary_*`, `button_danger_*`, `button_toggle_*` | 128 × 64 | 20 | 10 |
| `button_icon_*.png` | 64 × 64 | 16 | 8 |
| `glow_cell.png` | 128 × 128 | 32 | 22 |
| `divider.png` | 256 × 16 | links/rechts 32 | 32 (3-Slice) |
| `badge_status.png` | 64 × 32 | 15 | 11 |
| `scroll_thumb.png` | 32 × 64 | oben/unten 12 | 12 |

Knopfzustände: `_normal`, `_hover`, `_pressed` (Inhalt 2 px tiefer), `_disabled` (Text Alpha 0,45). `button_toggle` hat zusätzlich `_selected`.

Gekachelt (`SetHorizTile`/`SetVertTile`): `bg_window_wood.png`, `bg_window_freespin.png` (256 × 256, nahtlos).
Gestreckt: `bg_reels(_freespin).png` (512 × 256 → 480 × 288, getrennt vom Rahmen), `reel_shade.png` je Walze (64 × 256 → 96 × 288).

## Symbole

10 × `symbol_<name>.png` + 10 × `symbol_<name>_win.png`, je 256 × 256 mit transparentem Rand, angezeigt in 96 × 96.
Niedrig (ohne Medaillon): copper, silver, gold, potion, sword. Hoch (Medaillon mit Goldrand): kraken, dragon, crown, legendary (orange Aura). Sonder: tome (violetter Strahlenkranz).

## Bildfolgen (Raster, Bildreihenfolge zeilenweise)

| Datei | Raster | Bild | Verwendung |
|---|---|---|---|
| `sprite_coin_spin_8x1.png` | 8 × 1 | 64 × 64 | Münzregen, 12 Bilder/s |
| `sprite_sparkle_8x1.png` | 8 × 1 | 64 × 64 | Funken bei Gewinn, einmal abspielen |
| `sprite_book_open_4x2.png` | 4 × 2 | 256 × 256 | Foliant schlägt auf, 0,8 s, Bild 8 halten |

## Effekt-Texturen (Blend-Modus ADD, per `SetVertexColor` einfärbbar)

`glow_soft.png` 128², `glow_cell.png` 128², `rays.png` 512² (Rotation 360° in 9 s), `shine.png` 64 × 256 (Translation über den Banner, abgeschnitten mit `SetClipsChildren`), `expand_column.png` 128 × 512 (Hintergrund einer ausgebreiteten Walze), `line_glow.png` 128 × 32.

Banner ohne Text: `banner_bigwin.png`, `banner_freespins.png` (512 × 128, fest, Skalierung 0,2 → 1,12 → 1 beim Erscheinen).
Karten: `card_back.png`, `card_front_red.png`, `card_front_black.png` (256 × 256, Karte 168 × 240 mittig). Aufdecken per Scale-X 1 → 0 → 1.

## Offene Punkte

- Die Auszahlungswerte im Gewinnplan sind Beispielwerte und noch nicht auf eine Auszahlungsquote gerechnet.
- Das Murloc-Symbol ist durch ein eigenes Motiv (Tiefenkrake) ersetzt. Im Spiel lässt sich dafür das Client-Icon `Interface\Icons\INV_Misc_Head_Murloc_01` verwenden.
- Ob PNG im Ziel-Client geladen wird, im Spiel prüfen. Falls nicht, mit gleichem Namen als TGA exportieren (Größen bleiben gleich).
