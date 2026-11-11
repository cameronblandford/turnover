std = "lua51"
max_line_length = 120
exclude_files = { "tests/**" }

globals = { "TurnoverDB", "SLASH_TURNOVER1", "SLASH_TURNOVER2", "SlashCmdList" }

read_globals = {
  "AuctionFrame", "AuctionHouseFrame", "C_AuctionHouse", "C_Item", "CanSendAuctionQuery",
  "CreateFrame", "Enum", "GameTooltip", "GetAuctionItemInfo", "GetAuctionItemTimeLeft",
  "GetCoinTextureString", "GetItemInfo", "GetNumAuctionItems", "GetRealmName", "GetTime",
  "ItemRefTooltip", "NUM_AUCTION_ITEMS_PER_PAGE", "QueryAuctionItems", "TooltipDataProcessor",
  "UnitFactionGroup", "hooksecurefunc", "time", "unpack", "wipe",
}
