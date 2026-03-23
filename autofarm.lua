-- ============================================================
--  ★ autofarm.lua – Ergänzung
--
--  EINFÜGEN: direkt in autofarm.lua
--  POSITION: nach der Zeile
--      task.spawn(TryAutoResume)
--  und VOR:
--      HS.SetModuleLoaded(VERSION)
--
--  WICHTIG: Muss im selben Scope wie autofarm.lua stehen,
--  damit AF, ClearDB, ScanAllRewards, DBCount, NotifyDBReady,
--  D, Tw, TF, TM alle aufgelöst werden.
-- ============================================================

-- ────────────────────────────────────────────────────────────
--  TriggerResetRescan
--  Aufgerufen vom Hauptskript via _G.HazeShared.TriggerResetRescan()
--  Löscht DB im RAM → Deep-Scan → NotifyDBReady
-- ────────────────────────────────────────────────────────────
HS.TriggerResetRescan = function(onProgress)
    -- Schutz: kein Doppel-Scan
    if AF.Scanning then
        pcall(function()
            if onProgress then
                onProgress("⚠ Scan läuft bereits – bitte warten!")
            end
        end)
        return
    end

    -- RAM-DB leeren (Datei wurde bereits vom Hauptskript gelöscht)
    ClearDB()

    -- Autofarm-UI-Labels zurücksetzen
    pcall(function()
        AF.UI.Lbl.DBStatus.Text           = "⏳ Reset & Rescan gestartet..."
        AF.UI.Lbl.DBStatus.TextColor3     = D.Yellow
        AF.UI.Fr.ScanBar.Visible          = true
        AF.UI.Fr.ScanBarFill.Size         = UDim2.new(0, 0, 1, 0)
        AF.UI.Fr.ScanBarFill.BackgroundColor3 = D.Purple
        AF.UI.Lbl.ScanProgress.Text       = "Reset & Rescan: startet..."
        AF.UI.Lbl.ScanProgress.TextColor3 = D.Yellow
        if AF.UI.Btn.ForceRescan then
            AF.UI.Btn.ForceRescan.Text       = "Scannt..."
            AF.UI.Btn.ForceRescan.TextColor3 = D.Yellow
        end
        if AF.UI.Btn.UpdateDB then
            AF.UI.Btn.UpdateDB.Text       = "Scannt..."
            AF.UI.Btn.UpdateDB.TextColor3 = D.Yellow
        end
    end)

    -- Deep-Scan asynchron starten
    task.spawn(function()
        -- Kombinierter Progress-Callback: geht an UI + Hauptskript-Callback
        local function _combined(msg)
            pcall(function()
                AF.UI.Lbl.DBStatus.Text       = msg
                AF.UI.Lbl.DBStatus.TextColor3 = D.Yellow
            end)
            if onProgress then pcall(function() onProgress(msg) end) end
        end

        local _ok = ScanAllRewards(_combined)

        -- Buttons zurücksetzen
        pcall(function()
            if AF.UI.Btn.ForceRescan then
                AF.UI.Btn.ForceRescan.Text       = "DATENBANK NEU SCANNEN"
                AF.UI.Btn.ForceRescan.TextColor3 = Color3.new(1, 1, 1)
            end
            if AF.UI.Btn.UpdateDB then
                AF.UI.Btn.UpdateDB.Text       = "Update Database"
                AF.UI.Btn.UpdateDB.TextColor3 = D.Cyan
            end
        end)

        local _finalMsg = _ok
            and string.format(
                "✅ Reset & Rescan fertig! %d Chapters in DB.", DBCount())
            or  "⚠ Scan abgeschlossen (einige Chapters fehlgeschlagen)."

        pcall(function() onProgress(_finalMsg) end)

        -- Hauptskript-UI freischalten (Start-Button im Game-Tab)
        if _ok then
            NotifyDBReady(DBCount(), _finalMsg)
        end

        print("[HazeHub] TriggerResetRescan: " .. _finalMsg)
    end)
end
