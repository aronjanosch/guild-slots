local _, ns = ...

-- German strings, only for German clients. Missing keys fall back to English.
if type(GetLocale) ~= "function" or GetLocale() ~= "deDE" then
	return
end

local L = ns.L

L.THOUSANDS = "."
L.TITLE = "Gildenslots"
L.SOLO = "Solo"
L.BALANCE = "Guthaben"
L.STAKE = "Einsatz"
L.SPIN = "DREHEN"
L.STOP = "STOPP"
L.WIN = "Gewinn"
L.TAKE = "NEHMEN %s"
L.GAMBLE = "RISIKO %s"
L.REFILL = "Auffüllen"
L.PAYTABLE = "Gewinnplan"
L.PAIR = "Paar"
L.TRIPLE = "Drilling"
L.PAIR_RULE = "Paar = Walze 1 und 2 auf der mittleren Linie"
L.GAMBLE_RULE = "Risiko: doppelt oder nichts, 50 %%, bis zu %d Mal"
L.RTP = "Auszahlungsquote: %.1f %%"
L.FOOTER = "Nur Spielgeld. Kein Auszahlungsanspruch. Die Bank gewinnt immer."
L.NO_FUNDS = "Guthaben reicht nicht. Auffüllen, um weiterzuspielen."
L.BIG_WIN = "GROSSER GEWINN"
L.GAMBLE_WON = "Verdoppelt!"
L.GAMBLE_LOST = "Verloren"
L.TAKEN = "Genommen"
L.REFILLED = "Guthaben aufgefüllt"
L.SOUND_ON = "Ton an"
L.SOUND_OFF = "Ton aus"
L.SPACE_ON = "Leertaste dreht, solange die Maus über dem Fenster ist"
L.SPACE_OFF = "Leertaste aus"
L.HELP = "/gslots oder /gs: öffnen/schließen. /gs sound, /gs space, /gs reset (Fensterposition)"
L.RESET_DONE = "Fensterposition zurückgesetzt"
