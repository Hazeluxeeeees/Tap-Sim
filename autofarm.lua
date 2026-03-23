-- ============================================================
--  ★ autofarm.lua – Ergänzung (an das Ende des Startup-Blocks)
--  Einfügen NACH: task.spawn(TryAutoResume)
--  und VOR:       HS.SetModuleLoaded(VERSION)
-- ============================================================

-- ────────────────────────────────────────────────────────────
--  ★ TriggerResetRescan
--  Wird vom Hauptskript (Settings-Tab Button 1) aufgerufen.
--  Löscht die DB im RAM, startet ScanAllRewards() und
--  ruft am Ende NotifyDBReady() auf, damit der Start-Button
--  im Game-Tab wieder freigeschaltet wird.
-- ────────────────────────────────────────────────────────────
HS.TriggerResetRescan = function(onProgress)
    if AF.Scanning then
        pcall(function()
            if onProgress then onProgress("⚠ Scan läuft bereits – bitte warten!") end
        end)
        return
    end

    -- RAM-DB leeren (Datei wurde bereits vom Hauptskript gelöscht)
    ClearDB()

    -- Status-Labels im Autofarm-UI zurücksetzen
    pcall(function()
        AF.UI.Lbl.DBStatus.Text       = "⏳ Reset & Rescan gestartet..."
        AF.UI.Lbl.DBStatus.TextColor3 = D.Yellow
        AF.UI.Fr.ScanBar.Visible      = true
        AF.UI.Fr.ScanBarFill.Size     = UDim2.new(0, 0, 1, 0)
        AF.UI.Fr.ScanBarFill.BackgroundColor3 = D.Purple
        AF.UI.Lbl.ScanProgress.Text   = "Reset & Rescan: startet..."
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

    -- Deep-Scan asynchron ausführen
    task.spawn(function()
        local combinedProgress = function(msg)
            pcall(function()
                AF.UI.Lbl.DBStatus.Text       = msg
                AF.UI.Lbl.DBStatus.TextColor3 = D.Yellow
            end)
            if onProgress then pcall(function() onProgress(msg) end) end
        end

        local ok = ScanAllRewards(combinedProgress)

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

        local finalMsg = ok
            and string.format("✅ Reset & Rescan fertig! %d Chapters in DB.", DBCount())
            or  "⚠ Scan abgeschlossen (einige Chapters fehlgeschlagen)."

        pcall(function() onProgress(finalMsg) end)

        -- Hauptskript-UI über Ergebnis informieren
        if ok then
            NotifyDBReady(DBCount(), finalMsg)
        end

        print("[HazeHub] TriggerResetRescan: " .. finalMsg)
    end)
end
