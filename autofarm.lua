-- ╔══════════════════════════════════════════════════════════╗
--  HazeHUB – autofarm.lua  (externes Modul)
--  Liegt auf GitHub, wird vom Hauptskript via loadstring geladen
--  Greift auf _G.HazeShared zu für GUI + Shared-Funktionen
-- ╚══════════════════════════════════════════════════════════╝

-- ============================================================
--  WARTEN BIS SHARED-TABLE BEREIT IST
-- ============================================================
local timeout = 10
local waited  = 0
while not _G.HazeShared or not _G.HazeShared.Container do
    task.wait(0.5); waited = waited + 0.5
    if waited >= timeout then
        warn("[HazeAF] _G.HazeShared nicht gefunden – Autofarm nicht geladen.")
        return
    end
end

-- ============================================================
--  SHARED REFERENZEN EINLESEN  (kurze Aliase)
-- ============================================================
local HS      = _G.HazeShared
local Container = HS.Container      -- Frame im Game-Tab
local Config    = HS.Config
local State     = HS.State
local D         = HS.D
local Svc       = HS.Svc

-- UI-Factory (gleiche Funktionen wie im Hauptskript)
local Card    = HS.Card
local NeonBtn = HS.NeonBtn
local MkLbl   = HS.MkLbl
local SecLbl  = HS.SecLbl
local MkInput = HS.MkInput
local VList   = HS.VList
local HList   = HS.HList
local Pad     = HS.Pad
local Corner  = HS.Corner
local Stroke  = HS.Stroke
local Tw      = HS.Tw
local TF      = HS.TF
local TM      = HS.TM

-- Hilfsfunktionen aus dem Hauptskript
local PR                 = HS.PR
local FireCreateAndStart = HS.FireCreateAndStart
local GetInvAmt          = HS.GetInvAmt
local IsInLobby          = HS.IsInLobby
local ClickBackToLobby   = HS.ClickBackToLobby
local SaveConfig         = HS.SaveConfig
local SendWebhook        = HS.SendWebhook

-- ============================================================
--  AUTOFARM STATE
-- ============================================================
local AF = {
    Queue      = Config.SavedQueue or {},  -- { {item,amount,done}, ... }
    Active     = false,
    Running    = true,
    RewardDB   = {},
    Lbl        = {},
    Fr         = {},
}

local DB_FILE = "HazeHUB/HazeHUB_RewardDB.json"

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

local function SaveQueue()
    Config.SavedQueue = {}
    for _,q in ipairs(AF.Queue) do
        table.insert(Config.SavedQueue,{item=q.item,amount=q.amount,done=q.done})
    end
    SaveConfig()
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
            if iname and iname ~= "" then
                items[iname] = {dropRate=rate, dropAmount=amt}
            end
        end)
    end
    return items
end

local function ScanAllRewards(onProgress)
    if not HS.IsScanDone() then
        pcall(function() onProgress("⚠ Bitte zuerst Welten laden!") end); return
    end
    AF.RewardDB = {}
    local WorldData = HS.GetWorldData()
    local WorldIds  = HS.GetWorldIds()
    local total, scanned, skipped = 0, 0, 0

    for _,wid in ipairs(WorldIds) do
        local wd = WorldData[wid] or {}
        total = total + #(wd.story or {}) + #(wd.ranger or {})
    end

    for _,wid in ipairs(WorldIds) do
        if not AF.Running then break end
        local wd = WorldData[wid] or {}
        local chapters = {}
        for _,cid in ipairs(wd.story  or {}) do table.insert(chapters,{id=cid,mode="Story"})  end
        for _,cid in ipairs(wd.ranger or {}) do table.insert(chapters,{id=cid,mode="Ranger"}) end

        for _,chap in ipairs(chapters) do
            if not AF.Running then break end
            scanned = scanned + 1
            pcall(function() onProgress(string.format("⏳ %d/%d – %s",scanned,total,chap.id)) end)

            pcall(function()
                if chap.mode=="Story"  then PR("Change-World",{World=wid})
                elseif chap.mode=="Ranger" then PR("Change-Mode",{KeepWorld=wid,Mode="Ranger Stage"}) end
                PR("Change-Chapter",{Chapter=chap.id})
            end)
            task.wait(1.5)

            local items = ReadItemsList()
            if items and next(items) then
                AF.RewardDB[chap.id] = {world=wid, mode=chap.mode, items=items}
            else
                skipped = skipped + 1
                pcall(function() onProgress(string.format("⚠ Timeout: %s",chap.id)) end)
            end
        end
    end

    SaveDB()
    pcall(function()
        onProgress(string.format("✅ Scan fertig: %d/%d · %d Timeouts",scanned-skipped,total,skipped))
    end)
end

local function FindBestChapter(itemName)
    local best,bestRate,bestWorld,bestMode = nil,-1,nil,nil
    for chapId,data in pairs(AF.RewardDB) do
        if data.items and data.items[itemName] then
            local r = data.items[itemName].dropRate or 0
            if r > bestRate then bestRate=r;best=chapId;bestWorld=data.world;bestMode=data.mode end
        end
    end
    return best, bestWorld, bestMode, bestRate
end

-- ============================================================
--  FARM LOOP
-- ============================================================
local function GetNextItem()
    for _,q in ipairs(AF.Queue) do if not q.done then return q end end
    return nil
end

local function SetStatus(text,color)
    pcall(function()
        if AF.Lbl.FarmStatus then
            AF.Lbl.FarmStatus.Text=text
            AF.Lbl.FarmStatus.TextColor3=color or D.TextMid
        end
    end)
end

local function UpdateQueueUI()
    if not AF.Fr.QueueList then return end
    for _,v in pairs(AF.Fr.QueueList:GetChildren()) do if v:IsA("Frame") then v:Destroy() end end
    if AF.Lbl.QueueEmpty then AF.Lbl.QueueEmpty.Visible=(#AF.Queue==0) end

    for i,q in ipairs(AF.Queue) do
        local inv  = GetInvAmt(q.item)
        local pct  = math.min(1, inv/math.max(1,q.amount))
        local isNext = (not q.done) and (GetNextItem()==q)

        local row=Instance.new("Frame",AF.Fr.QueueList)
        row.Size=UDim2.new(1,0,0,42);row.BorderSizePixel=0;Corner(row,8)
        if q.done then row.BackgroundColor3=D.GreenDark;Stroke(row,D.GreenBright,1.5,0)
        elseif isNext then row.BackgroundColor3=Color3.fromRGB(0,30,55);Stroke(row,D.Cyan,1.5,0)
        else row.BackgroundColor3=D.Card;Stroke(row,D.Border,1,0.4) end

        local bar=Instance.new("Frame",row);bar.Size=UDim2.new(0,3,0.65,0);bar.Position=UDim2.new(0,0,0.175,0);bar.BackgroundColor3=q.done and D.GreenBright or (isNext and D.Cyan or D.Purple);bar.BorderSizePixel=0;Corner(bar,2)
        local pgBg=Instance.new("Frame",row);pgBg.Size=UDim2.new(1,-52,0,3);pgBg.Position=UDim2.new(0,8,1,-6);pgBg.BackgroundColor3=Color3.fromRGB(28,38,62);pgBg.BorderSizePixel=0;Corner(pgBg,2)
        local pgF=Instance.new("Frame",pgBg);pgF.Size=UDim2.new(pct,0,1,0);pgF.BackgroundColor3=q.done and D.GreenBright or (isNext and D.Cyan or D.Purple);pgF.BorderSizePixel=0;Corner(pgF,2)

        local nL=Instance.new("TextLabel",row);nL.Position=UDim2.new(0,12,0,4);nL.Size=UDim2.new(1,-52,0.5,-2);nL.BackgroundTransparency=1
        nL.Text=(isNext and "▶ " or "")..(q.done and "✅ " or "")..q.item
        nL.TextColor3=q.done and D.GreenBright or (isNext and D.Cyan or D.TextHi)
        nL.TextSize=11;nL.Font=Enum.Font.GothamBold;nL.TextXAlignment=Enum.TextXAlignment.Left;nL.TextTruncate=Enum.TextTruncate.AtEnd

        local pL=Instance.new("TextLabel",row);pL.Position=UDim2.new(0,12,0.5,0);pL.Size=UDim2.new(1,-52,0.5,-4);pL.BackgroundTransparency=1
        pL.Text=inv.." / "..q.amount.."  ("..math.floor(pct*100).."%)"
        pL.TextColor3=q.done and D.GreenBright or D.TextMid;pL.TextSize=10;pL.Font=Enum.Font.GothamSemibold;pL.TextXAlignment=Enum.TextXAlignment.Left

        local ci=i
        local xBtn=Instance.new("TextButton",row);xBtn.Size=UDim2.new(0,34,0,34);xBtn.Position=UDim2.new(1,-38,0.5,-17);xBtn.BackgroundColor3=Color3.fromRGB(50,12,12);xBtn.Text="✕";xBtn.TextColor3=D.Red;xBtn.TextSize=13;xBtn.Font=Enum.Font.GothamBold;xBtn.AutoButtonColor=false;xBtn.BorderSizePixel=0;Corner(xBtn,7);Stroke(xBtn,D.Red,1,0.4)
        xBtn.MouseEnter:Connect(function() Tw(xBtn,{BackgroundColor3=D.RedDark}) end)
        xBtn.MouseLeave:Connect(function() Tw(xBtn,{BackgroundColor3=Color3.fromRGB(50,12,12)}) end)
        xBtn.MouseButton1Click:Connect(function() table.remove(AF.Queue,ci);SaveQueue();UpdateQueueUI() end)
    end
end

local function FarmLoop()
    AF.Active=true
    while AF.Running do
        local q=GetNextItem()
        if not q then
            AF.Active=false
            SetStatus("✅  Queue fertig!",D.Green)
            break
        end

        -- Bestes Chapter finden
        local chapId,worldId,mode,rate = FindBestChapter(q.item)
        if not chapId then
            -- Fallback: erstes Chapter aus WorldData
            local WorldIds = HS.GetWorldIds()
            if #WorldIds>0 then
                local wd = HS.GetWorldData()[WorldIds[1]] or {}
                if wd.story and #wd.story>0 then
                    chapId=wd.story[1];worldId=WorldIds[1];mode="Story";rate=0
                end
            end
        end

        if not chapId then
            SetStatus("⚠ Kein Chapter für '"..q.item.."' gefunden",D.Orange)
            task.wait(3);q.done=true;pcall(UpdateQueueUI);continue
        end

        SetStatus(string.format("🚀 Farm: %s → %s (%.1f%%)",q.item,chapId,rate or 0), D.Cyan)

        -- Raum erstellen & starten
        FireCreateAndStart(worldId,mode,chapId)

        -- Warten bis Ziel erreicht (max 10 Minuten)
        local deadline = os.time()+600
        local goalMet  = false

        while AF.Running and os.time()<deadline do
            task.wait(5)
            local cur=GetInvAmt(q.item)
            SetStatus(string.format("📊 %s: %d/%d (%.0f%%)",
                q.item, cur, q.amount, math.min(100,cur/math.max(1,q.amount)*100)), D.Cyan)
            pcall(function() HS.UpdateGoalsUI() end)
            pcall(UpdateQueueUI)
            if cur>=q.amount then goalMet=true;break end
        end

        if goalMet then
            q.done=true;SaveQueue();pcall(UpdateQueueUI)
            local cur=GetInvAmt(q.item)
            task.spawn(function() pcall(function() SendWebhook({},q.item,cur) end) end)

            SetStatus("🏠 Zurück zur Lobby...",D.Yellow)
            task.wait(2);ClickBackToLobby()

            -- Warten auf Lobby
            local lw=0
            while AF.Running and not IsInLobby() and lw<15 do task.wait(1);lw=lw+1 end
            task.wait(2)
        else
            SetStatus("⚠ Timeout – nächstes Item...",D.Orange)
            task.wait(2)
        end
    end
    AF.Active=false
end

-- Lobby-Auto-Restart
task.spawn(function()
    local wasInGame=false
    while AF.Running do
        task.wait(3)
        local inLobby=IsInLobby()
        if wasInGame and inLobby and #AF.Queue>0 and GetNextItem() and not AF.Active then
            task.wait(3);if AF.Running then task.spawn(FarmLoop) end
        end
        if not inLobby then wasInGame=true end
    end
end)

-- Live-Update Queue alle 5s
task.spawn(function()
    while AF.Running do task.wait(5);pcall(UpdateQueueUI) end
end)

-- ============================================================
--  STOP-FUNKTION (wird in _G.HazeShared registriert)
-- ============================================================
local function StopFarm()
    AF.Active=false;AF.Running=false
    SetStatus("⏹  Gestoppt",D.TextMid)
end
HS.StopFarm = StopFarm   -- Hauptskript kann damit beim Unload aufrufen

-- ============================================================
--  GUI AUFBAUEN  →  in Container injizieren
-- ============================================================

-- Loading-Hint entfernen
local hint = Container:FindFirstChild("AutofarmLoadingHint")
if hint then hint:Destroy() end

-- Status-Card
local fsCard=Card(Container,36);Pad(fsCard,6,10,6,10)
AF.Lbl.FarmStatus=Instance.new("TextLabel",fsCard)
AF.Lbl.FarmStatus.Size=UDim2.new(1,0,1,0);AF.Lbl.FarmStatus.BackgroundTransparency=1
AF.Lbl.FarmStatus.Text="⏹  Auto-Farm gestoppt";AF.Lbl.FarmStatus.TextColor3=D.TextMid
AF.Lbl.FarmStatus.TextSize=11;AF.Lbl.FarmStatus.Font=Enum.Font.GothamSemibold
AF.Lbl.FarmStatus.TextXAlignment=Enum.TextXAlignment.Left

-- Reward-DB Karte
local dbCard=Card(Container);Pad(dbCard,10,10,10,10);VList(dbCard,8);SecLbl(dbCard,"🗃  REWARD-DATENBANK")
AF.Lbl.DBStatus=MkLbl(dbCard,"Keine DB. Starte Scan oder lade Datei.",11,D.TextLow)
AF.Lbl.DBStatus.Size=UDim2.new(1,0,0,24)

local dbBtnRow=Instance.new("Frame",dbCard);dbBtnRow.Size=UDim2.new(1,0,0,30);dbBtnRow.BackgroundTransparency=1;HList(dbBtnRow,8)

local scanDbBtn=Instance.new("TextButton",dbBtnRow)
scanDbBtn.Size=UDim2.new(0.48,0,0,30);scanDbBtn.BackgroundColor3=D.CardHover
scanDbBtn.Text="🔍  Scannen";scanDbBtn.TextColor3=D.Purple
scanDbBtn.TextSize=11;scanDbBtn.Font=Enum.Font.GothamBold
scanDbBtn.AutoButtonColor=false;scanDbBtn.BorderSizePixel=0;Corner(scanDbBtn,7);Stroke(scanDbBtn,D.Purple,1,0.3)

local loadDbBtn=Instance.new("TextButton",dbBtnRow)
loadDbBtn.Size=UDim2.new(0.48,0,0,30);loadDbBtn.BackgroundColor3=D.CardHover
loadDbBtn.Text="📂  DB laden";loadDbBtn.TextColor3=D.CyanDim
loadDbBtn.TextSize=11;loadDbBtn.Font=Enum.Font.GothamBold
loadDbBtn.AutoButtonColor=false;loadDbBtn.BorderSizePixel=0;Corner(loadDbBtn,7);Stroke(loadDbBtn,D.CyanDim,1,0.3)

loadDbBtn.MouseButton1Click:Connect(function()
    if LoadDB() then
        local c=0; for _ in pairs(AF.RewardDB) do c=c+1 end
        AF.Lbl.DBStatus.Text=string.format("✅  DB: %d Chapter",c)
        AF.Lbl.DBStatus.TextColor3=D.Green
    else
        AF.Lbl.DBStatus.Text="⚠  Keine DB-Datei gefunden."
        AF.Lbl.DBStatus.TextColor3=D.Orange
    end
end)

scanDbBtn.MouseButton1Click:Connect(function()
    task.spawn(function()
        ScanAllRewards(function(msg)
            pcall(function()
                AF.Lbl.DBStatus.Text=msg
                AF.Lbl.DBStatus.TextColor3=D.Yellow
            end)
        end)
        local c=0; for _ in pairs(AF.RewardDB) do c=c+1 end
        pcall(function()
            AF.Lbl.DBStatus.Text=string.format("✅  %d Chapter gescannt",c)
            AF.Lbl.DBStatus.TextColor3=D.Green
        end)
    end)
end)

-- Queue-Karte
local qCard=Card(Container);Pad(qCard,10,10,10,10);VList(qCard,8);SecLbl(qCard,"📋  AUTO-FARM QUEUE")

local qRow=Instance.new("Frame",qCard);qRow.Size=UDim2.new(1,0,0,30);qRow.BackgroundTransparency=1;HList(qRow,5)

-- Item-Eingabe
local qItemOuter,qItemBox=MkInput(qRow,"Item-Name...")
qItemOuter.Size=UDim2.new(0.50,0,0,30)
-- Anzahl-Eingabe
local qAmtOuter,qAmtBox=MkInput(qRow,"Anzahl")
qAmtOuter.Size=UDim2.new(0.28,0,0,30)
-- + Hinzufügen
local qAddBtn=Instance.new("TextButton",qRow)
qAddBtn.Size=UDim2.new(0.19,0,0,30);qAddBtn.BackgroundColor3=D.Green
qAddBtn.Text="+ Add";qAddBtn.TextColor3=Color3.new(1,1,1);qAddBtn.TextSize=11
qAddBtn.Font=Enum.Font.GothamBold;qAddBtn.AutoButtonColor=false;qAddBtn.BorderSizePixel=0
Corner(qAddBtn,7);Stroke(qAddBtn,D.Green,1,0.2)
qAddBtn.MouseEnter:Connect(function() Tw(qAddBtn,{BackgroundColor3=Color3.fromRGB(0,160,80)}) end)
qAddBtn.MouseLeave:Connect(function() Tw(qAddBtn,{BackgroundColor3=D.Green}) end)

AF.Fr.QueueList=Instance.new("Frame",qCard)
AF.Fr.QueueList.Size=UDim2.new(1,0,0,0);AF.Fr.QueueList.AutomaticSize=Enum.AutomaticSize.Y
AF.Fr.QueueList.BackgroundTransparency=1;VList(AF.Fr.QueueList,4)
AF.Lbl.QueueEmpty=MkLbl(AF.Fr.QueueList,"Queue leer. Item + Anzahl eintragen.",11,D.TextLow)
AF.Lbl.QueueEmpty.Size=UDim2.new(1,0,0,24)

qAddBtn.MouseButton1Click:Connect(function()
    local iname=(qItemBox.Text or ""):match("^%s*(.-)%s*$")
    local iamt=tonumber(qAmtBox.Text)
    if iname=="" or not iamt or iamt<=0 then return end

    -- Auch als Session-Ziel hinzufügen (über Hauptskript-State)
    local found=false
    for _,g in ipairs(State.Goals) do if g.item==iname then found=true;break end end
    if not found then table.insert(State.Goals,{item=iname,amount=iamt,reached=false}) end

    table.insert(AF.Queue,{item=iname,amount=iamt,done=false})
    SaveQueue();qItemBox.Text="";qAmtBox.Text=""
    UpdateQueueUI();pcall(function() HS.UpdateGoalsUI() end)
end)

-- Steuerung
local ctrlRow=Instance.new("Frame",qCard);ctrlRow.Size=UDim2.new(1,0,0,32);ctrlRow.BackgroundTransparency=1;HList(ctrlRow,8)

local startBtn=Instance.new("TextButton",ctrlRow)
startBtn.Size=UDim2.new(0.48,0,0,32);startBtn.BackgroundColor3=D.Green
startBtn.Text="▶  Start Queue";startBtn.TextColor3=Color3.new(1,1,1)
startBtn.TextSize=12;startBtn.Font=Enum.Font.GothamBold
startBtn.AutoButtonColor=false;startBtn.BorderSizePixel=0;Corner(startBtn,8);Stroke(startBtn,D.Green,1,0.2)

local stopBtn=Instance.new("TextButton",ctrlRow)
stopBtn.Size=UDim2.new(0.48,0,0,32);stopBtn.BackgroundColor3=D.RedDark
stopBtn.Text="⏹  Stop";stopBtn.TextColor3=D.Red
stopBtn.TextSize=12;stopBtn.Font=Enum.Font.GothamBold
stopBtn.AutoButtonColor=false;stopBtn.BorderSizePixel=0;Corner(stopBtn,8);Stroke(stopBtn,D.Red,1,0.4)

startBtn.MouseButton1Click:Connect(function()
    if not next(AF.RewardDB) then
        SetStatus("⚠ Reward-DB zuerst laden/scannen!",D.Orange);return
    end
    if AF.Active then SetStatus("⚠ Farm läuft bereits!",D.Yellow);return end
    AF.Running=true;task.spawn(FarmLoop)
end)

stopBtn.MouseButton1Click:Connect(StopFarm)

local clearBtn=NeonBtn(qCard,"🗑  Queue leeren",D.Red,28)
clearBtn.MouseButton1Click:Connect(function()
    AF.Queue={};SaveQueue();UpdateQueueUI()
end)

-- DB beim Starten laden falls vorhanden
if LoadDB() then
    local c=0; for _ in pairs(AF.RewardDB) do c=c+1 end
    pcall(function()
        AF.Lbl.DBStatus.Text=string.format("✅  DB: %d Chapter geladen",c)
        AF.Lbl.DBStatus.TextColor3=D.Green
    end)
end

-- Queue aus Config laden (beim Neustart wiederherstellen)
if Config.SavedQueue and type(Config.SavedQueue)=="table" then
    AF.Queue={}
    for _,q in ipairs(Config.SavedQueue) do
        if q.item and tonumber(q.amount) then
            table.insert(AF.Queue,{item=q.item,amount=tonumber(q.amount),done=q.done==true})
        end
    end
end
UpdateQueueUI()

print("[HazeAF] Autofarm-Modul erfolgreich geladen ✅")
