-- ╔══════════════════════════════════════════════════════════╗
--  HazeHUB V16 – Intelligent Auto-Farmer
--  NEU: ScanAllRewards() – Reward-Datenbank pro Chapter
--  NEU: HazeHUB_RewardDB.json – persistenter Cache
--  NEU: Auto-Farm Queue – Ziel-Items mit bester Droprate
--  NEU: Lobby-Rückkehr via PlayerGui-Button-Click
--  NEU: Lobby-Erkennung → automatischer Queue-Fortschritt
--  NEU: 5s Timeout pro Chapter beim Scan
--  NEU: Unload stoppt alle Loops/Scans
--  FIX: 2-stufiger Chapter-Scan (Welt-Ordner → Buttons)
--  FIX: Auto-Retry task.wait(1) · Mobile Button links-mitte
-- ╚══════════════════════════════════════════════════════════╝

local HttpService       = game:GetService("HttpService")
local UserInputService  = game:GetService("UserInputService")
local VirtualUser       = game:GetService("VirtualUser")
local GuiService        = game:GetService("GuiService")
local Player            = game:GetService("Players").LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

-- ============================================================
--  GUI PARENT
-- ============================================================
local guiParent = Player.PlayerGui
pcall(function()
    local cg = game:GetService("CoreGui")
    local tf = Instance.new("Frame", cg); tf:Destroy()
    guiParent = cg
end)

-- ============================================================
--  GLOBAL STOP FLAG (Unload)
-- ============================================================
local RUNNING = true   -- auf false setzen → alle Loops stoppen

-- ============================================================
--  PATHS & FILES
-- ============================================================
local folderName   = "HazeHUB"
local saveFile     = folderName .. "/HazeHUB_AutoSave.json"
local rewardDBFile = folderName .. "/HazeHUB_RewardDB.json"

-- ============================================================
--  CONFIG & RUNTIME DATA
-- ============================================================
local Config = {
    WebhookURL = "",
    UISize     = "PC",
    ToggleKey  = "F4",
    AutoRetry  = false,
    SavedGoals = {},
    SavedQueue = {},   -- Auto-Farm Queue
}

local SessionTotals    = {}
local InfoTotals       = {}
local roundCount       = 0
local sessionStart     = os.time()
local Goals            = {}
local goalsNotifiedSet = {}

local INFO_ITEMS = { Exp=true, Gems=true, Gold=true }
local RARE_ITEMS = { ["Legendary Stone"]=true, ["Mythic Egg"]=true }

-- ============================================================
--  REWARD DATABASE
-- ============================================================
-- RewardDB[chapterId] = {
--   world   = "JJK",
--   mode    = "Story"|"Ranger"|"Calamity",
--   items   = { [itemName] = { dropRate=N, dropAmount=N } }
-- }
local RewardDB = {}

-- Auto-Farm Queue: { {item=str, amount=num, done=bool}, ... }
local FarmQueue  = {}
local farmActive = false   -- läuft gerade ein Farm-Zyklus?
local farmThread = nil     -- coroutine/task-Referenz

-- ============================================================
--  WORLD DATA (Scan-Ergebnis)
-- ============================================================
local WorldData = {}   -- { [worldId] = { story={chapIds}, ranger={stageIds} } }
local WorldIds  = {}
local scanDone  = false

-- ============================================================
--  VERBINDUNGS-TRACKING
-- ============================================================
local Connections = {}
local function Track(c) table.insert(Connections,c); return c end
local function DisconnectAll()
    RUNNING = false
    for _,c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    Connections = {}
    if childAddedConn then pcall(function() childAddedConn:Disconnect() end) end
end
local childAddedConn = nil

-- ============================================================
--  SAVE / LOAD
-- ============================================================
local function SaveConfig()
    Config.SavedGoals = {}
    for _,g in ipairs(Goals) do table.insert(Config.SavedGoals,{item=g.item,amount=g.amount}) end
    Config.SavedQueue = {}
    for _,q in ipairs(FarmQueue) do table.insert(Config.SavedQueue,{item=q.item,amount=q.amount,done=q.done}) end
    if writefile then pcall(function() writefile(saveFile,HttpService:JSONEncode(Config)) end) end
end

local function LoadConfig()
    if not (isfile and isfile(saveFile)) then return end
    local ok,data = pcall(function() return HttpService:JSONDecode(readfile(saveFile)) end)
    if not ok or not data then return end
    if data.WebhookURL~=nil then Config.WebhookURL=data.WebhookURL end
    if data.UISize    ~=nil then Config.UISize    =data.UISize     end
    if data.ToggleKey ~=nil then Config.ToggleKey =data.ToggleKey  end
    if data.AutoRetry ~=nil then Config.AutoRetry =data.AutoRetry  end
    if data.SavedGoals and type(data.SavedGoals)=="table" then
        for _,g in ipairs(data.SavedGoals) do
            if g.item and tonumber(g.amount) then
                table.insert(Goals,{item=g.item,amount=tonumber(g.amount),reached=false})
            end
        end
    end
    if data.SavedQueue and type(data.SavedQueue)=="table" then
        for _,q in ipairs(data.SavedQueue) do
            if q.item and tonumber(q.amount) then
                table.insert(FarmQueue,{item=q.item,amount=tonumber(q.amount),done=q.done==true})
            end
        end
    end
end

local function SaveRewardDB()
    if writefile then pcall(function() writefile(rewardDBFile,HttpService:JSONEncode(RewardDB)) end) end
end

local function LoadRewardDB()
    if not (isfile and isfile(rewardDBFile)) then return false end
    local ok,data = pcall(function() return HttpService:JSONDecode(readfile(rewardDBFile)) end)
    if not ok or not data then return false end
    RewardDB = data
    return true
end

-- ============================================================
--  REMOTES
-- ============================================================
local Remote = nil
pcall(function()
    Remote = ReplicatedStorage:WaitForChild("Remote",10):WaitForChild("Client",10)
        :WaitForChild("UI",10):WaitForChild("GameEndedUI",10)
end)
local VoteRetryRemote = nil
pcall(function()
    VoteRetryRemote = ReplicatedStorage:WaitForChild("Remote",10):WaitForChild("Server",10)
        :WaitForChild("OnGame",10):WaitForChild("Voting",10):WaitForChild("VoteRetry",10)
end)
local PlayRoomRemote = nil
pcall(function()
    PlayRoomRemote = ReplicatedStorage:WaitForChild("Remote",10):WaitForChild("Server",10)
        :WaitForChild("PlayRoom",10):WaitForChild("Event",10)
end)

if makefolder then pcall(function() makefolder(folderName) end) end

local function PR(...)
    if PlayRoomRemote then pcall(PlayRoomRemote.FireServer, PlayRoomRemote, ...) end
end

local function FireVoteRetry()
    task.spawn(function()
        task.wait(1)
        pcall(function()
            if VoteRetryRemote then VoteRetryRemote:FireServer()
            else ReplicatedStorage.Remote.Server.OnGame.Voting.VoteRetry:FireServer() end
        end)
    end)
end

local function FireChangeDifficulty(diff)
    PR("Change-Difficulty",{Difficulty=diff})
end

-- Exakte Abfolge: Create→(0.3s)→Change-World/Mode→Change-Chapter→Submit→(0.5s)→Start
local function FireCreateAndStart(worldId, mode, chapterId)
    task.spawn(function()
        pcall(function()
            PR("Create"); task.wait(0.3)
            if mode=="Story"    then PR("Change-World",{World=worldId})
            elseif mode=="Ranger"   then PR("Change-Mode",{KeepWorld=worldId,Mode="Ranger Stage"})
            elseif mode=="Calamity" then PR("Change-Mode",{Mode="Calamity"}) end
            PR("Change-Chapter",{Chapter=chapterId})
            PR("Submit"); task.wait(0.5)
            PR("Start")
        end)
    end)
end

-- ============================================================
--  LOBBY-RÜCKKEHR
-- ============================================================
local function ClickBackToLobby()
    pcall(function()
        local btn = Player.PlayerGui
            :WaitForChild("Settings",3):WaitForChild("Main",3)
            :WaitForChild("Base",3):WaitForChild("Space",3)
            :WaitForChild("ScrollingFrame",3):WaitForChild("Back To Lobby",3)
        if btn then btn.MouseButton1Click:Fire() end
    end)
end

-- Prüft ob Spieler in Lobby (PlayRoom-GUI nicht sichtbar / existiert nicht)
local function IsInLobby()
    local playRoom = Player.PlayerGui:FindFirstChild("PlayRoom")
    if not playRoom then return true end
    -- PlayRoom existiert, aber vielleicht Enabled=false
    if not playRoom.Enabled then return true end
    return false
end

-- ============================================================
--  INVENTAR-CHECK (Live)
-- ============================================================
local function GetInventoryAmount(itemName)
    local amount = 0
    pcall(function()
        local itemsFolder = ReplicatedStorage
            :WaitForChild("Player_Data",3)
            :WaitForChild(Player.Name,3)
            :WaitForChild("Items",3)
        local item = itemsFolder:FindFirstChild(itemName)
        if item then
            local vc = item:FindFirstChild("Value") or item:FindFirstChild("Amount")
            if vc then amount = tonumber(vc.Value) or 0
            elseif item:IsA("IntValue") or item:IsA("NumberValue") then amount = tonumber(item.Value) or 0 end
        end
    end)
    return amount
end

-- ============================================================
--  SCAN: WORLD DATA (zweistufig: Chapter→Welt→Buttons)
-- ============================================================
local chapterFolderRef = nil

local function GetChapterFolder()
    if chapterFolderRef then return chapterFolderRef end
    local f = nil
    pcall(function() f = Player.PlayerGui.PlayRoom.Main.GameStage.Main.Base.Chapter end)
    if not f then
        pcall(function()
            f = Player:WaitForChild("PlayerGui",10)
                :WaitForChild("PlayRoom",10):WaitForChild("Main",10)
                :WaitForChild("GameStage",10):WaitForChild("Main",10)
                :WaitForChild("Base",10):WaitForChild("Chapter",10)
        end)
    end
    chapterFolderRef = f
    return f
end

local function ScanChapterFolder(chapterFolder)
    WorldData = {}
    for _, worldFolder in ipairs(chapterFolder:GetChildren()) do
        local worldId   = worldFolder.Name
        local storyBtns, rangerBtns = {}, {}
        for _, btn in ipairs(worldFolder:GetChildren()) do
            local n = btn.Name
            if n:find("_Chapter") and not worldId:lower():find("calamity") then
                table.insert(storyBtns, n)
            elseif n:find("_RangerStage") then
                table.insert(rangerBtns, n)
            elseif worldId:lower():find("calamity") and n:find("_Chapter") then
                table.insert(storyBtns, n)
            end
        end
        local sortByNum = function(a,b)
            return (tonumber(a:match("(%d+)$")) or 0) < (tonumber(b:match("(%d+)$")) or 0)
        end
        table.sort(storyBtns, sortByNum); table.sort(rangerBtns, sortByNum)
        if #storyBtns>0 or #rangerBtns>0 then
            WorldData[worldId] = {story=storyBtns, ranger=rangerBtns}
        end
    end
    local ids={}; for wid in pairs(WorldData) do table.insert(ids,wid) end
    table.sort(ids,function(a,b) return a:lower()<b:lower() end)
    WorldIds = ids; scanDone = true
end

local function ApplyFallback()
    WorldData = {
        JJK      ={story={"JJK_Chapter1","JJK_Chapter2","JJK_Chapter3","JJK_Chapter4","JJK_Chapter5"},ranger={"JJK_RangerStage1","JJK_RangerStage2","JJK_RangerStage3","JJK_RangerStage4"}},
        OnePiece ={story={"OnePiece_Chapter1","OnePiece_Chapter2","OnePiece_Chapter3","OnePiece_Chapter4","OnePiece_Chapter5"},ranger={"OnePiece_RangerStage1","OnePiece_RangerStage2","OnePiece_RangerStage3"}},
        Naruto   ={story={"Naruto_Chapter1","Naruto_Chapter2","Naruto_Chapter3","Naruto_Chapter4","Naruto_Chapter5"},ranger={"Naruto_RangerStage1","Naruto_RangerStage2","Naruto_RangerStage3"}},
        Namek    ={story={"Namek_Chapter1","Namek_Chapter2","Namek_Chapter3","Namek_Chapter4","Namek_Chapter5"},ranger={"Namek_RangerStage1","Namek_RangerStage2","Namek_RangerStage3"}},
        TokyoGhoul={story={"TokyoGhoul_Chapter1","TokyoGhoul_Chapter2","TokyoGhoul_Chapter3","TokyoGhoul_Chapter4","TokyoGhoul_Chapter5"},ranger={"TokyoGhoul_RangerStage1","TokyoGhoul_RangerStage2","TokyoGhoul_RangerStage3"}},
        SAO      ={story={"SAO_Chapter1","SAO_Chapter2","SAO_Chapter3","SAO_Chapter4","SAO_Chapter5"},ranger={"SAO_RangerStage1","SAO_RangerStage2","SAO_RangerStage3"}},
        Calamity ={story={"Calamity_Chapter1","Calamity_Chapter2"},ranger={}},
    }
    local ids={}; for wid in pairs(WorldData) do table.insert(ids,wid) end
    table.sort(ids,function(a,b) return a:lower()<b:lower() end)
    WorldIds=ids; scanDone=true
end

-- ============================================================
--  SCAN: REWARD DATABASE
-- ============================================================
-- Liest Rewards aus: ...Base.Rewards.ItemsList → Info (ItemNames, DropRate, DropAmount)
local scanStatusLbl  = nil   -- wird nach UI-Build gesetzt

local function ReadItemsListRewards(chapterId, worldId, mode)
    -- Wartet bis ItemsList vorhanden, max 5 Sekunden
    local itemsList = nil
    local deadline  = os.clock() + 5
    while os.clock() < deadline and RUNNING do
        pcall(function()
            itemsList = Player.PlayerGui
                .PlayRoom.Main.GameStage.Main.Base.Rewards.ItemsList
        end)
        if itemsList then break end
        task.wait(0.25)
    end
    if not itemsList then return nil end   -- Timeout

    local items = {}
    for _, infoFolder in ipairs(itemsList:GetChildren()) do
        pcall(function()
            local info     = infoFolder:FindFirstChild("Info")
            if not info then return end
            local nameVal  = info:FindFirstChild("ItemNames")
            local rateVal  = info:FindFirstChild("DropRate")
            local amtVal   = info:FindFirstChild("DropAmount")
            local itemName = nameVal and tostring(nameVal.Value) or infoFolder.Name
            local rate     = rateVal and tonumber(rateVal.Value) or 0
            local amount   = amtVal  and tonumber(amtVal.Value)  or 1
            if itemName and itemName~="" then
                items[itemName] = { dropRate=rate, dropAmount=amount }
            end
        end)
    end
    return items
end

-- Vollständiger Reward-Scan aller Welten/Chapter
-- Ergebnis: RewardDB[chapterId] = { world, mode, items }
local function ScanAllRewards(onProgress)
    if not scanDone then return end
    RewardDB = {}
    local totalChapters, scanned, skipped = 0, 0, 0

    -- Zählen
    for _,wid in ipairs(WorldIds) do
        local wData = WorldData[wid] or {}
        totalChapters = totalChapters + #(wData.story or {}) + #(wData.ranger or {})
    end

    for _, wid in ipairs(WorldIds) do
        if not RUNNING then break end
        local wData = WorldData[wid] or {}
        local allChapters = {}
        for _,cid in ipairs(wData.story  or {}) do table.insert(allChapters,{id=cid,mode="Story"}) end
        for _,cid in ipairs(wData.ranger or {}) do table.insert(allChapters,{id=cid,mode="Ranger"}) end

        for _, chap in ipairs(allChapters) do
            if not RUNNING then break end
            scanned = scanned + 1

            -- Status-Update
            if onProgress then
                pcall(function()
                    onProgress(string.format("⏳  %d/%d  –  %s",scanned,totalChapters,chap.id))
                end)
            end

            -- Raum wechseln um ItemsList zu laden
            pcall(function()
                if chap.mode=="Story" then
                    PR("Change-World",{World=wid})
                elseif chap.mode=="Ranger" then
                    PR("Change-Mode",{KeepWorld=wid,Mode="Ranger Stage"})
                elseif chap.mode=="Calamity" then
                    PR("Change-Mode",{Mode="Calamity"})
                end
                PR("Change-Chapter",{Chapter=chap.id})
            end)

            task.wait(1.5)   -- kurz warten damit ItemsList lädt

            local items = ReadItemsListRewards(chap.id, wid, chap.mode)
            if items and next(items) then
                RewardDB[chap.id] = {
                    world   = wid,
                    mode    = chap.mode,
                    items   = items,
                }
            else
                skipped = skipped + 1
                if onProgress then
                    pcall(function()
                        onProgress(string.format("⚠  Timeout: %s (übersprungen)",chap.id))
                    end)
                end
            end
        end
    end

    SaveRewardDB()
    if onProgress then
        pcall(function()
            onProgress(string.format("✅  Scan fertig: %d/%d Chapter · %d Timeouts",
                scanned-skipped, totalChapters, skipped))
        end)
    end
end

-- Beste Chapter-ID für ein Item suchen (höchste DropRate)
local function FindBestChapterForItem(itemName)
    local bestChapter, bestRate, bestWorld, bestMode = nil, -1, nil, nil
    for chapterId, data in pairs(RewardDB) do
        if data.items and data.items[itemName] then
            local rate = data.items[itemName].dropRate or 0
            if rate > bestRate then
                bestRate    = rate
                bestChapter = chapterId
                bestWorld   = data.world
                bestMode    = data.mode
            end
        end
    end
    return bestChapter, bestWorld, bestMode, bestRate
end

-- ============================================================
--  AUTO-FARM QUEUE ENGINE
-- ============================================================
local farmStatusLbl   = nil   -- wird nach UI-Build gesetzt
local UpdateFarmQueueUI       -- Vorwärtsdeklaration

local function GetCurrentQueueItem()
    for _,q in ipairs(FarmQueue) do
        if not q.done then return q end
    end
    return nil
end

local function FarmLoop()
    farmActive = true
    while RUNNING do
        local qItem = GetCurrentQueueItem()
        if not qItem then
            -- Queue leer
            farmActive = false
            pcall(function()
                if farmStatusLbl then farmStatusLbl.Text="✅  Queue fertig!";farmStatusLbl.TextColor3=Color3.fromRGB(0,220,120) end
            end)
            break
        end

        -- Bestes Chapter suchen
        local chapterId, worldId, mode, dropRate = FindBestChapterForItem(qItem.item)
        if not chapterId then
            -- Kein Eintrag in DB → fallback: erstes Chapter
            if #WorldIds>0 then
                local wid = WorldIds[1]
                local wData = WorldData[wid] or {}
                local chapList = wData.story or {}
                if #chapList>0 then
                    chapterId = chapList[1]; worldId=wid; mode="Story"; dropRate=0
                end
            end
        end

        if not chapterId then
            pcall(function()
                if farmStatusLbl then farmStatusLbl.Text="⚠  Kein Chapter für '"..qItem.item.."' gefunden" end
            end)
            task.wait(3)
            qItem.done = true   -- überspringen
            pcall(function() UpdateFarmQueueUI() end)
            continue
        end

        -- Status
        pcall(function()
            if farmStatusLbl then
                farmStatusLbl.Text=string.format("🚀  Farm: %s  →  %s  (Rate: %.1f%%)",
                    qItem.item, chapterId, dropRate)
                farmStatusLbl.TextColor3=Color3.fromRGB(0,200,255)
            end
        end)

        -- Raum erstellen und starten
        FireCreateAndStart(worldId, mode, chapterId)

        -- Warten bis Ziel erreicht (Inventar-Check alle 5s)
        local startInv = GetInventoryAmount(qItem.item)
        local deadline = os.time() + 600   -- max 10 Minuten pro Item
        local goalMet  = false

        while RUNNING and os.time()<deadline do
            task.wait(5)
            local current = GetInventoryAmount(qItem.item)
            pcall(function()
                if farmStatusLbl then
                    farmStatusLbl.Text=string.format("📊  %s:  %d / %d  (%.0f%%)",
                        qItem.item, current, qItem.amount,
                        math.min(100,(current/math.max(1,qItem.amount))*100))
                end
            end)
            -- Ziel-Logik im Session-Tab aktualisieren
            pcall(function() UpdateGoalsUI() end)

            if current >= qItem.amount then
                goalMet = true; break
            end
        end

        if goalMet then
            qItem.done = true
            SaveConfig()
            pcall(function() UpdateFarmQueueUI() end)

            -- Webhook senden
            task.spawn(function()
                local cur = GetInventoryAmount(qItem.item)
                SendWebhook({}, qItem.item, cur)
            end)

            -- Zurück zur Lobby
            pcall(function()
                if farmStatusLbl then farmStatusLbl.Text="🏠  Rückkehr zur Lobby..." end
            end)
            task.wait(2)
            ClickBackToLobby()

            -- Warten bis Lobby erkannt
            local lobbyWait = 0
            while RUNNING and not IsInLobby() and lobbyWait < 15 do
                task.wait(1); lobbyWait = lobbyWait + 1
            end
            task.wait(2)   -- kurz in Lobby verweilen
        else
            -- Timeout – trotzdem weiter
            pcall(function()
                if farmStatusLbl then farmStatusLbl.Text="⚠  Timeout – nächstes Item..." end
            end)
            task.wait(2)
        end
    end
    farmActive = false
end

local function StartFarmLoop()
    if farmActive then return end
    farmThread = task.spawn(FarmLoop)
end

local function StopFarmLoop()
    farmActive = false
    RUNNING    = false
    task.wait(0.1)
    RUNNING    = true   -- für andere Loops wieder freigeben
    pcall(function()
        if farmStatusLbl then farmStatusLbl.Text="⏹  Auto-Farm gestoppt" end
    end)
end

-- ============================================================
--  ANTI-AFK
-- ============================================================
task.spawn(function()
    while RUNNING do
        task.wait(60)
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:SetKeyDown(" "); task.wait(0.1); VirtualUser:SetKeyUp(" ")
            task.wait(0.4)
            VirtualUser:SetKeyDown(" "); task.wait(0.1); VirtualUser:SetKeyUp(" ")
        end)
    end
end)

-- ============================================================
--  SESSION TIMER
-- ============================================================
local sessionTimerLbl = nil
local function FormatDuration(secs)
    local h=math.floor(secs/3600);local m=math.floor((secs%3600)/60);local s=secs%60
    if h>0 then return string.format("%dh %02dm %02ds",h,m,s) else return string.format("%dm %02ds",m,s) end
end
task.spawn(function()
    while RUNNING do
        task.wait(1)
        if sessionTimerLbl then
            pcall(function() sessionTimerLbl.Text="⏱  "..FormatDuration(os.time()-sessionStart) end)
        end
    end
end)

-- ============================================================
--  LOBBY-ERKENNUNG – startet Queue automatisch nach Rückkehr
-- ============================================================
task.spawn(function()
    local wasInGame = false
    while RUNNING do
        task.wait(3)
        local inLobby = IsInLobby()
        if wasInGame and inLobby then
            -- Spieler ist zurück in Lobby
            wasInGame = false
            if #FarmQueue>0 and GetCurrentQueueItem() and not farmActive then
                task.wait(3)   -- kurz warten
                if RUNNING then StartFarmLoop() end
            end
        end
        if not inLobby then wasInGame = true end
    end
end)

-- ============================================================
--  DESIGN TOKENS
-- ============================================================
local D={
    BG=Color3.fromRGB(13,15,25),Sidebar=Color3.fromRGB(9,11,20),
    Card=Color3.fromRGB(22,28,48),CardHover=Color3.fromRGB(30,38,62),
    Input=Color3.fromRGB(16,20,36),TabActive=Color3.fromRGB(18,26,50),
    TabInactive=Color3.fromRGB(14,18,34),
    Cyan=Color3.fromRGB(0,200,255),CyanDim=Color3.fromRGB(0,110,160),
    Green=Color3.fromRGB(0,220,120),GreenDark=Color3.fromRGB(0,55,28),
    GreenBright=Color3.fromRGB(50,255,140),
    Red=Color3.fromRGB(215,50,50),RedDark=Color3.fromRGB(60,10,10),
    Yellow=Color3.fromRGB(255,210,0),Orange=Color3.fromRGB(255,145,30),
    Purple=Color3.fromRGB(180,80,255),
    TextHi=Color3.fromRGB(235,245,255),TextMid=Color3.fromRGB(155,175,215),
    TextLow=Color3.fromRGB(80,100,148),Border=Color3.fromRGB(40,55,95),
    BorderCyan=Color3.fromRGB(0,150,200),
}

-- ============================================================
--  UTILITIES
-- ============================================================
local function Corner(p,r) local c=Instance.new("UICorner",p);c.CornerRadius=UDim.new(0,r or 10);return c end
local function Stroke(p,col,th,tr)
    local o=p:FindFirstChildOfClass("UIStroke");if o then o:Destroy() end
    local s=Instance.new("UIStroke",p);s.Color=col or D.Border;s.Thickness=th or 1;s.Transparency=tr or 0;return s
end
local function Pad(p,pt,pr,pb,pl)
    local u=Instance.new("UIPadding",p)
    u.PaddingTop=UDim.new(0,pt or 6);u.PaddingRight=UDim.new(0,pr or 6)
    u.PaddingBottom=UDim.new(0,pb or 6);u.PaddingLeft=UDim.new(0,pl or 6)
end
local function VList(p,pad)
    local l=Instance.new("UIListLayout",p);l.FillDirection=Enum.FillDirection.Vertical
    l.HorizontalAlignment=Enum.HorizontalAlignment.Left;l.Padding=UDim.new(0,pad or 6);l.SortOrder=Enum.SortOrder.LayoutOrder;return l
end
local function HList(p,pad)
    local l=Instance.new("UIListLayout",p);l.FillDirection=Enum.FillDirection.Horizontal
    l.VerticalAlignment=Enum.VerticalAlignment.Center;l.Padding=UDim.new(0,pad or 6);l.SortOrder=Enum.SortOrder.LayoutOrder;return l
end
local function MkLabel(parent,text,size,color,bold,xalign)
    local l=Instance.new("TextLabel",parent);l.BackgroundTransparency=1;l.Text=text or "";l.TextSize=size or 13
    l.TextColor3=color or D.TextHi;l.Font=bold and Enum.Font.GothamBold or Enum.Font.GothamSemibold
    l.TextXAlignment=xalign or Enum.TextXAlignment.Left;l.TextWrapped=true;l.Size=UDim2.new(1,0,0,(size or 13)+8);return l
end
local function SectionLabel(parent,text) local l=MkLabel(parent,text,10,D.TextLow,true);l.Size=UDim2.new(1,0,0,14);return l end
local function Card(parent,fixedH)
    local f=Instance.new("Frame",parent);f.BackgroundColor3=D.Card;f.BackgroundTransparency=0;f.BorderSizePixel=0
    if fixedH then f.Size=UDim2.new(1,0,0,fixedH) else f.Size=UDim2.new(1,0,0,0);f.AutomaticSize=Enum.AutomaticSize.Y end
    Corner(f,9);Stroke(f,D.Border,1,0.3);return f
end
local TI_fast=TweenInfo.new(0.15,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)
local TI_mid =TweenInfo.new(0.25,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)
local function Tween(obj,props,ti) TweenService:Create(obj,ti or TI_fast,props):Play() end

local function NeonBtn(parent,text,accent,height)
    local acc=accent or D.Cyan;local b=Instance.new("TextButton",parent)
    b.Size=UDim2.new(1,0,0,height or 34);b.BackgroundColor3=D.CardHover
    b.Text=text;b.TextColor3=acc;b.TextSize=13;b.Font=Enum.Font.GothamBold
    b.AutoButtonColor=false;b.BorderSizePixel=0;Corner(b,8);Stroke(b,acc,1,0.4)
    local function ct(f) return Color3.fromRGB(math.clamp(math.floor(acc.R*255*f),0,255),math.clamp(math.floor(acc.G*255*f),0,255),math.clamp(math.floor(acc.B*255*f),0,255)) end
    Track(b.MouseEnter:Connect(function() Tween(b,{BackgroundColor3=ct(0.25)}) end))
    Track(b.MouseLeave:Connect(function() Tween(b,{BackgroundColor3=D.CardHover}) end))
    Track(b.MouseButton1Down:Connect(function() Tween(b,{BackgroundColor3=ct(0.40)}) end))
    Track(b.MouseButton1Up:Connect(function() Tween(b,{BackgroundColor3=ct(0.25)}) end))
    return b
end

-- ============================================================
--  DRAG
-- ============================================================
local function MakeDraggable(frame,handle)
    local dragging,dragInput,dragStart,startPos
    Track(handle.InputBegan:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            dragging=true;dragStart=input.Position;startPos=frame.Position
            input.Changed:Connect(function() if input.UserInputState==Enum.UserInputState.End then dragging=false end end)
        end
    end))
    Track(handle.InputChanged:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseMovement or input.UserInputType==Enum.UserInputType.Touch then dragInput=input end
    end))
    Track(UserInputService.InputChanged:Connect(function(input)
        if input==dragInput and dragging then
            local d=input.Position-dragStart
            frame.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y)
        end
    end))
end

-- ============================================================
--  LOGO
-- ============================================================
local function BuildLogo(parent,lgSize,lgX,lgY)
    lgSize=lgSize or 32
    local lgRoot=Instance.new("Frame",parent);lgRoot.Size=UDim2.new(0,lgSize,0,lgSize);lgRoot.AnchorPoint=Vector2.new(0,0);lgRoot.Position=UDim2.new(0,lgX or 0,0,lgY or 0);lgRoot.BackgroundTransparency=1;lgRoot.BorderSizePixel=0
    local lgRing=Instance.new("Frame",lgRoot);lgRing.Size=UDim2.new(1,0,1,0);lgRing.BackgroundTransparency=1;lgRing.BorderSizePixel=0;Corner(lgRing,99);Stroke(lgRing,D.Cyan,1.5,0.35)
    local lgBg=Instance.new("Frame",lgRoot);lgBg.Size=UDim2.new(0.84,0,0.84,0);lgBg.Position=UDim2.new(0.08,0,0.08,0);lgBg.BackgroundColor3=Color3.fromRGB(0,15,38);lgBg.BackgroundTransparency=0.08;lgBg.BorderSizePixel=0;Corner(lgBg,99)
    local lgBgG=Instance.new("UIGradient",lgBg);lgBgG.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.fromRGB(0,38,85)),ColorSequenceKeypoint.new(1,Color3.fromRGB(0,8,28))});lgBgG.Rotation=135
    local lgTk=math.max(2,math.floor(lgSize*0.18));local lgBH=math.floor(lgSize*0.75);local lgBY=math.floor((lgSize-lgBH)/2);local lgBXL=math.floor(lgSize*0.18);local lgBXR=lgSize-lgBXL-lgTk
    local function lgGS() return ColorSequence.new({ColorSequenceKeypoint.new(0,D.Cyan),ColorSequenceKeypoint.new(0.5,D.Green),ColorSequenceKeypoint.new(1,D.Cyan)}) end
    local lgBL=Instance.new("Frame",lgRoot);lgBL.Size=UDim2.new(0,lgTk,0,lgBH);lgBL.Position=UDim2.new(0,lgBXL,0,lgBY);lgBL.BackgroundColor3=D.Cyan;lgBL.BorderSizePixel=0;Corner(lgBL,2);Instance.new("UIGradient",lgBL).Color=lgGS()
    local lgBR=Instance.new("Frame",lgRoot);lgBR.Size=UDim2.new(0,lgTk,0,lgBH);lgBR.Position=UDim2.new(0,lgBXR,0,lgBY);lgBR.BackgroundColor3=D.Cyan;lgBR.BorderSizePixel=0;Corner(lgBR,2);Instance.new("UIGradient",lgBR).Color=lgGS()
    local lgCH=math.max(2,math.floor(lgSize*0.14));local lgCW=lgBXR-lgBXL-lgTk;local lgCY=lgBY+math.floor((lgBH-lgCH)/2)
    local lgBC=Instance.new("Frame",lgRoot);lgBC.Size=UDim2.new(0,lgCW,0,lgCH);lgBC.Position=UDim2.new(0,lgBXL+lgTk,0,lgCY);lgBC.BackgroundColor3=D.Cyan;lgBC.BorderSizePixel=0;Corner(lgBC,2)
    local lgGGC=Instance.new("UIGradient",lgBC);lgGGC.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,D.Green),ColorSequenceKeypoint.new(1,D.Cyan)})
    local lgDS=lgCH+2;local lgDot=Instance.new("Frame",lgRoot);lgDot.Size=UDim2.new(0,lgDS,0,lgDS);lgDot.Position=UDim2.new(0,lgBXL+lgTk+math.floor(lgCW/2)-math.floor(lgDS/2),0,lgCY-1);lgDot.BackgroundColor3=Color3.new(1,1,1);lgDot.BackgroundTransparency=0.15;lgDot.BorderSizePixel=0;Corner(lgDot,99)
    task.spawn(function() while lgRoot.Parent and RUNNING do Tween(lgDot,{BackgroundTransparency=0.7},TI_mid);task.wait(0.85);Tween(lgDot,{BackgroundTransparency=0.1},TI_mid);task.wait(0.85) end end)
    return lgRoot
end

-- ============================================================
--  SCREEN GUI + MAIN FRAME
-- ============================================================
local ScreenGui=Instance.new("ScreenGui");ScreenGui.Name="HazeHUB_v16";ScreenGui.ResetOnSpawn=false;ScreenGui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling;ScreenGui.DisplayOrder=999;ScreenGui.IgnoreGuiInset=true;ScreenGui.Parent=guiParent

local Main=Instance.new("Frame",ScreenGui);Main.Name="Main";Main.Size=UDim2.new(0,570,0,440);Main.Position=UDim2.new(0.5,-285,0.5,-220);Main.BackgroundColor3=D.BG;Main.BackgroundTransparency=0.06;Main.BorderSizePixel=0;Corner(Main,12);Stroke(Main,D.BorderCyan,1.5,0.45)
local GlowOvr=Instance.new("Frame",Main);GlowOvr.Size=UDim2.new(1,0,0.35,0);GlowOvr.BackgroundColor3=D.Cyan;GlowOvr.BackgroundTransparency=0.94;GlowOvr.BorderSizePixel=0;Corner(GlowOvr,12)
local goG=Instance.new("UIGradient",GlowOvr);goG.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.fromRGB(0,180,255)),ColorSequenceKeypoint.new(1,Color3.fromRGB(0,0,0))});goG.Rotation=90

local Sidebar=Instance.new("Frame",Main);Sidebar.Name="Sidebar";Sidebar.BackgroundColor3=D.Sidebar;Sidebar.BackgroundTransparency=0.04;Sidebar.BorderSizePixel=0;Corner(Sidebar,10)
do
    local sd=Instance.new("Frame",Sidebar);sd.Size=UDim2.new(0,1,1,0);sd.Position=UDim2.new(1,-1,0,0);sd.BackgroundColor3=D.BorderCyan;sd.BackgroundTransparency=0.55;sd.BorderSizePixel=0
    local ss=Instance.new("Frame",Sidebar);ss.Size=UDim2.new(0,2,0.65,0);ss.Position=UDim2.new(0,0,0.175,0);ss.BackgroundColor3=D.Cyan;ss.BorderSizePixel=0;Corner(ss,2)
    local ssG=Instance.new("UIGradient",ss);ssG.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,D.Cyan),ColorSequenceKeypoint.new(0.5,D.Green),ColorSequenceKeypoint.new(1,D.Cyan)});ssG.Rotation=90
    local slf=Instance.new("Frame",Sidebar);slf.Size=UDim2.new(1,0,0,46);slf.Position=UDim2.new(0,0,0,2);slf.BackgroundTransparency=1
    local sl=BuildLogo(slf,32,0,7);sl.AnchorPoint=Vector2.new(0.5,0);sl.Position=UDim2.new(0.5,0,0,7)
end
local TabHolder=Instance.new("Frame",Sidebar);TabHolder.Position=UDim2.new(0,0,0,52);TabHolder.Size=UDim2.new(1,0,1,-56);TabHolder.BackgroundTransparency=1;VList(TabHolder,3);Pad(TabHolder,3,5,3,5)
local Content=Instance.new("Frame",Main);Content.Name="Content";Content.BackgroundTransparency=1

-- TAB SYSTEM
local Pages={}; local TabBtns={}; local activePage=nil
local function SelectTab(page,btn)
    for _,p in pairs(Pages) do p.Visible=false end
    for _,b in pairs(TabBtns) do b.BackgroundColor3=D.TabInactive;b.TextColor3=D.TextMid;local s=b:FindFirstChildOfClass("UIStroke");if s then s.Transparency=1 end end
    page.Visible=true;activePage=page;btn.BackgroundColor3=D.TabActive;btn.TextColor3=D.Cyan
    local s=btn:FindFirstChildOfClass("UIStroke");if s then s.Transparency=0 end
end
local function CreateTab(def)
    local B=Instance.new("TextButton",TabHolder);B.Size=UDim2.new(1,0,0,30);B.BackgroundColor3=D.TabInactive;B.Text=def.icon.."  "..def.name;B.TextColor3=D.TextMid;B.TextSize=10;B.Font=Enum.Font.GothamSemibold;B.AutoButtonColor=false;B.BorderSizePixel=0;Corner(B,7);Stroke(B,D.Cyan,1,1)
    Track(B.MouseEnter:Connect(function() if activePage~=Pages[def.name] then Tween(B,{BackgroundColor3=D.CardHover}) end end))
    Track(B.MouseLeave:Connect(function() if activePage~=Pages[def.name] then Tween(B,{BackgroundColor3=D.TabInactive}) end end))
    local P=Instance.new("ScrollingFrame",Content);P.Name=def.name;P.Size=UDim2.new(1,0,1,0);P.Visible=false;P.BackgroundTransparency=1;P.ScrollBarThickness=3;P.ScrollBarImageColor3=D.CyanDim;P.AutomaticCanvasSize=Enum.AutomaticSize.Y;P.BorderSizePixel=0;VList(P,8);Pad(P,10,10,10,10)
    Pages[def.name]=P;table.insert(TabBtns,B);Track(B.MouseButton1Click:Connect(function() SelectTab(P,B) end));return P,B
end
local GamePage, GameBtn  = CreateTab({name="Game",     icon="🎮"})
local FarmPage, FarmBtn  = CreateTab({name="AutoFarm", icon="🤖"})
local MiscPage, MiscBtn  = CreateTab({name="Misc",     icon="🔧"})
local SessPage, SessBtn  = CreateTab({name="Session",  icon="📊"})
local InvPage,  InvBtn   = CreateTab({name="Inventory",icon="🎒"})
local SettPage, SettBtn  = CreateTab({name="Settings", icon="⚙"})

-- Game-Tab shared upvalues
local UpdateAutoRetryUI   -- Vorwärtsdeklaration
local wTestBtn = nil      -- Webhook-Test-Button (aus Settings-Tab referenziert)

-- ============================================================
--  ===  GAME TAB  ===
-- ============================================================
do
MkLabel(GamePage,"🎮  Game",14,D.Cyan,true)

local scanCard=Card(GamePage,30);Pad(scanCard,4,10,4,10)
scanStatusLbl=Instance.new("TextLabel",scanCard);scanStatusLbl.Size=UDim2.new(1,0,1,0);scanStatusLbl.BackgroundTransparency=1;scanStatusLbl.Text="⏳  Scanne Welten...";scanStatusLbl.TextColor3=D.Yellow;scanStatusLbl.TextSize=10;scanStatusLbl.Font=Enum.Font.GothamSemibold;scanStatusLbl.TextXAlignment=Enum.TextXAlignment.Left

-- Auto-Retry
local arCard=Card(GamePage);Pad(arCard,10,12,10,12);VList(arCard,8);SectionLabel(arCard,"AUTO-RETRY")
local arRow=Instance.new("Frame",arCard);arRow.Size=UDim2.new(1,0,0,32);arRow.BackgroundTransparency=1;HList(arRow,10)
local arStatusLbl=Instance.new("TextLabel",arRow);arStatusLbl.Size=UDim2.new(0.55,0,1,0);arStatusLbl.BackgroundTransparency=1;arStatusLbl.Text="Auto Retry:  AUS";arStatusLbl.TextColor3=D.TextMid;arStatusLbl.TextSize=12;arStatusLbl.Font=Enum.Font.GothamBold;arStatusLbl.TextXAlignment=Enum.TextXAlignment.Left
local arToggleBtn=Instance.new("TextButton",arRow);arToggleBtn.Size=UDim2.new(0.42,0,0,30);arToggleBtn.BackgroundColor3=D.CardHover;arToggleBtn.Text="⬜  AUS";arToggleBtn.TextColor3=D.TextLow;arToggleBtn.TextSize=12;arToggleBtn.Font=Enum.Font.GothamBold;arToggleBtn.AutoButtonColor=false;arToggleBtn.BorderSizePixel=0;Corner(arToggleBtn,8);Stroke(arToggleBtn,D.TextLow,1,0.4)
UpdateAutoRetryUI=function()
    if Config.AutoRetry then arToggleBtn.Text="✅  AN";arToggleBtn.TextColor3=D.Green;arStatusLbl.Text="Auto Retry:  AN";arStatusLbl.TextColor3=D.Green;Stroke(arToggleBtn,D.Green,1.5,0);Tween(arToggleBtn,{BackgroundColor3=D.GreenDark})
    else arToggleBtn.Text="⬜  AUS";arToggleBtn.TextColor3=D.TextLow;arStatusLbl.Text="Auto Retry:  AUS";arStatusLbl.TextColor3=D.TextMid;Stroke(arToggleBtn,D.TextLow,1,0.4);Tween(arToggleBtn,{BackgroundColor3=D.CardHover}) end
end
Track(arToggleBtn.MouseButton1Click:Connect(function() Config.AutoRetry=not Config.AutoRetry;SaveConfig();UpdateAutoRetryUI() end))

-- Welt-Auswahl (komprimiert)
local worldCard=Card(GamePage);Pad(worldCard,10,10,10,10);VList(worldCard,8)
SectionLabel(worldCard,"WELT & KAPITEL AUSWAHL")
local worldStatusLbl=Instance.new("TextLabel",worldCard);worldStatusLbl.Size=UDim2.new(1,0,0,16);worldStatusLbl.BackgroundTransparency=1;worldStatusLbl.Text="Modus → Welt → Kapitel";worldStatusLbl.TextColor3=D.TextLow;worldStatusLbl.TextSize=11;worldStatusLbl.Font=Enum.Font.GothamSemibold;worldStatusLbl.TextXAlignment=Enum.TextXAlignment.Left

local selectedMode="Story"; local selectedWorldId=nil; local selectedChapterId=nil
local MODUS_DEF={{id="Story",label="📖 Story",color=D.Cyan},{id="Ranger",label="🏹 Ranger",color=D.Green},{id="Calamity",label="⚡ Calamity",color=D.Orange}}
local modeBtns={}
SectionLabel(worldCard,"SPIELMODUS")
local modeRow=Instance.new("Frame",worldCard);modeRow.Size=UDim2.new(1,0,0,28);modeRow.BackgroundTransparency=1;HList(modeRow,6)

local function HighlightModeBtn(activeId)
    for _,def in ipairs(MODUS_DEF) do local mb=modeBtns[def.id];if not mb then continue end
        if def.id==activeId then local c=def.color;Tween(mb,{BackgroundColor3=Color3.fromRGB(math.clamp(math.floor(c.R*255*0.22),0,255),math.clamp(math.floor(c.G*255*0.22),0,255),math.clamp(math.floor(c.B*255*0.22),0,255))});Stroke(mb,c,1.5,0)
        else Tween(mb,{BackgroundColor3=D.CardHover});Stroke(mb,D.Border,1,0.5) end
    end
end

local diffCard=Card(worldCard);Pad(diffCard,8,8,8,8);VList(diffCard,5);diffCard.Visible=true;SectionLabel(diffCard,"SCHWIERIGKEIT")
local diffRow=Instance.new("Frame",diffCard);diffRow.Size=UDim2.new(1,0,0,26);diffRow.BackgroundTransparency=1;HList(diffRow,6)
local diffColors={Normal=D.Green,Hard=D.Orange,Nightmare=D.Red};local diffBtns={}
for _,diff in ipairs({"Normal","Hard","Nightmare"}) do
    local db=Instance.new("TextButton",diffRow);db.Size=UDim2.new(0.32,0,0,24);db.BackgroundColor3=D.CardHover;db.Text=diff;db.TextColor3=diffColors[diff];db.TextSize=10;db.Font=Enum.Font.GothamBold;db.AutoButtonColor=false;db.BorderSizePixel=0;Corner(db,7);Stroke(db,diffColors[diff],1,0.4)
    Track(db.MouseButton1Click:Connect(function() FireChangeDifficulty(diff);for _,b in pairs(diffBtns) do Tween(b,{BackgroundColor3=D.CardHover});local bs=b:FindFirstChildOfClass("UIStroke");if bs then bs.Transparency=0.4 end end;Tween(db,{BackgroundColor3=Color3.fromRGB(math.clamp(math.floor(diffColors[diff].R*255*0.25),0,255),math.clamp(math.floor(diffColors[diff].G*255*0.25),0,255),math.clamp(math.floor(diffColors[diff].B*255*0.25),0,255))});local dbs=db:FindFirstChildOfClass("UIStroke");if dbs then dbs.Transparency=0 end end))
    diffBtns[diff]=db
end

local chapterCard=Card(worldCard);Pad(chapterCard,8,8,8,8);VList(chapterCard,5);SectionLabel(chapterCard,"KAPITEL / STAGE")
local chapterScroll=Instance.new("Frame",chapterCard);chapterScroll.Size=UDim2.new(1,0,0,0);chapterScroll.AutomaticSize=Enum.AutomaticSize.Y;chapterScroll.BackgroundTransparency=1;HList(chapterScroll,4)
local chapterBtns={}

local function RebuildChapterButtons(chapterList)
    for _,v in pairs(chapterScroll:GetChildren()) do if v:IsA("TextButton") then v:Destroy() end end
    chapterBtns={}
    if not chapterList or #chapterList==0 then return end
    selectedChapterId=chapterList[1]
    for i,chapId in ipairs(chapterList) do
        local ci=i;local capId=chapId;local numStr=chapId:match("(%d+)$") or tostring(i)
        local cb=Instance.new("TextButton",chapterScroll);cb.Size=UDim2.new(0,34,0,26);cb.BackgroundColor3=D.CardHover;cb.Text=numStr;cb.TextColor3=D.TextHi;cb.TextSize=12;cb.Font=Enum.Font.GothamBold;cb.AutoButtonColor=false;cb.BorderSizePixel=0;Corner(cb,7);Stroke(cb,D.Border,1,0.4)
        Track(cb.MouseButton1Click:Connect(function()
            selectedChapterId=capId;for _,b in pairs(chapterBtns) do Tween(b,{BackgroundColor3=D.CardHover});local bs=b:FindFirstChildOfClass("UIStroke");if bs then bs.Color=D.Border;bs.Transparency=0.4 end end
            Tween(cb,{BackgroundColor3=Color3.fromRGB(0,28,52)});Stroke(cb,D.Cyan,1.5,0)
            worldStatusLbl.Text=string.format("⚙  %s [%s] → %s",selectedWorldId or "?",selectedMode,capId);worldStatusLbl.TextColor3=D.Cyan
        end))
        chapterBtns[i]=cb
    end
    if chapterBtns[1] then Tween(chapterBtns[1],{BackgroundColor3=Color3.fromRGB(0,28,52)});Stroke(chapterBtns[1],D.Cyan,1.5,0) end
end

SectionLabel(worldCard,"WELTEN")
local worldBtnFrame=Instance.new("Frame",worldCard);worldBtnFrame.Size=UDim2.new(1,0,0,0);worldBtnFrame.AutomaticSize=Enum.AutomaticSize.Y;worldBtnFrame.BackgroundTransparency=1;VList(worldBtnFrame,4)

local function CreateWorldButton(worldId)
    local wb=Instance.new("TextButton",worldBtnFrame);wb.Size=UDim2.new(1,0,0,30);wb.BackgroundColor3=D.CardHover;wb.Text="🌍  "..worldId;wb.TextColor3=D.TextHi;wb.TextSize=11;wb.Font=Enum.Font.GothamSemibold;wb.AutoButtonColor=false;wb.BorderSizePixel=0;Corner(wb,7);Stroke(wb,D.Border,1,0.4)
    local capId=worldId
    Track(wb.MouseEnter:Connect(function() if selectedWorldId~=capId then Tween(wb,{BackgroundColor3=Color3.fromRGB(36,46,74)}) end end))
    Track(wb.MouseLeave:Connect(function() if selectedWorldId~=capId then Tween(wb,{BackgroundColor3=D.CardHover}) end end))
    Track(wb.MouseButton1Click:Connect(function()
        selectedWorldId=capId
        for _,b in pairs(worldBtnFrame:GetChildren()) do if b:IsA("TextButton") then Tween(b,{BackgroundColor3=D.CardHover});local bs=b:FindFirstChildOfClass("UIStroke");if bs then bs.Color=D.Border;bs.Transparency=0.4 end end end
        Tween(wb,{BackgroundColor3=Color3.fromRGB(0,28,52)});Stroke(wb,D.Cyan,1.5,0)
        worldStatusLbl.Text="🌍  "..capId.."  ["..selectedMode.."]  → Kapitel wählen";worldStatusLbl.TextColor3=D.Yellow
        local wData=WorldData[capId] or {}
        local chapList=(selectedMode=="Story" or selectedMode=="Calamity") and wData.story or wData.ranger
        RebuildChapterButtons(chapList or {})
    end))
end

local RebuildWorldList
RebuildWorldList=function()
    for _,v in pairs(worldBtnFrame:GetChildren()) do if v:IsA("TextButton") then v:Destroy() end end
    for _,v in pairs(chapterScroll:GetChildren()) do if v:IsA("TextButton") then v:Destroy() end end
    chapterBtns={};selectedWorldId=nil;selectedChapterId=nil
    if selectedMode=="Calamity" then
        local calData=WorldData["Calamity"]
        if calData and #calData.story>0 then selectedWorldId="Calamity";RebuildChapterButtons(calData.story);worldStatusLbl.Text="⚡  Calamity → Kapitel wählen";worldStatusLbl.TextColor3=D.Orange
        else worldStatusLbl.Text="⏳  Calamity lädt...";worldStatusLbl.TextColor3=D.Yellow end;return
    end
    local worldsWithMode={}
    for _,wid in ipairs(WorldIds) do
        if wid:lower():find("calamity") then continue end
        local wData=WorldData[wid] or {}
        local list=(selectedMode=="Story") and wData.story or wData.ranger
        if list and #list>0 then table.insert(worldsWithMode,wid) end
    end
    if #worldsWithMode==0 then worldStatusLbl.Text="⏳  Welten laden...";worldStatusLbl.TextColor3=D.Yellow;return end
    for _,wid in ipairs(worldsWithMode) do CreateWorldButton(wid) end
    worldStatusLbl.Text="✅  "..#worldsWithMode.." Welten verfügbar";worldStatusLbl.TextColor3=D.Green
end

local function OnModeSelected(modeId) selectedMode=modeId;HighlightModeBtn(modeId);diffCard.Visible=(modeId=="Story");RebuildWorldList() end
for _,def in ipairs(MODUS_DEF) do
    local mb=Instance.new("TextButton",modeRow);mb.Size=UDim2.new(0.32,0,0,26);mb.BackgroundColor3=D.CardHover;mb.Text=def.label;mb.TextColor3=def.color;mb.TextSize=10;mb.Font=Enum.Font.GothamBold;mb.AutoButtonColor=false;mb.BorderSizePixel=0;Corner(mb,7);Stroke(mb,D.Border,1,0.5)
    local capId=def.id;Track(mb.MouseButton1Click:Connect(function() OnModeSelected(capId) end));modeBtns[def.id]=mb
end
HighlightModeBtn("Story")

local createStartBtn=NeonBtn(worldCard,"🚀  Create & Start Room",D.Green,36)
Track(createStartBtn.MouseButton1Click:Connect(function()
    if not selectedChapterId then worldStatusLbl.Text="⚠  Welt & Kapitel wählen!";worldStatusLbl.TextColor3=D.Red;return end
    worldStatusLbl.Text="⚙  Erstelle: "..selectedChapterId;worldStatusLbl.TextColor3=D.Yellow
    createStartBtn.Text="⏳  Gestartet..."
    FireCreateAndStart(selectedWorldId or "Unknown",selectedMode,selectedChapterId)
    task.delay(2.5,function() pcall(function() createStartBtn.Text="🚀  Create & Start Room";worldStatusLbl.Text="✅  "..selectedChapterId;worldStatusLbl.TextColor3=D.Green end) end)
end))

local refreshBtn=NeonBtn(worldCard,"🔄  Welten neu laden",D.CyanDim,26)
Track(refreshBtn.MouseButton1Click:Connect(function()
    worldStatusLbl.Text="⏳  Scanne...";worldStatusLbl.TextColor3=D.Yellow;chapterFolderRef=nil
    task.spawn(function()
        local folder=GetChapterFolder()
        if folder then ScanChapterFolder(folder);pcall(function() scanStatusLbl.Text="✅  "..#WorldIds.." Welten";scanStatusLbl.TextColor3=D.Green end) else ApplyFallback() end
        pcall(function() RebuildWorldList() end)
    end)
end))
end -- do GAME TAB

-- ============================================================
--  ===  AUTO-FARM TAB  ===
-- ============================================================
do
MkLabel(FarmPage,"🤖  Auto-Farm",14,D.Cyan,true)

-- Status-Card
local farmStatusCard=Card(FarmPage,36);Pad(farmStatusCard,6,10,6,10)
farmStatusLbl=Instance.new("TextLabel",farmStatusCard);farmStatusLbl.Size=UDim2.new(1,0,1,0);farmStatusLbl.BackgroundTransparency=1;farmStatusLbl.Text="⏹  Auto-Farm gestoppt";farmStatusLbl.TextColor3=D.TextMid;farmStatusLbl.TextSize=11;farmStatusLbl.Font=Enum.Font.GothamSemibold;farmStatusLbl.TextXAlignment=Enum.TextXAlignment.Left

-- Reward-DB Scan
local dbCard=Card(FarmPage);Pad(dbCard,10,10,10,10);VList(dbCard,8);SectionLabel(dbCard,"🗃  REWARD-DATENBANK")
dbStatusLbl=MkLabel(dbCard,"Keine DB geladen. Starte Scan oder lade aus Datei.",11,D.TextLow);dbStatusLbl.Size=UDim2.new(1,0,0,24)
local dbBtnRow=Instance.new("Frame",dbCard);dbBtnRow.Size=UDim2.new(1,0,0,30);dbBtnRow.BackgroundTransparency=1;HList(dbBtnRow,8)
local scanDbBtn=Instance.new("TextButton",dbBtnRow);scanDbBtn.Size=UDim2.new(0.48,0,0,30);scanDbBtn.BackgroundColor3=D.CardHover;scanDbBtn.Text="🔍  Alle Rewards scannen";scanDbBtn.TextColor3=D.Purple;scanDbBtn.TextSize=11;scanDbBtn.Font=Enum.Font.GothamBold;scanDbBtn.AutoButtonColor=false;scanDbBtn.BorderSizePixel=0;Corner(scanDbBtn,7);Stroke(scanDbBtn,D.Purple,1,0.3)
local loadDbBtn=Instance.new("TextButton",dbBtnRow);loadDbBtn.Size=UDim2.new(0.48,0,0,30);loadDbBtn.BackgroundColor3=D.CardHover;loadDbBtn.Text="📂  DB laden";loadDbBtn.TextColor3=D.CyanDim;loadDbBtn.TextSize=11;loadDbBtn.Font=Enum.Font.GothamBold;loadDbBtn.AutoButtonColor=false;loadDbBtn.BorderSizePixel=0;Corner(loadDbBtn,7);Stroke(loadDbBtn,D.CyanDim,1,0.3)

Track(loadDbBtn.MouseButton1Click:Connect(function()
    if LoadRewardDB() then
        local count=0;for _ in pairs(RewardDB) do count=count+1 end
        dbStatusLbl.Text=string.format("✅  DB geladen: %d Chapter-Einträge",count);dbStatusLbl.TextColor3=D.Green
    else dbStatusLbl.Text="⚠  Keine DB-Datei gefunden. Bitte zuerst scannen.";dbStatusLbl.TextColor3=D.Orange end
end))

Track(scanDbBtn.MouseButton1Click:Connect(function()
    if not scanDone then dbStatusLbl.Text="⚠  Bitte zuerst Welten laden!";dbStatusLbl.TextColor3=D.Orange;return end
    dbStatusLbl.Text="⏳  Scan läuft...";dbStatusLbl.TextColor3=D.Yellow
    task.spawn(function()
        ScanAllRewards(function(msg)
            pcall(function() dbStatusLbl.Text=msg;dbStatusLbl.TextColor3=D.Yellow end)
        end)
        local count=0;for _ in pairs(RewardDB) do count=count+1 end
        pcall(function() dbStatusLbl.Text=string.format("✅  Scan fertig: %d Chapter",count);dbStatusLbl.TextColor3=D.Green end)
    end)
end))

-- Queue-Eingabe
local queueCard=Card(FarmPage);Pad(queueCard,10,10,10,10);VList(queueCard,8);SectionLabel(queueCard,"📋  AUTO-FARM QUEUE")
local qInputRow=Instance.new("Frame",queueCard);qInputRow.Size=UDim2.new(1,0,0,30);qInputRow.BackgroundTransparency=1;HList(qInputRow,5)
local qItemOuter=Instance.new("Frame",qInputRow);qItemOuter.Size=UDim2.new(0.50,0,0,30);qItemOuter.BackgroundColor3=D.Input;qItemOuter.BorderSizePixel=0;Corner(qItemOuter,7);Stroke(qItemOuter,D.Border,1,0.2)
local qItemBox=Instance.new("TextBox",qItemOuter);qItemBox.Size=UDim2.new(1,0,1,0);qItemBox.BackgroundTransparency=1;qItemBox.PlaceholderText="Item-Name...";qItemBox.PlaceholderColor3=D.TextLow;qItemBox.Text="";qItemBox.TextColor3=D.TextHi;qItemBox.TextSize=11;qItemBox.Font=Enum.Font.Gotham;qItemBox.ClearTextOnFocus=false;Pad(qItemBox,0,8,0,8)
local qAmtOuter=Instance.new("Frame",qInputRow);qAmtOuter.Size=UDim2.new(0.28,0,0,30);qAmtOuter.BackgroundColor3=D.Input;qAmtOuter.BorderSizePixel=0;Corner(qAmtOuter,7);Stroke(qAmtOuter,D.Border,1,0.2)
local qAmtBox=Instance.new("TextBox",qAmtOuter);qAmtBox.Size=UDim2.new(1,0,1,0);qAmtBox.BackgroundTransparency=1;qAmtBox.PlaceholderText="Anzahl";qAmtBox.PlaceholderColor3=D.TextLow;qAmtBox.Text="";qAmtBox.TextColor3=D.TextHi;qAmtBox.TextSize=11;qAmtBox.Font=Enum.Font.Gotham;qAmtBox.ClearTextOnFocus=false;Pad(qAmtBox,0,8,0,8)
local qAddBtn=Instance.new("TextButton",qInputRow);qAddBtn.Size=UDim2.new(0.19,0,0,30);qAddBtn.BackgroundColor3=D.Green;qAddBtn.Text="+ Add";qAddBtn.TextColor3=Color3.new(1,1,1);qAddBtn.TextSize=11;qAddBtn.Font=Enum.Font.GothamBold;qAddBtn.AutoButtonColor=false;qAddBtn.BorderSizePixel=0;Corner(qAddBtn,7);Stroke(qAddBtn,D.Green,1,0.2)
Track(qAddBtn.MouseEnter:Connect(function() Tween(qAddBtn,{BackgroundColor3=Color3.fromRGB(0,160,80)}) end))
Track(qAddBtn.MouseLeave:Connect(function() Tween(qAddBtn,{BackgroundColor3=D.Green}) end))

local queueListFrame=Instance.new("Frame",queueCard);queueListFrame.Size=UDim2.new(1,0,0,0);queueListFrame.AutomaticSize=Enum.AutomaticSize.Y;queueListFrame.BackgroundTransparency=1;VList(queueListFrame,4)
local qEmptyLbl=MkLabel(queueListFrame,"Queue leer. Item + Anzahl eingeben und hinzufügen.",11,D.TextLow);qEmptyLbl.Size=UDim2.new(1,0,0,28)

UpdateFarmQueueUI=function()
    for _,v in pairs(queueListFrame:GetChildren()) do if v:IsA("Frame") then v:Destroy() end end
    qEmptyLbl.Visible=(#FarmQueue==0)
    for i,q in ipairs(FarmQueue) do
        local invAmt  = GetInventoryAmount(q.item)
        local pct     = math.min(1, invAmt/math.max(1,q.amount))
        local isNext  = (not q.done) and (GetCurrentQueueItem()==q)
        local row=Instance.new("Frame",queueListFrame);row.Size=UDim2.new(1,0,0,42);row.BorderSizePixel=0;Corner(row,8)
        if q.done then row.BackgroundColor3=D.GreenDark;Stroke(row,D.GreenBright,1.5,0)
        elseif isNext then row.BackgroundColor3=Color3.fromRGB(0,30,55);Stroke(row,D.Cyan,1.5,0)
        else row.BackgroundColor3=D.Card;Stroke(row,D.Border,1,0.4) end

        local bar=Instance.new("Frame",row);bar.Size=UDim2.new(0,3,0.65,0);bar.Position=UDim2.new(0,0,0.175,0);bar.BackgroundColor3=q.done and D.GreenBright or (isNext and D.Cyan or D.Purple);bar.BorderSizePixel=0;Corner(bar,2)
        local pgBg=Instance.new("Frame",row);pgBg.Size=UDim2.new(1,-52,0,3);pgBg.Position=UDim2.new(0,8,1,-6);pgBg.BackgroundColor3=Color3.fromRGB(28,38,62);pgBg.BorderSizePixel=0;Corner(pgBg,2)
        local pgFill=Instance.new("Frame",pgBg);pgFill.Size=UDim2.new(pct,0,1,0);pgFill.BackgroundColor3=q.done and D.GreenBright or (isNext and D.Cyan or D.Purple);pgFill.BorderSizePixel=0;Corner(pgFill,2)

        local nL=Instance.new("TextLabel",row);nL.Position=UDim2.new(0,12,0,4);nL.Size=UDim2.new(1,-52,0.5,-2);nL.BackgroundTransparency=1;nL.Text=(isNext and "▶ " or "")..(q.done and "✅ " or "")..q.item;nL.TextColor3=q.done and D.GreenBright or (isNext and D.Cyan or D.TextHi);nL.TextSize=11;nL.Font=Enum.Font.GothamBold;nL.TextXAlignment=Enum.TextXAlignment.Left;nL.TextTruncate=Enum.TextTruncate.AtEnd
        local pL=Instance.new("TextLabel",row);pL.Position=UDim2.new(0,12,0.5,0);pL.Size=UDim2.new(1,-52,0.5,-4);pL.BackgroundTransparency=1
        pL.Text=tostring(invAmt).." / "..tostring(q.amount).."  ("..math.floor(pct*100).."%)"
        pL.TextColor3=q.done and D.GreenBright or D.TextMid;pL.TextSize=10;pL.Font=Enum.Font.GothamSemibold;pL.TextXAlignment=Enum.TextXAlignment.Left

        local capturedI=i
        local xBtn=Instance.new("TextButton",row);xBtn.Size=UDim2.new(0,34,0,34);xBtn.Position=UDim2.new(1,-38,0.5,-17);xBtn.BackgroundColor3=Color3.fromRGB(50,12,12);xBtn.Text="✕";xBtn.TextColor3=D.Red;xBtn.TextSize=13;xBtn.Font=Enum.Font.GothamBold;xBtn.AutoButtonColor=false;xBtn.BorderSizePixel=0;Corner(xBtn,7);Stroke(xBtn,D.Red,1,0.4)
        Track(xBtn.MouseEnter:Connect(function() Tween(xBtn,{BackgroundColor3=D.RedDark}) end))
        Track(xBtn.MouseLeave:Connect(function() Tween(xBtn,{BackgroundColor3=Color3.fromRGB(50,12,12)}) end))
        Track(xBtn.MouseButton1Click:Connect(function() table.remove(FarmQueue,capturedI);SaveConfig();UpdateFarmQueueUI() end))
    end
end

Track(qAddBtn.MouseButton1Click:Connect(function()
    local iname=(qItemBox.Text or ""):match("^%s*(.-)%s*$")
    local iamt=tonumber(qAmtBox.Text)
    if iname=="" or not iamt or iamt<=0 then return end
    -- Auch als Session-Ziel hinzufügen
    local found=false;for _,g in ipairs(Goals) do if g.item==iname then found=true;break end end
    if not found then table.insert(Goals,{item=iname,amount=iamt,reached=false}) end
    table.insert(FarmQueue,{item=iname,amount=iamt,done=false})
    SaveConfig();qItemBox.Text="";qAmtBox.Text=""
    UpdateFarmQueueUI();UpdateGoalsUI()
end))

-- Steuerungs-Buttons
local farmCtrlRow=Instance.new("Frame",queueCard);farmCtrlRow.Size=UDim2.new(1,0,0,32);farmCtrlRow.BackgroundTransparency=1;HList(farmCtrlRow,8)
local startFarmBtn=Instance.new("TextButton",farmCtrlRow);startFarmBtn.Size=UDim2.new(0.48,0,0,32);startFarmBtn.BackgroundColor3=D.Green;startFarmBtn.Text="▶  Start Queue";startFarmBtn.TextColor3=Color3.new(1,1,1);startFarmBtn.TextSize=12;startFarmBtn.Font=Enum.Font.GothamBold;startFarmBtn.AutoButtonColor=false;startFarmBtn.BorderSizePixel=0;Corner(startFarmBtn,8);Stroke(startFarmBtn,D.Green,1,0.2)
local stopFarmBtn=Instance.new("TextButton",farmCtrlRow);stopFarmBtn.Size=UDim2.new(0.48,0,0,32);stopFarmBtn.BackgroundColor3=D.RedDark;stopFarmBtn.Text="⏹  Stop";stopFarmBtn.TextColor3=D.Red;stopFarmBtn.TextSize=12;stopFarmBtn.Font=Enum.Font.GothamBold;stopFarmBtn.AutoButtonColor=false;stopFarmBtn.BorderSizePixel=0;Corner(stopFarmBtn,8);Stroke(stopFarmBtn,D.Red,1,0.4)
Track(startFarmBtn.MouseButton1Click:Connect(function()
    if not next(RewardDB) then farmStatusLbl.Text="⚠  Bitte zuerst Reward-DB laden/scannen!";farmStatusLbl.TextColor3=D.Orange;return end
    StartFarmLoop()
end))
Track(stopFarmBtn.MouseButton1Click:Connect(StopFarmLoop))

local clearQueueBtn=NeonBtn(queueCard,"🗑  Queue leeren",D.Red,28)
Track(clearQueueBtn.MouseButton1Click:Connect(function()
    FarmQueue={};SaveConfig();UpdateFarmQueueUI()
end))

-- Queue Live-Update alle 5s
task.spawn(function()
    while RUNNING do task.wait(5);pcall(function() UpdateFarmQueueUI() end) end
end)
end -- do AUTOFARM TAB

-- ============================================================
--  ===  MISC TAB  ===
-- ============================================================
do
MkLabel(MiscPage,"🔧  Misc",14,D.Cyan,true)
local afkCard=Card(MiscPage,50);Pad(afkCard,0,14,0,14)
local afkRow2=Instance.new("Frame",afkCard);afkRow2.Size=UDim2.new(1,0,1,0);afkRow2.BackgroundTransparency=1
local afkDot=Instance.new("Frame",afkRow2);afkDot.Size=UDim2.new(0,10,0,10);afkDot.Position=UDim2.new(0,0,0.5,-5);afkDot.BackgroundColor3=D.Green;afkDot.BorderSizePixel=0;Corner(afkDot,99)
local afkLbl=Instance.new("TextLabel",afkRow2);afkLbl.Position=UDim2.new(0,18,0,0);afkLbl.Size=UDim2.new(1,-18,1,0);afkLbl.BackgroundTransparency=1;afkLbl.Text="Anti-AFK  —  Aktiv (alle 60s)";afkLbl.TextColor3=D.Green;afkLbl.TextSize=13;afkLbl.Font=Enum.Font.GothamBold;afkLbl.TextXAlignment=Enum.TextXAlignment.Left
task.spawn(function() while RUNNING and ScreenGui.Parent do Tween(afkDot,{BackgroundTransparency=0.65},TI_mid);task.wait(1.1);Tween(afkDot,{BackgroundTransparency=0},TI_mid);task.wait(1.1) end end)
end -- do MISC TAB

-- ============================================================
--  SESSION TAB – shared upvalues (benötigt von Farm-Loop & Events)
-- ============================================================
local sRoundsLbl      = nil
local sItemCountLbl   = nil
local infoDisplays    = {}
local goalsListFrame  = nil
local goalsEmptyLbl   = nil
local goalItemBox     = nil
local goalAmtBox      = nil
local goalItemOuter   = nil
local goalAmtOuter    = nil
local sListCard       = nil
local sEmptyLbl       = nil
local sTotalLbl       = nil

-- ============================================================
--  ===  SESSION TAB  ===
-- ============================================================
do
local sHeaderCard=Card(SessPage,65);Pad(sHeaderCard,6,12,4,12)
local sHRow=Instance.new("Frame",sHeaderCard);sHRow.Size=UDim2.new(1,0,0,30);sHRow.BackgroundTransparency=1
sRoundsLbl=Instance.new("TextLabel",sHRow);sRoundsLbl.Size=UDim2.new(0.55,0,1,0);sRoundsLbl.BackgroundTransparency=1;sRoundsLbl.Text="Runden: 0";sRoundsLbl.TextColor3=D.Green;sRoundsLbl.TextSize=14;sRoundsLbl.Font=Enum.Font.GothamBold;sRoundsLbl.TextXAlignment=Enum.TextXAlignment.Left
sItemCountLbl=Instance.new("TextLabel",sHRow);sItemCountLbl.Position=UDim2.new(0.55,0,0,0);sItemCountLbl.Size=UDim2.new(0.45,0,1,0);sItemCountLbl.BackgroundTransparency=1;sItemCountLbl.Text="0 Items";sItemCountLbl.TextColor3=D.TextMid;sItemCountLbl.TextSize=12;sItemCountLbl.Font=Enum.Font.GothamSemibold;sItemCountLbl.TextXAlignment=Enum.TextXAlignment.Right
local sTimerRow=Instance.new("Frame",sHeaderCard);sTimerRow.Size=UDim2.new(1,0,0,22);sTimerRow.BackgroundTransparency=1
sessionTimerLbl=Instance.new("TextLabel",sTimerRow);sessionTimerLbl.Size=UDim2.new(1,0,1,0);sessionTimerLbl.BackgroundTransparency=1;sessionTimerLbl.Text="⏱  0m 00s";sessionTimerLbl.TextColor3=D.TextLow;sessionTimerLbl.TextSize=11;sessionTimerLbl.Font=Enum.Font.Gotham;sessionTimerLbl.TextXAlignment=Enum.TextXAlignment.Left

local infoSectCard=Card(SessPage);Pad(infoSectCard,8,10,8,10);VList(infoSectCard,5);SectionLabel(infoSectCard,"ℹ  INFO-ITEMS")
local infoItemsFrame=Instance.new("Frame",infoSectCard);infoItemsFrame.Size=UDim2.new(1,0,0,0);infoItemsFrame.AutomaticSize=Enum.AutomaticSize.Y;infoItemsFrame.BackgroundTransparency=1;HList(infoItemsFrame,8)
for _,iname in ipairs({"Exp","Gems","Gold"}) do
    local iF=Instance.new("Frame",infoItemsFrame);iF.Size=UDim2.new(0.31,0,0,44);iF.BackgroundColor3=Color3.fromRGB(12,22,40);iF.BorderSizePixel=0;Corner(iF,8);Stroke(iF,D.Orange,1,0.5)
    local iN=Instance.new("TextLabel",iF);iN.Size=UDim2.new(1,0,0.45,0);iN.BackgroundTransparency=1;iN.Text=iname;iN.TextColor3=D.Orange;iN.TextSize=10;iN.Font=Enum.Font.GothamSemibold;iN.TextXAlignment=Enum.TextXAlignment.Center
    local iV=Instance.new("TextLabel",iF);iV.Size=UDim2.new(1,0,0.55,0);iV.Position=UDim2.new(0,0,0.45,0);iV.BackgroundTransparency=1;iV.Text="0";iV.TextColor3=D.TextHi;iV.TextSize=14;iV.Font=Enum.Font.GothamBold;iV.TextXAlignment=Enum.TextXAlignment.Center
    infoDisplays[iname]=iV
end

-- Multi-Targeting
local goalsCard=Card(SessPage);Pad(goalsCard,10,10,10,10);VList(goalsCard,8);SectionLabel(goalsCard,"🎯  ZIELE  (Multi-Targeting · AutoSave)")
local goalInputRow=Instance.new("Frame",goalsCard);goalInputRow.Size=UDim2.new(1,0,0,30);goalInputRow.BackgroundTransparency=1;HList(goalInputRow,5)
goalItemOuter=Instance.new("Frame",goalInputRow);goalItemOuter.Size=UDim2.new(0.50,0,0,30);goalItemOuter.BackgroundColor3=D.Input;goalItemOuter.BorderSizePixel=0;Corner(goalItemOuter,7);Stroke(goalItemOuter,D.Border,1,0.2)
goalItemBox=Instance.new("TextBox",goalItemOuter);goalItemBox.Size=UDim2.new(1,0,1,0);goalItemBox.BackgroundTransparency=1;goalItemBox.PlaceholderText="Item-Name...";goalItemBox.PlaceholderColor3=D.TextLow;goalItemBox.Text="";goalItemBox.TextColor3=D.TextHi;goalItemBox.TextSize=11;goalItemBox.Font=Enum.Font.Gotham;goalItemBox.ClearTextOnFocus=false;Pad(goalItemBox,0,8,0,8)
goalAmtOuter=Instance.new("Frame",goalInputRow);goalAmtOuter.Size=UDim2.new(0.28,0,0,30);goalAmtOuter.BackgroundColor3=D.Input;goalAmtOuter.BorderSizePixel=0;Corner(goalAmtOuter,7);Stroke(goalAmtOuter,D.Border,1,0.2)
goalAmtBox=Instance.new("TextBox",goalAmtOuter);goalAmtBox.Size=UDim2.new(1,0,1,0);goalAmtBox.BackgroundTransparency=1;goalAmtBox.PlaceholderText="Anzahl";goalAmtBox.PlaceholderColor3=D.TextLow;goalAmtBox.Text="";goalAmtBox.TextColor3=D.TextHi;goalAmtBox.TextSize=11;goalAmtBox.Font=Enum.Font.Gotham;goalAmtBox.ClearTextOnFocus=false;Pad(goalAmtBox,0,8,0,8)
local goalAddBtn=Instance.new("TextButton",goalInputRow);goalAddBtn.Size=UDim2.new(0.19,0,0,30);goalAddBtn.BackgroundColor3=D.Purple;goalAddBtn.Text="+ Ziel";goalAddBtn.TextColor3=Color3.new(1,1,1);goalAddBtn.TextSize=11;goalAddBtn.Font=Enum.Font.GothamBold;goalAddBtn.AutoButtonColor=false;goalAddBtn.BorderSizePixel=0;Corner(goalAddBtn,7);Stroke(goalAddBtn,D.Purple,1,0.2)
Track(goalAddBtn.MouseEnter:Connect(function() Tween(goalAddBtn,{BackgroundColor3=Color3.fromRGB(150,60,220)}) end))
Track(goalAddBtn.MouseLeave:Connect(function() Tween(goalAddBtn,{BackgroundColor3=D.Purple}) end))

goalsListFrame=Instance.new("Frame",goalsCard);goalsListFrame.Size=UDim2.new(1,0,0,0);goalsListFrame.AutomaticSize=Enum.AutomaticSize.Y;goalsListFrame.BackgroundTransparency=1;VList(goalsListFrame,4)
goalsEmptyLbl=MkLabel(goalsListFrame,"Keine Ziele. Inventar-Item anklicken oder eintragen.",11,D.TextLow);goalsEmptyLbl.Size=UDim2.new(1,0,0,28)

-- UpdateGoalsUI – nutzt echte Inventar-Menge
UpdateGoalsUI=function()
    for _,v in pairs(goalsListFrame:GetChildren()) do if v:IsA("Frame") then v:Destroy() end end
    goalsEmptyLbl.Visible=(#Goals==0)
    for _,goal in ipairs(Goals) do
        -- Echtzeit-Inventar-Check
        local cur=math.max(SessionTotals[goal.item] or 0, GetInventoryAmount(goal.item))
        local reached=cur>=goal.amount;goal.reached=reached
        local pct=math.min(1,cur/math.max(1,goal.amount))
        local row=Instance.new("Frame",goalsListFrame);row.Size=UDim2.new(1,0,0,44);row.BorderSizePixel=0;Corner(row,8)
        if reached then row.BackgroundColor3=D.GreenDark;Stroke(row,D.GreenBright,1.5,0) else row.BackgroundColor3=D.Card;Stroke(row,D.Border,1,0.4) end
        local bar=Instance.new("Frame",row);bar.Size=UDim2.new(0,3,0.65,0);bar.Position=UDim2.new(0,0,0.175,0);bar.BackgroundColor3=reached and D.GreenBright or D.Purple;bar.BorderSizePixel=0;Corner(bar,2)
        local pgBg=Instance.new("Frame",row);pgBg.Size=UDim2.new(1,-52,0,3);pgBg.Position=UDim2.new(0,8,1,-6);pgBg.BackgroundColor3=Color3.fromRGB(28,38,62);pgBg.BorderSizePixel=0;Corner(pgBg,2)
        local pgFill=Instance.new("Frame",pgBg);pgFill.Size=UDim2.new(pct,0,1,0);pgFill.BackgroundColor3=reached and D.GreenBright or D.Purple;pgFill.BorderSizePixel=0;Corner(pgFill,2)
        local nL=Instance.new("TextLabel",row);nL.Position=UDim2.new(0,12,0,5);nL.Size=UDim2.new(1,-52,0.5,-3);nL.BackgroundTransparency=1;nL.Text=goal.item;nL.TextColor3=reached and D.GreenBright or D.TextHi;nL.TextSize=11;nL.Font=Enum.Font.GothamBold;nL.TextXAlignment=Enum.TextXAlignment.Left;nL.TextTruncate=Enum.TextTruncate.AtEnd
        local pL=Instance.new("TextLabel",row);pL.Position=UDim2.new(0,12,0.5,1);pL.Size=UDim2.new(1,-52,0.5,-5);pL.BackgroundTransparency=1
        if reached then pL.Text="✅  "..cur.." / "..goal.amount.."  ERREICHT!";pL.TextColor3=D.GreenBright
        else pL.Text=tostring(cur).." / "..tostring(goal.amount).."  ("..math.floor(pct*100).."%)";pL.TextColor3=D.TextMid end
        pL.TextSize=10;pL.Font=Enum.Font.GothamSemibold;pL.TextXAlignment=Enum.TextXAlignment.Left
        local capturedItem=goal.item
        local xBtn=Instance.new("TextButton",row);xBtn.Size=UDim2.new(0,34,0,34);xBtn.Position=UDim2.new(1,-38,0.5,-17);xBtn.BackgroundColor3=Color3.fromRGB(50,12,12);xBtn.Text="✕";xBtn.TextColor3=D.Red;xBtn.TextSize=13;xBtn.Font=Enum.Font.GothamBold;xBtn.AutoButtonColor=false;xBtn.BorderSizePixel=0;Corner(xBtn,7);Stroke(xBtn,D.Red,1,0.4)
        Track(xBtn.MouseEnter:Connect(function() Tween(xBtn,{BackgroundColor3=D.RedDark}) end))
        Track(xBtn.MouseLeave:Connect(function() Tween(xBtn,{BackgroundColor3=Color3.fromRGB(50,12,12)}) end))
        Track(xBtn.MouseButton1Click:Connect(function()
            local idx=nil;for i,g in ipairs(Goals) do if g.item==capturedItem then idx=i;break end end
            if idx then table.remove(Goals,idx) end;goalsNotifiedSet[capturedItem]=nil;SaveConfig();UpdateGoalsUI()
        end))
        if reached then task.spawn(function() while row.Parent do Tween(row,{BackgroundColor3=Color3.fromRGB(0,75,38)},TI_mid);task.wait(0.65);if not row.Parent then break end;Tween(row,{BackgroundColor3=D.GreenDark},TI_mid);task.wait(0.65) end end) end
    end
end

Track(goalAddBtn.MouseButton1Click:Connect(function()
    local iname=(goalItemBox.Text or ""):match("^%s*(.-)%s*$");local iamt=tonumber(goalAmtBox.Text)
    if iname=="" or not iamt or iamt<=0 then return end
    local found=false;for _,g in ipairs(Goals) do if g.item==iname then found=true;break end end
    if not found then table.insert(Goals,{item=iname,amount=iamt,reached=false}) end
    goalsNotifiedSet[iname]=nil;SaveConfig();UpdateGoalsUI();goalItemBox.Text="";goalAmtBox.Text=""
end))

local function SetGoalFromInventory(itemName)
    SelectTab(SessPage,SessBtn);goalItemBox.Text=itemName;goalAmtBox.Text=""
    task.defer(function() pcall(function() goalAmtBox:CaptureFocus() end) end)
    Stroke(goalItemOuter,D.Purple,1.5,0);Stroke(goalAmtOuter,D.Purple,1.5,0)
    task.delay(2.5,function() Stroke(goalItemOuter,D.Border,1,0.2);Stroke(goalAmtOuter,D.Border,1,0.2) end)
end

local sListCard=Card(SessPage);Pad(sListCard,6,8,6,8);VList(sListCard,4)
sEmptyLbl=MkLabel(sListCard,"Noch keine Items...",12,D.TextLow);sEmptyLbl.Size=UDim2.new(1,0,0,30);sEmptyLbl.TextXAlignment=Enum.TextXAlignment.Center
local sTotalCard=Card(SessPage,34);Pad(sTotalCard,0,12,0,12)
local sTotalRow=Instance.new("Frame",sTotalCard);sTotalRow.Size=UDim2.new(1,0,1,0);sTotalRow.BackgroundTransparency=1
sTotalLbl=MkLabel(sTotalRow,"Gesamt: 0 Items",12,D.TextMid);sTotalLbl.Size=UDim2.new(1,0,1,0);sTotalLbl.TextXAlignment=Enum.TextXAlignment.Right
local sResetBtn=NeonBtn(SessPage,"🗑  Session zurücksetzen",D.Red,34)

local function UpdateSessionUI()
    if not sRoundsLbl then return end
    sRoundsLbl.Text="Runden: "..roundCount
    for iname,lbl in pairs(infoDisplays) do lbl.Text=tostring(InfoTotals[iname] or 0) end
    for _,v in pairs(sListCard:GetChildren()) do if v:IsA("Frame") then v:Destroy() end end
    local total,count=0,0
    for name,amt in pairs(SessionTotals) do
        total=total+amt;count=count+1;local isRare=RARE_ITEMS[name]==true
        local row=Instance.new("Frame",sListCard);row.Size=UDim2.new(1,0,0,34);row.BorderSizePixel=0;Corner(row,7)
        if isRare then row.BackgroundColor3=D.RedDark;Stroke(row,D.Red,1.5,0) else row.BackgroundColor3=D.CardHover;Stroke(row,D.Border,1,0.5) end
        local bar=Instance.new("Frame",row);bar.Size=UDim2.new(0,3,0.55,0);bar.Position=UDim2.new(0,0,0.225,0);bar.BackgroundColor3=isRare and D.Red or D.Cyan;bar.BorderSizePixel=0;Corner(bar,2)
        local nL=Instance.new("TextLabel",row);nL.Position=UDim2.new(0,12,0,0);nL.Size=UDim2.new(1,-70,1,0);nL.BackgroundTransparency=1;nL.Text=name;nL.TextColor3=isRare and D.Red or D.TextHi;nL.TextSize=12;nL.Font=Enum.Font.GothamBold;nL.TextXAlignment=Enum.TextXAlignment.Left;nL.TextTruncate=Enum.TextTruncate.AtEnd
        if isRare then local rg=Instance.new("UIGradient",nL);rg.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.fromRGB(255,60,60)),ColorSequenceKeypoint.new(0.5,Color3.fromRGB(255,180,0)),ColorSequenceKeypoint.new(1,Color3.fromRGB(255,60,60))});task.spawn(function() local off=0;while nL.Parent do off=(off+0.02)%1;rg.Offset=Vector2.new(off,0);task.wait(0.05) end end) end
        local aL=Instance.new("TextLabel",row);aL.Position=UDim2.new(1,-62,0,0);aL.Size=UDim2.new(0,56,1,0);aL.BackgroundTransparency=1;aL.Text="×"..tostring(amt);aL.TextColor3=isRare and D.Red or D.Cyan;aL.TextSize=13;aL.Font=Enum.Font.GothamBold;aL.TextXAlignment=Enum.TextXAlignment.Right
    end
    sEmptyLbl.Visible=(count==0);sTotalLbl.Text="Gesamt: "..tostring(total).." Items";sItemCountLbl.Text=tostring(total).." Items"
    UpdateGoalsUI()
end

Track(sResetBtn.MouseButton1Click:Connect(function()
    SessionTotals={};InfoTotals={};roundCount=0;sessionStart=os.time()
    for _,g in ipairs(Goals) do g.reached=false end;goalsNotifiedSet={};UpdateSessionUI()
end))
end -- do SESSION TAB

-- ============================================================
--  ===  INVENTORY TAB  ===
-- ============================================================
do
MkLabel(InvPage,"🎒  Inventar",14,D.Cyan,true)
local invInfoLbl=MkLabel(InvPage,"Alphabetisch · Klick = Ziel hinzufügen",11,D.TextLow);invInfoLbl.Size=UDim2.new(1,0,0,20)
local invListCard=Card(InvPage);Pad(invListCard,6,8,6,8);VList(invListCard,4)
local invEmptyLbl=MkLabel(invListCard,"Inventar wird geladen...",12,D.TextLow);invEmptyLbl.Size=UDim2.new(1,0,0,30);invEmptyLbl.TextXAlignment=Enum.TextXAlignment.Center
local invRefreshBtn=NeonBtn(InvPage,"🔄  Inventar neu laden",D.CyanDim,30)

local function RebuildInventoryUI()
    if not invListCard then return end
    for _,v in pairs(invListCard:GetChildren()) do if v:IsA("Frame") then v:Destroy() end end
    local itemsFolder=nil
    pcall(function() itemsFolder=ReplicatedStorage:WaitForChild("Player_Data",5):WaitForChild(Player.Name,5):WaitForChild("Items",5) end)
    if not itemsFolder then invEmptyLbl.Visible=true;invEmptyLbl.Text="Pfad nicht gefunden";invEmptyLbl.TextColor3=D.Orange;return end
    local children=itemsFolder:GetChildren()
    if #children==0 then invEmptyLbl.Visible=true;invEmptyLbl.Text="Inventar leer";invEmptyLbl.TextColor3=D.TextLow;return end
    invEmptyLbl.Visible=false
    table.sort(children,function(a,b) return a.Name:lower()<b.Name:lower() end)
    for _,item in ipairs(children) do
        local itemName,itemValue="",""
        pcall(function() itemName=item.Name;if item:IsA("StringValue") then itemValue=tostring(item.Value) else local vc=item:FindFirstChild("Value") or item:FindFirstChild("Amount");if vc then itemValue=tostring(vc.Value) end end end)
        if itemName~="" then
            local isRare=RARE_ITEMS[itemName]==true
            local row=Instance.new("Frame",invListCard);row.Size=UDim2.new(1,0,0,36);row.BorderSizePixel=0;Corner(row,7)
            row.BackgroundColor3=isRare and D.RedDark or D.CardHover;Stroke(row,isRare and D.Red or D.Border,1,isRare and 0 or 0.5)
            local clickBtn=Instance.new("TextButton",row);clickBtn.Size=UDim2.new(1,0,1,0);clickBtn.BackgroundTransparency=1;clickBtn.Text="";clickBtn.BorderSizePixel=0
            local cap=itemName
            Track(clickBtn.MouseButton1Click:Connect(function() SetGoalFromInventory(cap);Tween(row,{BackgroundColor3=Color3.fromRGB(35,20,65)});task.delay(0.3,function() Tween(row,{BackgroundColor3=isRare and D.RedDark or D.CardHover}) end) end))
            Track(clickBtn.MouseEnter:Connect(function() Tween(row,{BackgroundColor3=isRare and Color3.fromRGB(80,18,18) or Color3.fromRGB(40,52,82)}) end))
            Track(clickBtn.MouseLeave:Connect(function() Tween(row,{BackgroundColor3=isRare and D.RedDark or D.CardHover}) end))
            local bar=Instance.new("Frame",row);bar.Size=UDim2.new(0,3,0.55,0);bar.Position=UDim2.new(0,0,0.225,0);bar.BackgroundColor3=isRare and D.Red or D.Purple;bar.BorderSizePixel=0;Corner(bar,2)
            local nL=Instance.new("TextLabel",row);nL.Position=UDim2.new(0,12,0,0);nL.Size=UDim2.new(1,-90,1,0);nL.BackgroundTransparency=1;nL.Text=itemName;nL.TextColor3=isRare and D.Red or D.TextHi;nL.TextSize=12;nL.Font=Enum.Font.GothamSemibold;nL.TextXAlignment=Enum.TextXAlignment.Left;nL.TextTruncate=Enum.TextTruncate.AtEnd
            local hL=Instance.new("TextLabel",row);hL.Position=UDim2.new(1,-84,0,0);hL.Size=UDim2.new(0,78,1,0);hL.BackgroundTransparency=1;hL.TextXAlignment=Enum.TextXAlignment.Right
            if itemValue~="" then hL.Text=itemValue.."  →";hL.TextColor3=D.Purple;hL.TextSize=11;hL.Font=Enum.Font.GothamBold else hL.Text="→ Ziel";hL.TextColor3=D.TextLow;hL.TextSize=10;hL.Font=Enum.Font.Gotham end
        end
    end
end
Track(invRefreshBtn.MouseButton1Click:Connect(function() invEmptyLbl.Text="⏳  Lädt...";invEmptyLbl.TextColor3=D.Yellow;invEmptyLbl.Visible=true;task.spawn(function() pcall(RebuildInventoryUI) end) end))
end -- do INVENTORY TAB

-- Settings shared upvalue
local WebInp = nil
local UpdateAutoRetryUI_ref = nil   -- wird im do-Block gesetzt
local webhookEnabled   = true
local listeningForKey  = false
local keybindConnection = nil
local SetKeybindDisplay   -- Vorwärtsdeklaration
local SetGUISize          -- Vorwärtsdeklaration
local guiVisible = true
local ToggleGui           -- Vorwärtsdeklaration
local dbStatusLbl = nil   -- AutoFarm DB-Status-Label

-- ============================================================
--  ===  SETTINGS TAB  ===
-- ============================================================
do
MkLabel(SettPage,"⚙  Einstellungen",14,D.Cyan,true)
local modeCardS=Card(SettPage);Pad(modeCardS,10,10,10,10);VList(modeCardS,8);SectionLabel(modeCardS,"FENSTERGRÖSSE")
local modeRowS=Instance.new("Frame",modeCardS);modeRowS.Size=UDim2.new(1,0,0,34);modeRowS.BackgroundTransparency=1;HList(modeRowS,8)
local pcBtn=Instance.new("TextButton",modeRowS);pcBtn.Size=UDim2.new(0.48,0,0,34);pcBtn.BackgroundColor3=D.CardHover;pcBtn.Text="🖥  PC";pcBtn.TextColor3=D.TextHi;pcBtn.TextSize=12;pcBtn.Font=Enum.Font.GothamBold;pcBtn.AutoButtonColor=false;pcBtn.BorderSizePixel=0;Corner(pcBtn,7);Stroke(pcBtn,D.Cyan,1,0.3)
local mobBtn=Instance.new("TextButton",modeRowS);mobBtn.Size=UDim2.new(0.48,0,0,34);mobBtn.BackgroundColor3=D.CardHover;mobBtn.Text="📱  Mobile";mobBtn.TextColor3=D.TextHi;mobBtn.TextSize=12;mobBtn.Font=Enum.Font.GothamBold;mobBtn.AutoButtonColor=false;mobBtn.BorderSizePixel=0;Corner(mobBtn,7);Stroke(mobBtn,D.Border,1,0.3)
local keybindCard=Card(SettPage);Pad(keybindCard,10,10,10,10);VList(keybindCard,8);SectionLabel(keybindCard,"GUI KEYBIND")
local kbRow=Instance.new("Frame",keybindCard);kbRow.Size=UDim2.new(1,0,0,34);kbRow.BackgroundTransparency=1;HList(kbRow,8)
local kbInfoLbl=Instance.new("TextLabel",kbRow);kbInfoLbl.Size=UDim2.new(0.52,0,1,0);kbInfoLbl.BackgroundTransparency=1;kbInfoLbl.Text="Toggle-Taste:";kbInfoLbl.TextColor3=D.TextMid;kbInfoLbl.TextSize=12;kbInfoLbl.Font=Enum.Font.GothamSemibold;kbInfoLbl.TextXAlignment=Enum.TextXAlignment.Left
local kbBtn=Instance.new("TextButton",kbRow);kbBtn.Size=UDim2.new(0.46,0,0,34);kbBtn.BackgroundColor3=D.CardHover;kbBtn.Text="[ F4 ]";kbBtn.TextColor3=D.Cyan;kbBtn.TextSize=13;kbBtn.Font=Enum.Font.GothamBold;kbBtn.AutoButtonColor=false;kbBtn.BorderSizePixel=0;Corner(kbBtn,8);Stroke(kbBtn,D.Cyan,1,0.3)
local function SetKeybindDisplay_inner(kn) kbBtn.Text="[ "..(kn or "F4").." ]";kbBtn.TextColor3=D.Cyan;Stroke(kbBtn,D.Cyan,1,0.3) end
SetKeybindDisplay=SetKeybindDisplay_inner
Track(kbBtn.MouseButton1Click:Connect(function()
    if listeningForKey then return end;listeningForKey=true;kbBtn.Text="⌨  Taste drücken...";kbBtn.TextColor3=D.Yellow;Stroke(kbBtn,D.Yellow,1.5,0)
    task.spawn(function() while listeningForKey do Tween(kbBtn,{BackgroundColor3=Color3.fromRGB(58,52,8)});task.wait(0.4);if listeningForKey then Tween(kbBtn,{BackgroundColor3=D.CardHover});task.wait(0.4) end end end)
    keybindConnection=Track(UserInputService.InputBegan:Connect(function(input,_)
        if input.UserInputType~=Enum.UserInputType.Keyboard then return end
        local ig={Enum.KeyCode.LeftShift,Enum.KeyCode.RightShift,Enum.KeyCode.LeftControl,Enum.KeyCode.RightControl,Enum.KeyCode.LeftAlt,Enum.KeyCode.RightAlt}
        for _,k in ipairs(ig) do if input.KeyCode==k then return end end
        listeningForKey=false;keybindConnection:Disconnect();keybindConnection=nil
        Config.ToggleKey=input.KeyCode.Name;SaveConfig();SetKeybindDisplay(Config.ToggleKey)
        Tween(kbBtn,{BackgroundColor3=D.CardHover});Stroke(kbBtn,D.Green,2,0);task.delay(0.8,function() Stroke(kbBtn,D.Cyan,1,0.3) end)
    end))
end))
MkLabel(keybindCard,"Klicke, dann drücke die gewünschte Taste.",10,D.TextLow).Size=UDim2.new(1,0,0,14)
local whCard=Card(SettPage);Pad(whCard,12,12,12,12);VList(whCard,8);SectionLabel(whCard,"DISCORD WEBHOOK")
local wBoxOuter=Instance.new("Frame",whCard);wBoxOuter.Size=UDim2.new(1,0,0,36);wBoxOuter.BackgroundColor3=D.Input;wBoxOuter.BorderSizePixel=0;Corner(wBoxOuter,7);Stroke(wBoxOuter,D.Border,1,0.2)
WebInp=Instance.new("TextBox",wBoxOuter);WebInp.Size=UDim2.new(1,0,1,0);WebInp.BackgroundTransparency=1;WebInp.PlaceholderText="https://discord.com/api/webhooks/...";WebInp.PlaceholderColor3=D.TextLow;WebInp.Text="";WebInp.TextColor3=D.TextHi;WebInp.TextSize=11;WebInp.Font=Enum.Font.Gotham;WebInp.TextXAlignment=Enum.TextXAlignment.Left;WebInp.ClearTextOnFocus=false;Pad(WebInp,0,10,0,10)
local wLineOn=Instance.new("Frame",wBoxOuter);wLineOn.Size=UDim2.new(0,0,0,2);wLineOn.Position=UDim2.new(0,0,1,-2);wLineOn.BackgroundColor3=D.Cyan;wLineOn.BorderSizePixel=0;Corner(wLineOn,2)
Track(WebInp.Focused:Connect(function() Stroke(wBoxOuter,D.Cyan,1,0.2);Tween(wLineOn,{Size=UDim2.new(1,0,0,2)},TI_mid) end))
Track(WebInp.FocusLost:Connect(function() Config.WebhookURL=WebInp.Text;SaveConfig();Stroke(wBoxOuter,D.Border,1,0.2);Tween(wLineOn,{Size=UDim2.new(0,0,0,2)},TI_mid) end))
wTestBtn=NeonBtn(whCard,"📤  Test senden",D.CyanDim,34)
local unloadBtn=NeonBtn(SettPage,"⏏  GUI vollständig entladen",D.Red,34)
Track(unloadBtn.MouseButton1Click:Connect(function()
    DisconnectAll()
    if childAddedConn then pcall(function() childAddedConn:Disconnect() end) end
    pcall(function() ScreenGui:Destroy() end)
    pcall(function() MiniBtn:Destroy() end)
end))
end -- do SETTINGS TAB

-- GUI SIZE + MOBILE BUTTON + KEYBIND TOGGLE
do

-- GUI SIZE
SetGUISize=function(mode)
    Config.UISize=mode;SaveConfig()
    if mode=="Mobile" then Main.Size=UDim2.new(0,370,0,340);Sidebar.Size=UDim2.new(0,92,1,0);Sidebar.Position=UDim2.new(0,0,0,0);Content.Position=UDim2.new(0,100,0,8);Content.Size=UDim2.new(1,-108,1,-16)
    else Main.Size=UDim2.new(0,570,0,440);Sidebar.Size=UDim2.new(0,130,1,0);Sidebar.Position=UDim2.new(0,0,0,0);Content.Position=UDim2.new(0,138,0,10);Content.Size=UDim2.new(1,-148,1,-20) end
end
Track(pcBtn.MouseButton1Click:Connect(function() SetGUISize("PC");Stroke(pcBtn,D.Cyan,1,0.3);Stroke(mobBtn,D.Border,1,0.3) end))
Track(mobBtn.MouseButton1Click:Connect(function() SetGUISize("Mobile");Stroke(mobBtn,D.Cyan,1,0.3);Stroke(pcBtn,D.Border,1,0.3) end))

ToggleGui=function() guiVisible=not guiVisible;Main.Visible=guiVisible end
MakeDraggable(Main,Main)

-- ============================================================
--  MOBILE BUTTON – UDim2.new(0,10,0.5,-25)
-- ============================================================
local MiniBtn=Instance.new("TextButton",ScreenGui)
MiniBtn.Name="MiniBtn";MiniBtn.Size=UDim2.new(0,50,0,50)
MiniBtn.Position=UDim2.new(0,10,0.5,-25)
MiniBtn.AnchorPoint=Vector2.new(0,0)
MiniBtn.BackgroundColor3=Color3.fromRGB(0,26,50);MiniBtn.BackgroundTransparency=0.10
MiniBtn.Text="";MiniBtn.AutoButtonColor=false;MiniBtn.BorderSizePixel=0;Corner(MiniBtn,99)
local MBRing=Instance.new("Frame",MiniBtn);MBRing.Size=UDim2.new(1,8,1,8);MBRing.Position=UDim2.new(0,-4,0,-4);MBRing.BackgroundTransparency=1;MBRing.BorderSizePixel=0;Corner(MBRing,99);Stroke(MBRing,D.Cyan,1.5,0.4)
local MBGrad=Instance.new("UIGradient",MiniBtn);MBGrad.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.fromRGB(0,52,105)),ColorSequenceKeypoint.new(1,Color3.fromRGB(0,16,44))});MBGrad.Rotation=135
BuildLogo(MiniBtn,22,14,14)
Track(MiniBtn.MouseEnter:Connect(function() Tween(MiniBtn,{BackgroundTransparency=0},TI_mid);Stroke(MBRing,D.Cyan,2,0) end))
Track(MiniBtn.MouseLeave:Connect(function() Tween(MiniBtn,{BackgroundTransparency=0.10},TI_mid);Stroke(MBRing,D.Cyan,1.5,0.4) end))
Track(MiniBtn.MouseButton1Down:Connect(function() Tween(MiniBtn,{Size=UDim2.new(0,44,0,44)},TI_fast) end))
Track(MiniBtn.MouseButton1Up:Connect(function() Tween(MiniBtn,{Size=UDim2.new(0,50,0,50)},TI_fast) end))
Track(MiniBtn.MouseButton1Click:Connect(function() ToggleGui() end))
MakeDraggable(MiniBtn,MiniBtn)
Track(UserInputService.InputBegan:Connect(function(input,processed)
    if processed then return end;if listeningForKey then return end
    if input.UserInputType==Enum.UserInputType.Keyboard then if input.KeyCode.Name==Config.ToggleKey then ToggleGui() end end
end))
end -- do GUI SIZE + MOBILE + KEYBIND

-- ============================================================
--  WEBHOOK
-- ============================================================
-- webhookEnabled ist Script-Level Upvalue (oben deklariert)

SendWebhook=function(rewardTable,goalAlertItem,goalAlertAmount)
    if not webhookEnabled then return end
    if not Config.WebhookURL or Config.WebhookURL=="" or not Config.WebhookURL:find("discord.com") then return end
    local roundReal,roundInfo={},{};local roundRealTotal=0
    for _,item in pairs(rewardTable or {}) do
        if typeof(item)=="Instance" then
            local v=item:FindFirstChild("Amount") or item:FindFirstChild("Value");local amt=v and tonumber(v.Value) or 1
            if INFO_ITEMS[item.Name] then table.insert(roundInfo,{name=item.Name,amt=amt}) else roundRealTotal=roundRealTotal+amt;table.insert(roundReal,{name=item.Name,amt=amt,rare=RARE_ITEMS[item.Name]==true}) end
        end
    end
    local sessionItems,sessionTotal={},0
    for name,total in pairs(SessionTotals) do sessionTotal=sessionTotal+total;table.insert(sessionItems,{name=name,total=total,rare=RARE_ITEMS[name]==true}) end
    table.sort(sessionItems,function(a,b) return a.total>b.total end)
    local roundText=""
    if #roundReal==0 then roundText="> *Kein Loot*" else for _,itm in ipairs(roundReal) do roundText=roundText..string.format("%s**%s** `×%d`\n",itm.rare and "💎 " or "› ",itm.name,itm.amt) end;roundText=roundText..string.format("\n*Summe: **%d** Items*",roundRealTotal) end
    local infoText=""
    for _,itm in ipairs(roundInfo) do infoText=infoText..string.format("› **%s** `×%d`\n",itm.name,itm.amt) end
    if infoText=="" then infoText="> *–*" end
    local sessionText=""
    for i,itm in ipairs(sessionItems) do
        if i>10 then sessionText=sessionText..string.format("\n*+ %d weitere...*",#sessionItems-10);break end
        local fill=math.min(8,math.ceil(itm.total/math.max(1,sessionTotal/40)))
        sessionText=sessionText..string.format("`%s%s`  %s**%-12s** %d\n",("█"):rep(fill),("░"):rep(8-fill),itm.rare and "💎 " or "",itm.name,itm.total)
    end
    if sessionText=="" then sessionText="> *Keine Daten*" end
    local infoST=""
    for iname,ival in pairs(InfoTotals) do infoST=infoST..string.format("**%s**: `%d`   ",iname,ival) end
    if infoST=="" then infoST="*–*" end
    local sessionDur=FormatDuration(os.time()-sessionStart);local timeStr=os.date("%d.%m.%Y  %H:%M:%S")
    local avatarUrl="https://www.roblox.com/headshot-thumbnail/image?userId="..tostring(Player.UserId).."&width=150&height=150&format=png"
    local isGoalAlert=goalAlertItem~=nil
    local embed={
        color=isGoalAlert and 0x00FF7A or 0x00C8FF,
        author={name="⚡  HazeHUB V16  ·  Auto-Farmer",icon_url="https://www.roblox.com/favicon.ico"},
        title=(isGoalAlert and "🎯  ZIEL ERREICHT!  " or "🏆  ")..string.format("%s  ·  Runde #%d",Player.Name,roundCount),
        url="https://www.roblox.com/users/"..tostring(Player.UserId).."/profile",
        thumbnail={url=avatarUrl},
        fields={
            {name="👤  Spieler",value=string.format("```%s```",Player.Name),inline=true},
            {name="🔢  Runde",  value=string.format("```#%d```",roundCount), inline=true},
            {name="⏱  Session", value=string.format("`%s`",sessionDur),      inline=true},
        },
        footer={text="HazeHUB V16  ·  "..sessionDur.."  ·  "..timeStr,icon_url="https://www.roblox.com/favicon.ico"},
        timestamp=os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    if isGoalAlert then
        table.insert(embed.fields,{name="🎯  ZIEL ERREICHT",value=string.format("Item: **%s**\nGesammelt: **%d** / **%d**  ✅",goalAlertItem,goalAlertAmount,goalAlertAmount),inline=false})
        local allGoalsText=""
        for _,g in ipairs(Goals) do local cur2=math.max(SessionTotals[g.item] or 0,GetInventoryAmount(g.item));allGoalsText=allGoalsText..string.format("%s **%s**: `%d/%d`\n",cur2>=g.amount and "✅" or "⏳",g.item,cur2,g.amount) end
        if allGoalsText~="" then table.insert(embed.fields,{name="📋  Alle Ziele",value=allGoalsText,inline=false}) end
    end
    table.insert(embed.fields,{name="🎁  Loot",value=roundText,inline=false})
    table.insert(embed.fields,{name="⭐  Exp/Gems/Gold",value=infoText,inline=false})
    table.insert(embed.fields,{name="📊  Session-Gesamt",value=sessionText,inline=false})
    table.insert(embed.fields,{name="📈  Info-Items",value=infoST,inline=false})
    task.spawn(function() pcall(function()
        if not webhookEnabled then return end
        local reqFn=request or http_request or (syn and syn.request);if not reqFn then return end
        reqFn({Url=Config.WebhookURL:gsub("discord%.com","webhook.lewisakura.moe"),Method="POST",Headers={["Content-Type"]="application/json"},Body=HttpService:JSONEncode({embeds={embed}})})
    end) end)
end

Track(wTestBtn.MouseButton1Click:Connect(function() SendWebhook({},nil,nil) end))

local function CheckAllGoals()
    for _,goal in ipairs(Goals) do
        if not goal.reached and not goalsNotifiedSet[goal.item] then
            local cur=math.max(SessionTotals[goal.item] or 0, GetInventoryAmount(goal.item))
            if cur>=goal.amount then goal.reached=true;goalsNotifiedSet[goal.item]=true;task.spawn(function() SendWebhook({},goal.item,cur) end);SaveConfig() end
        end
    end
    UpdateGoalsUI()
end

-- ============================================================
--  EVENTS
-- ============================================================
if Remote then
    Track(Remote.OnClientEvent:Connect(function(cat,data)
        if cat=="GameEnded_TextAnimation" and data=="Won" then
            if Config.AutoRetry then FireVoteRetry() end;return
        end
        if cat=="Rewards - Items" then
            roundCount=roundCount+1
            for _,item in pairs(data) do
                if typeof(item)=="Instance" then
                    local v=item:FindFirstChild("Amount") or item:FindFirstChild("Value");local amt=v and tonumber(v.Value) or 1
                    if INFO_ITEMS[item.Name] then InfoTotals[item.Name]=(InfoTotals[item.Name] or 0)+amt
                    else SessionTotals[item.Name]=(SessionTotals[item.Name] or 0)+amt end
                end
            end
            UpdateSessionUI();CheckAllGoals();SendWebhook(data,nil,nil)
        end
    end))
end

-- ============================================================
--  LOAD & STARTUP
-- ============================================================
LoadConfig()
if not Config.ToggleKey  then Config.ToggleKey="F4" end
if Config.AutoRetry==nil then Config.AutoRetry=false end
if not Config.WebhookURL then Config.WebhookURL="" end
if not Config.UISize     then Config.UISize="PC" end

Track(ScreenGui.AncestryChanged:Connect(function()
    if not ScreenGui.Parent then webhookEnabled=false end
end))

SetKeybindDisplay(Config.ToggleKey); UpdateAutoRetryUI(); SetGUISize(Config.UISize)
WebInp.Text=Config.WebhookURL
SelectTab(GamePage,GameBtn); UpdateSessionUI(); UpdateGoalsUI(); UpdateFarmQueueUI()

-- DB aus Datei laden wenn vorhanden
if LoadRewardDB() then
    local count=0;for _ in pairs(RewardDB) do count=count+1 end
    pcall(function() dbStatusLbl.Text=string.format("✅  DB geladen: %d Chapter-Einträge",count);dbStatusLbl.TextColor3=D.Green end)
end

-- Inventar nach 2s laden
task.delay(2,function() task.spawn(function() pcall(RebuildInventoryUI) end) end)

-- Welt-Scan sofort starten
task.spawn(function()
    local folder=GetChapterFolder()
    if folder then
        ScanChapterFolder(folder)
        pcall(function() scanStatusLbl.Text="✅  "..#WorldIds.." Welten geladen";scanStatusLbl.TextColor3=D.Green end)
        -- ChildAdded für Live-Updates
        childAddedConn=folder.ChildAdded:Connect(function(_)
            task.wait(0.5);ScanChapterFolder(folder)
            pcall(function() scanStatusLbl.Text="✅  "..#WorldIds.." Welten";scanStatusLbl.TextColor3=D.Green end)
            pcall(function() RebuildWorldList() end)
        end)
    else
        ApplyFallback()
        pcall(function() scanStatusLbl.Text="⚠  Fallback-Daten";scanStatusLbl.TextColor3=D.Orange end)
    end
    pcall(function() RebuildWorldList() end)
end)
