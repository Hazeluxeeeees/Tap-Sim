-- ╔══════════════════════════════════════════════════════════╗
--  HazeHUB – autofarm.lua  v1.0.0
--  GitHub: Hazeluxeeeees/HazeHub-Modules
--  Wird vom Hauptskript via loadstring geladen
--  Greift auf _G.HazeShared zu
-- ╚══════════════════════════════════════════════════════════╝

local VERSION = "1.0.0"

-- ============================================================
--  WARTEN BIS SHARED-TABLE BEREIT IST  (max. 10s)
-- ============================================================
local waited = 0
while not (_G.HazeShared and _G.HazeShared.Container and _G.HazeShared.SetModuleLoaded) do
    task.wait(0.3); waited = waited + 0.3
    if waited >= 10 then
        warn("[HazeAF] _G.HazeShared nicht bereit nach 10s – Abbruch.")
        return
    end
end

-- ============================================================
--  SHARED ALIASE
-- ============================================================
local HS  = _G.HazeShared
local CFG = HS.Config      -- Haze.Config (live-Referenz)
local ST  = HS.State       -- Haze.S      (live-Referenz)
local D   = HS.D
local TF  = HS.TF; local TM=HS.TM; local Tw=HS.Tw
local Svc = HS.Svc

-- UI-Factory (identisch mit Hauptskript)
local Card    = HS.Card;    local NeonBtn = HS.NeonBtn
local MkLbl   = HS.MkLbl;  local SecLbl  = HS.SecLbl
local MkInput = HS.MkInput; local VList   = HS.VList
local HList   = HS.HList;   local Pad     = HS.Pad
local Corner  = HS.Corner;  local Stroke  = HS.Stroke

-- Funktionen aus Hauptskript
local PR                 = HS.PR
local FireCreateAndStart = HS.FireCreateAndStart
local FireVoteRetry      = HS.FireVoteRetry
local GetInvAmt          = HS.GetInvAmt
local IsInLobby          = HS.IsInLobby
local ClickBackToLobby   = HS.ClickBackToLobby
local SaveConfig         = HS.SaveConfig
local SendWebhook        = HS.SendWebhook

-- Container (Frame im Game-Tab)
local Container = HS.Container

-- ============================================================
--  AUTOFARM STATE
-- ============================================================
local AF = {
    Queue    = {},   -- { {item, amount, done}, ... }
    Active   = false,
    Running  = true,
    RewardDB = {},
    UI       = { Lbl={}, Fr={} },
}

local DB_FILE     = "HazeHUB/HazeHUB_RewardDB.json"
local QUEUE_KEY   = "SavedQueue"   -- in CFG gespeichert

-- ============================================================
--  QUEUE PERSISTENZ
-- ============================================================
local function SaveQueue()
    CFG[QUEUE_KEY] = {}
    for _,q in ipairs(AF.Queue) do
        table.insert(CFG[QUEUE_KEY], {item=q.item, amount=q.amount, done=q.done})
    end
    SaveConfig()
end

local function LoadQueue()
    if not CFG[QUEUE_KEY] then return end
    AF.Queue = {}
    for _,q in ipairs(CFG[QUEUE_KEY]) do
        if q.item and tonumber(q.amount) then
            table.insert(AF.Queue, {item=q.item, amount=tonumber(q.amount), done=q.done==true})
        end
    end
end

-- ============================================================
--  REWARD DB  SAVE / LOAD
-- ============================================================
local function SaveDB()
    if writefile then
        pcall(function()
            writefile(DB_FILE, Svc.Http:JSONEncode(AF.RewardDB))
        end)
    end
end

local function LoadDB()
    if not (isfile and isfile(DB_FILE)) then return false end
    local ok,data = pcall(function()
        return Svc.Http:JSONDecode(readfile(DB_FILE))
    end)
    if not ok or not data then return false end
    AF.RewardDB = data; return true
end

-- ============================================================
--  REWARD DB SCAN
-- ============================================================
local function ReadItemsList()
    local itemsList
    local deadline = os.clock() + 5
    while os.clock() < deadline and AF.Running do
        pcall(function()
            itemsList = Svc.Player.PlayerGui
                .PlayRoom.Main.GameStage.Main.Base.Rewards.ItemsList
        end)
        if itemsList then break end
        task.wait(0.25)
    end
    if not itemsList then return nil end

    local items = {}
    for _,info in ipairs(itemsList:GetChildren()) do
        pcall(function()
            local inf = info:FindFirstChild("Info"); if not inf then return end
            local nameV = inf:FindFirstChild("ItemNames")
            local rateV = inf:FindFirstChild("DropRate")
            local amtV  = inf:FindFirstChild("DropAmount")
            local iname = nameV and tostring(nameV.Value) or info.Name
            local rate  = rateV and tonumber(rateV.Value) or 0
            local amt   = amtV  and tonumber(amtV.Value)  or 1
            if iname and iname~="" then
                items[iname] = {dropRate=rate, dropAmount=amt}
            end
        end)
    end
    return items
end

local function ScanAllRewards(onProgress)
    if not HS.IsScanDone() then
        pcall(function() onProgress("⚠ Zuerst Welten im Game-Tab laden!") end); return
    end
    AF.RewardDB = {}
    local WorldData = HS.GetWorldData()
    local WorldIds  = HS.GetWorldIds()
    local total, scanned, skipped = 0, 0, 0

    for _,wid in ipairs(WorldIds) do
        local wd=WorldData[wid] or {}
        total = total + #(wd.story or {}) + #(wd.ranger or {})
    end

    for _,wid in ipairs(WorldIds) do
        if not AF.Running then break end
        local wd=WorldData[wid] or {}
        local chapters = {}
        for _,cid in ipairs(wd.story  or {}) do table.insert(chapters,{id=cid,mode="Story"})  end
        for _,cid in ipairs(wd.ranger or {}) do table.insert(chapters,{id=cid,mode="Ranger"}) end

        for _,chap in ipairs(chapters) do
            if not AF.Running then break end
            scanned = scanned + 1
            pcall(function() onProgress(string.format("⏳ %d/%d  –  %s",scanned,total,chap.id)) end)

            -- Chapter-Ansicht wechseln damit ItemsList aktualisiert
            pcall(function()
                if chap.mode=="Story"  then PR("Change-World",{World=wid})
                elseif chap.mode=="Ranger" then PR("Change-Mode",{KeepWorld=wid,Mode="Ranger Stage"}) end
                PR("Change-Chapter",{Chapter=chap.id})
            end)
            task.wait(1.5)   -- ItemsList laden lassen

            local items = ReadItemsList()
            if items and next(items) then
                AF.RewardDB[chap.id] = {world=wid, mode=chap.mode, items=items}
            else
                skipped = skipped + 1
                pcall(function() onProgress(string.format("⚠ Timeout: %s (übersprungen)",chap.id)) end)
            end
        end
    end

    SaveDB()
    pcall(function()
        onProgress(string.format("✅ Scan fertig: %d/%d Chapter  ·  %d Timeouts",
            scanned-skipped, total, skipped))
    end)
end

local function FindBestChapter(itemName)
    local best,bestRate,bestWorld,bestMode = nil,-1,nil,nil
    for chapId,data in pairs(AF.RewardDB) do
        if data.items and data.items[itemName] then
            local r = data.items[itemName].dropRate or 0
            if r > bestRate then
                bestRate=r; best=chapId; bestWorld=data.world; bestMode=data.mode
            end
        end
    end
    return best, bestWorld, bestMode, bestRate
end

-- ============================================================
--  UI HELPER
-- ============================================================
local function SetStatus(text, color)
    pcall(function()
        AF.UI.Lbl.Status.Text  = text
        AF.UI.Lbl.Status.TextColor3 = color or D.TextMid
    end)
end

local function UpdateQueueUI()
    if not AF.UI.Fr.List then return end
    for _,v in pairs(AF.UI.Fr.List:GetChildren()) do
        if v:IsA("Frame") then v:Destroy() end
    end
    if AF.UI.Lbl.Empty then
        AF.UI.Lbl.Empty.Visible = (#AF.Queue==0)
    end

    local function NextItem()
        for _,q in ipairs(AF.Queue) do if not q.done then return q end end
        return nil
    end

    for i,q in ipairs(AF.Queue) do
        local inv    = GetInvAmt(q.item)
        local pct    = math.min(1, inv / math.max(1,q.amount))
        local isNext = (not q.done) and (NextItem()==q)

        local row=Instance.new("Frame",AF.UI.Fr.List)
        row.Size=UDim2.new(1,0,0,42); row.BorderSizePixel=0; Corner(row,8)
        if q.done then
            row.BackgroundColor3=D.GreenDark; Stroke(row,D.GreenBright,1.5,0)
        elseif isNext then
            row.BackgroundColor3=Color3.fromRGB(0,30,55); Stroke(row,D.Cyan,1.5,0)
        else
            row.BackgroundColor3=D.Card; Stroke(row,D.Border,1,0.4)
        end

        local barColor = q.done and D.GreenBright or (isNext and D.Cyan or D.Purple)
        local bar=Instance.new("Frame",row); bar.Size=UDim2.new(0,3,0.65,0); bar.Position=UDim2.new(0,0,0.175,0); bar.BackgroundColor3=barColor; bar.BorderSizePixel=0; Corner(bar,2)
        local pgBg=Instance.new("Frame",row); pgBg.Size=UDim2.new(1,-52,0,3); pgBg.Position=UDim2.new(0,8,1,-6); pgBg.BackgroundColor3=Color3.fromRGB(28,38,62); pgBg.BorderSizePixel=0; Corner(pgBg,2)
        local pgF=Instance.new("Frame",pgBg); pgF.Size=UDim2.new(pct,0,1,0); pgF.BackgroundColor3=barColor; pgF.BorderSizePixel=0; Corner(pgF,2)

        local nL=Instance.new("TextLabel",row); nL.Position=UDim2.new(0,12,0,4); nL.Size=UDim2.new(1,-52,0.5,-2); nL.BackgroundTransparency=1
        nL.Text=(isNext and "▶ " or "")..(q.done and "✅ " or "")..q.item
        nL.TextColor3=q.done and D.GreenBright or (isNext and D.Cyan or D.TextHi)
        nL.TextSize=11; nL.Font=Enum.Font.GothamBold; nL.TextXAlignment=Enum.TextXAlignment.Left; nL.TextTruncate=Enum.TextTruncate.AtEnd

        local pL=Instance.new("TextLabel",row); pL.Position=UDim2.new(0,12,0.5,0); pL.Size=UDim2.new(1,-52,0.5,-4); pL.BackgroundTransparency=1
        pL.Text=inv.." / "..q.amount.."  ("..math.floor(pct*100).."%)"
        pL.TextColor3=q.done and D.GreenBright or D.TextMid; pL.TextSize=10; pL.Font=Enum.Font.GothamSemibold; pL.TextXAlignment=Enum.TextXAlignment.Left

        local ci=i
        local xBtn=Instance.new("TextButton",row); xBtn.Size=UDim2.new(0,34,0,34); xBtn.Position=UDim2.new(1,-38,0.5,-17); xBtn.BackgroundColor3=Color3.fromRGB(50,12,12); xBtn.Text="✕"; xBtn.TextColor3=D.Red; xBtn.TextSize=13; xBtn.Font=Enum.Font.GothamBold; xBtn.AutoButtonColor=false; xBtn.BorderSizePixel=0; Corner(xBtn,7); Stroke(xBtn,D.Red,1,0.4)
        xBtn.MouseEnter:Connect(function() Tw(xBtn,{BackgroundColor3=D.RedDark}) end)
        xBtn.MouseLeave:Connect(function() Tw(xBtn,{BackgroundColor3=Color3.fromRGB(50,12,12)}) end)
        xBtn.MouseButton1Click:Connect(function()
            table.remove(AF.Queue,ci); SaveQueue(); UpdateQueueUI()
        end)
    end
end

-- ============================================================
--  FARM LOOP
-- ============================================================
local function GetNextItem()
    for _,q in ipairs(AF.Queue) do if not q.done then return q end end
    return nil
end

local function FarmLoop()
    AF.Active = true
    while AF.Running do
        local q = GetNextItem()
        if not q then
            AF.Active = false
            SetStatus("✅  Queue fertig!", D.Green); break
        end

        -- Bestes Chapter aus RewardDB suchen
        local chapId, worldId, mode, rate = FindBestChapter(q.item)

        -- Fallback: erstes verfügbares Chapter
        if not chapId then
            local ids = HS.GetWorldIds()
            if #ids>0 then
                local wd = HS.GetWorldData()[ids[1]] or {}
                if wd.story and #wd.story>0 then
                    chapId=wd.story[1]; worldId=ids[1]; mode="Story"; rate=0
                end
            end
        end

        if not chapId then
            SetStatus("⚠ Kein Chapter für '"..q.item.."' gefunden",D.Orange)
            task.wait(3); q.done=true; pcall(UpdateQueueUI); continue
        end

        SetStatus(string.format("🚀 Farm: %s → %s  (%.1f%%)",q.item,chapId,rate or 0), D.Cyan)

        -- ── REMOTE ABFOLGE: Create → Change-World → Change-Chapter → Submit → Start ──
        FireCreateAndStart(worldId, mode, chapId)

        -- Warten bis Ziel erreicht  (max 10 Minuten)
        local deadline = os.time() + 600
        local goalMet  = false

        while AF.Running and os.time()<deadline do
            task.wait(5)
            local cur = GetInvAmt(q.item)
            SetStatus(string.format("📊 %s:  %d / %d  (%.0f%%)",
                q.item, cur, q.amount, math.min(100, cur/math.max(1,q.amount)*100)), D.Cyan)
            pcall(UpdateQueueUI)
            pcall(function() HS.UpdateGoalsUI() end)
            if cur >= q.amount then goalMet=true; break end
        end

        if goalMet then
            q.done = true; SaveQueue(); pcall(UpdateQueueUI)
            local cur = GetInvAmt(q.item)
            task.spawn(function() pcall(function() SendWebhook({},q.item,cur) end) end)

            -- ── LOBBY-RÜCKKEHR ──────────────────────────────────────
            SetStatus("🏠 Ziel erreicht – Back To Lobby...", D.Yellow)
            task.wait(2)

            -- Physischer Klick auf "Back To Lobby" Button
            ClickBackToLobby()

            -- Warten bis Lobby erkannt
            local lw = 0
            while AF.Running and not IsInLobby() and lw < 15 do
                task.wait(1); lw=lw+1
            end
            task.wait(2)   -- kurz in Lobby einrasten lassen
        else
            -- Timeout – nächstes Item versuchen
            SetStatus("⚠ Timeout – nächstes Item...", D.Orange)
            task.wait(2)
        end
    end
    AF.Active = false
end

-- Lobby-Erkennung: Auto-Start nach Rückkehr
task.spawn(function()
    local wasInGame = false
    while AF.Running do
        task.wait(3)
        local inLobby = IsInLobby()
        if wasInGame and inLobby then
            wasInGame = false
            if #AF.Queue>0 and GetNextItem() and not AF.Active then
                task.wait(3)
                if AF.Running then task.spawn(FarmLoop) end
            end
        end
        if not inLobby then wasInGame=true end
    end
end)

-- Live-Update Queue alle 5s
task.spawn(function()
    while AF.Running do task.wait(5); pcall(UpdateQueueUI) end
end)

-- ============================================================
--  STOP  (wird in HazeShared registriert)
-- ============================================================
local function StopFarm()
    AF.Active = false; AF.Running = false
    SetStatus("⏹  Auto-Farm gestoppt", D.TextMid)
end
HS.StopFarm = StopFarm

-- ============================================================
--  GUI AUFBAUEN  →  direkt in Container injizieren
-- ============================================================

-- Status-Card
local sCard = Card(Container, 36); Pad(sCard,6,10,6,10)
AF.UI.Lbl.Status = Instance.new("TextLabel",sCard)
AF.UI.Lbl.Status.Size=UDim2.new(1,0,1,0); AF.UI.Lbl.Status.BackgroundTransparency=1
AF.UI.Lbl.Status.Text="⏹  Auto-Farm gestoppt"; AF.UI.Lbl.Status.TextColor3=D.TextMid
AF.UI.Lbl.Status.TextSize=11; AF.UI.Lbl.Status.Font=Enum.Font.GothamSemibold
AF.UI.Lbl.Status.TextXAlignment=Enum.TextXAlignment.Left

-- Reward-DB Karte
local dbCard = Card(Container); Pad(dbCard,10,10,10,10); VList(dbCard,8)
SecLbl(dbCard,"🗃  REWARD-DATENBANK")
AF.UI.Lbl.DBStatus = MkLbl(dbCard,"Keine DB geladen. Scannen oder Datei laden.",11,D.TextLow)
AF.UI.Lbl.DBStatus.Size=UDim2.new(1,0,0,24)

local dbBtnRow=Instance.new("Frame",dbCard); dbBtnRow.Size=UDim2.new(1,0,0,30); dbBtnRow.BackgroundTransparency=1; HList(dbBtnRow,8)

local scanDbBtn=Instance.new("TextButton",dbBtnRow)
scanDbBtn.Size=UDim2.new(0.48,0,0,30); scanDbBtn.BackgroundColor3=D.CardHover
scanDbBtn.Text="🔍  Alle Rewards scannen"; scanDbBtn.TextColor3=D.Purple
scanDbBtn.TextSize=11; scanDbBtn.Font=Enum.Font.GothamBold
scanDbBtn.AutoButtonColor=false; scanDbBtn.BorderSizePixel=0; Corner(scanDbBtn,7); Stroke(scanDbBtn,D.Purple,1,0.3)

local loadDbBtn=Instance.new("TextButton",dbBtnRow)
loadDbBtn.Size=UDim2.new(0.48,0,0,30); loadDbBtn.BackgroundColor3=D.CardHover
loadDbBtn.Text="📂  DB laden"; loadDbBtn.TextColor3=D.CyanDim
loadDbBtn.TextSize=11; loadDbBtn.Font=Enum.Font.GothamBold
loadDbBtn.AutoButtonColor=false; loadDbBtn.BorderSizePixel=0; Corner(loadDbBtn,7); Stroke(loadDbBtn,D.CyanDim,1,0.3)

loadDbBtn.MouseButton1Click:Connect(function()
    if LoadDB() then
        local c=0; for _ in pairs(AF.RewardDB) do c=c+1 end
        AF.UI.Lbl.DBStatus.Text=string.format("✅  DB: %d Chapter geladen",c)
        AF.UI.Lbl.DBStatus.TextColor3=D.Green
    else
        AF.UI.Lbl.DBStatus.Text="⚠  Keine DB-Datei gefunden."
        AF.UI.Lbl.DBStatus.TextColor3=D.Orange
    end
end)

scanDbBtn.MouseButton1Click:Connect(function()
    task.spawn(function()
        ScanAllRewards(function(msg)
            pcall(function()
                AF.UI.Lbl.DBStatus.Text=msg
                AF.UI.Lbl.DBStatus.TextColor3=D.Yellow
            end)
        end)
        local c=0; for _ in pairs(AF.RewardDB) do c=c+1 end
        pcall(function()
            AF.UI.Lbl.DBStatus.Text=string.format("✅  %d Chapter gescannt",c)
            AF.UI.Lbl.DBStatus.TextColor3=D.Green
        end)
    end)
end)

-- Queue-Karte
local qCard = Card(Container); Pad(qCard,10,10,10,10); VList(qCard,8)
SecLbl(qCard,"📋  AUTO-FARM QUEUE")

local qRow=Instance.new("Frame",qCard); qRow.Size=UDim2.new(1,0,0,30); qRow.BackgroundTransparency=1; HList(qRow,5)

local qItemOuter,qItemBox = MkInput(qRow,"Item-Name..."); qItemOuter.Size=UDim2.new(0.50,0,0,30)
local qAmtOuter,qAmtBox   = MkInput(qRow,"Anzahl");       qAmtOuter.Size=UDim2.new(0.28,0,0,30)

local qAddBtn=Instance.new("TextButton",qRow)
qAddBtn.Size=UDim2.new(0.19,0,0,30); qAddBtn.BackgroundColor3=D.Green
qAddBtn.Text="+ Add"; qAddBtn.TextColor3=Color3.new(1,1,1); qAddBtn.TextSize=11
qAddBtn.Font=Enum.Font.GothamBold; qAddBtn.AutoButtonColor=false; qAddBtn.BorderSizePixel=0
Corner(qAddBtn,7); Stroke(qAddBtn,D.Green,1,0.2)
qAddBtn.MouseEnter:Connect(function() Tw(qAddBtn,{BackgroundColor3=Color3.fromRGB(0,160,80)}) end)
qAddBtn.MouseLeave:Connect(function() Tw(qAddBtn,{BackgroundColor3=D.Green}) end)

AF.UI.Fr.List = Instance.new("Frame",qCard)
AF.UI.Fr.List.Size=UDim2.new(1,0,0,0); AF.UI.Fr.List.AutomaticSize=Enum.AutomaticSize.Y
AF.UI.Fr.List.BackgroundTransparency=1; VList(AF.UI.Fr.List,4)
AF.UI.Lbl.Empty = MkLbl(AF.UI.Fr.List,"Queue leer. Item + Anzahl eintragen.",11,D.TextLow)
AF.UI.Lbl.Empty.Size=UDim2.new(1,0,0,24)

qAddBtn.MouseButton1Click:Connect(function()
    local iname=(qItemBox.Text or ""):match("^%s*(.-)%s*$")
    local iamt=tonumber(qAmtBox.Text)
    if iname=="" or not iamt or iamt<=0 then return end

    -- Auch als Session-Ziel registrieren (über Hauptskript-State)
    local found=false
    for _,g in ipairs(ST.Goals) do if g.item==iname then found=true; break end end
    if not found then
        table.insert(ST.Goals,{item=iname,amount=iamt,reached=false})
        SaveConfig()
    end

    table.insert(AF.Queue,{item=iname,amount=iamt,done=false})
    SaveQueue(); qItemBox.Text=""; qAmtBox.Text=""
    UpdateQueueUI(); pcall(function() HS.UpdateGoalsUI() end)
end)

-- Steuerungs-Buttons
local ctrlRow=Instance.new("Frame",qCard); ctrlRow.Size=UDim2.new(1,0,0,32); ctrlRow.BackgroundTransparency=1; HList(ctrlRow,8)

local startBtn=Instance.new("TextButton",ctrlRow)
startBtn.Size=UDim2.new(0.48,0,0,32); startBtn.BackgroundColor3=D.Green
startBtn.Text="▶  Start Queue"; startBtn.TextColor3=Color3.new(1,1,1)
startBtn.TextSize=12; startBtn.Font=Enum.Font.GothamBold
startBtn.AutoButtonColor=false; startBtn.BorderSizePixel=0; Corner(startBtn,8); Stroke(startBtn,D.Green,1,0.2)

local stopBtn=Instance.new("TextButton",ctrlRow)
stopBtn.Size=UDim2.new(0.48,0,0,32); stopBtn.BackgroundColor3=D.RedDark
stopBtn.Text="⏹  Stop"; stopBtn.TextColor3=D.Red
stopBtn.TextSize=12; stopBtn.Font=Enum.Font.GothamBold
stopBtn.AutoButtonColor=false; stopBtn.BorderSizePixel=0; Corner(stopBtn,8); Stroke(stopBtn,D.Red,1,0.4)

startBtn.MouseButton1Click:Connect(function()
    if not next(AF.RewardDB) then
        SetStatus("⚠ Reward-DB zuerst laden oder scannen!",D.Orange); return
    end
    if AF.Active then SetStatus("⚠ Farm läuft bereits!",D.Yellow); return end
    AF.Running=true; task.spawn(FarmLoop)
end)
stopBtn.MouseButton1Click:Connect(StopFarm)

local clearBtn=NeonBtn(qCard,"🗑  Queue leeren",D.Red,28)
clearBtn.MouseButton1Click:Connect(function()
    AF.Queue={}; SaveQueue(); UpdateQueueUI()
end)

-- ============================================================
--  STARTUP
-- ============================================================

-- Gespeicherte Queue laden
LoadQueue()

-- DB automatisch laden falls Datei existiert
if LoadDB() then
    local c=0; for _ in pairs(AF.RewardDB) do c=c+1 end
    pcall(function()
        AF.UI.Lbl.DBStatus.Text=string.format("✅  DB: %d Chapter geladen",c)
        AF.UI.Lbl.DBStatus.TextColor3=D.Green
    end)
end

-- Queue-UI initial aufbauen
UpdateQueueUI()

-- ── MODUL ERFOLGREICH GELADEN: Status im Hauptskript aktualisieren ──
_G.HazeShared.SetModuleLoaded(VERSION)

print("[HazeAF] autofarm.lua v"..VERSION.." erfolgreich geladen ✅")
