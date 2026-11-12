local t, ns = ...
local Coins = ns.Coins

t.test("coins: tokens to copper rounds down", function()
	t.eq(Coins.tokensToCopper(1000, 1000), 10000, "1000 tokens at 1000/gold is 1 gold")
	t.eq(Coins.tokensToCopper(1250, 1000), 12500, "1g 25s")
	t.eq(Coins.tokensToCopper(1, 3), 3333, "a third of a gold, rounded down")
	t.eq(Coins.tokensToCopper(2, 3), 6666, "two thirds, rounded down")
	t.eq(Coins.tokensToCopper(0, 1000), 0, "zero")
	t.eq(Coins.tokensToCopper(1, 1000000), 0, "below one copper")
	t.eq(Coins.tokensToCopper(10, nil), nil, "no rate")
	t.eq(Coins.tokensToCopper(10, 0), nil, "bad rate")
end)

t.test("coins: copper to tokens rounds down", function()
	t.eq(Coins.copperToTokens(10000, 1000), 1000, "one gold")
	t.eq(Coins.copperToTokens(125000, 1000), 12500, "12g 50s")
	t.eq(Coins.copperToTokens(9, 1000), 0, "9 copper buy nothing")
	t.eq(Coins.copperToTokens(19, 1000), 1, "19 copper buy one token")
	t.eq(Coins.copperToTokens(3333, 3), 0, "just below one token")
	t.eq(Coins.copperToTokens(3334, 3), 1, "one token")
	t.eq(Coins.copperToTokens(10000, 1000000000), 1000000000, "big rate")
	t.eq(Coins.copperToTokens(99999999999, 7), 69999999, "big amount stays exact")
	t.eq(Coins.copperToTokens(100, nil), nil, "no rate")
end)

t.test("coins: gold text parses whole and decimal gold", function()
	t.eq(Coins.parseGold("12"), 120000, "12 gold")
	t.eq(Coins.parseGold("12.5"), 125000, "12.5 gold")
	t.eq(Coins.parseGold("12,5"), 125000, "decimal comma")
	t.eq(Coins.parseGold(" 0.0001 "), 1, "one copper")
	t.eq(Coins.parseGold("0.00019"), 1, "below a copper is dropped")
	t.eq(Coins.parseGold(".5"), 5000, "leading dot")
	t.eq(Coins.parseGold("3."), 30000, "trailing dot")
	t.eq(Coins.parseGold(""), nil, "empty")
	t.eq(Coins.parseGold("."), nil, "only a dot")
	t.eq(Coins.parseGold("1.2.3"), nil, "two dots")
	t.eq(Coins.parseGold("-1"), nil, "negative")
	t.eq(Coins.parseGold("abc"), nil, "letters")
end)

t.test("coins: gold text to tokens", function()
	t.eq(Coins.goldToTokens("12.5", 1000), 12500, "12.5 gold at 1000/gold")
	t.eq(Coins.goldToTokens("0.0001", 1000), 0, "one copper buys nothing at 1000/gold")
	t.eq(Coins.goldToTokens("1", 3), 3, "one gold at 3/gold")
	t.eq(Coins.goldToTokens("x", 1000), nil, "bad text")
	t.eq(Coins.goldToTokens("1", nil), nil, "no rate")
end)

t.test("coins: coin text without the client's coin icons", function()
	t.eq(Coins.text(125000), "12g 50s", "gold and silver")
	t.eq(Coins.text(10000), "1g", "only gold")
	t.eq(Coins.text(10203), "1g 2s 3c", "all three")
	t.eq(Coins.text(5), "5c", "only copper")
	t.eq(Coins.text(0), "0c", "zero")
	t.eq(Coins.tokensText(12500, 1000), "12g 50s", "tokens to text")
	t.eq(Coins.tokensText(1, 3), "33s 33c", "rounded down")
	t.eq(Coins.tokensText(5, nil), nil, "no rate, no text")
end)

t.test("coins: the client's coin text is used when it exists", function()
	local seen
	GetCoinTextureString = function(copper)
		seen = copper
		return "C" .. copper
	end
	t.eq(Coins.text(125000), "C125000", "client function")
	t.eq(seen, 125000, "with the copper amount")
	GetCoinTextureString = function() error("boom") end
	t.eq(Coins.text(10000), "1g", "an error falls back")
	GetCoinTextureString = "not a function"
	C_CurrencyInfo = { GetCoinTextureString = function(copper) return "K" .. copper end }
	t.eq(Coins.text(7), "K7", "C_CurrencyInfo variant")
	GetCoinTextureString, C_CurrencyInfo = nil, nil
	t.eq(Coins.text(7), "7c", "back to plain text")
end)
