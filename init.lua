-- Whisper STT — Cmd+F5 toggle with waveform overlay
-- Daemon: http://127.0.0.1:19876

local DAEMON = "http://127.0.0.1:19876"
local PILL_W = 260
local PILL_H = 140
local PILL_BOTTOM_MARGIN = 60

-- State
local recording = false
local busy = false
local recordingStartTime = 0
local MIN_RECORDING_SEC = 1.0
-- Waveform pill (webview)
local pill = nil
local levelsTimer = nil

local function getPillFrame()
    local screen = hs.screen.mainScreen():frame()
    return hs.geometry.rect(
        screen.x + (screen.w - PILL_W) / 2,
        screen.y + screen.h - PILL_H - PILL_BOTTOM_MARGIN,
        PILL_W,
        PILL_H
    )
end

local function createPill()
    if pill then pill:delete() end
    local frame = getPillFrame()
    pill = hs.webview.new(frame, { developerExtrasEnabled = false })
    pill:windowStyle({"borderless", "utility", "HUD"})
    pill:level(hs.drawing.windowLevels.overlay)
    pill:alpha(1.0)
    pill:transparent(true)
    pill:allowTextEntry(false)
    pill:url("file://" .. os.getenv("HOME") .. "/.hammerspoon/waveform.html")
    pill:bringToFront(true)
end

local function showPill(mode)
    if not pill then createPill() end
    pill:frame(getPillFrame())
    pill:show()
    -- Trigger CSS enter animation
    hs.timer.doAfter(0.02, function()
        if pill then
            pill:evaluateJavaScript('show()')
            if mode then
                pill:evaluateJavaScript('setMode("' .. mode .. '")')
            end
        end
    end)
end

local function stopLevelsPolling()
    if levelsTimer then
        levelsTimer:stop()
        levelsTimer = nil
    end
end

local function startLevelsPolling()
    stopLevelsPolling()
    levelsTimer = hs.timer.doEvery(0.05, function()
        if not recording or not pill then
            stopLevelsPolling()
            return
        end
        hs.http.asyncGet(
            DAEMON .. "/levels",
            nil,
            function(code, body)
                if code == 200 and body and pill and recording then
                    local ok, data = pcall(hs.json.decode, body)
                    if ok and data and data.levels then
                        local js = "setLevels([" .. table.concat(data.levels, ",") .. "])"
                        pill:evaluateJavaScript(js)
                    end
                end
            end
        )
    end)
end

local function hidePill()
    stopLevelsPolling()
    if pill then
        pill:evaluateJavaScript('hide()')
        -- Wait for CSS exit animation (100ms) before actually hiding
        hs.timer.doAfter(0.12, function()
            if pill then pill:hide() end
        end)
    end
end

local function pasteText(text)
    if not text or #text == 0 then
        hs.alert.show("(empty)", 0.5)
        return
    end
    local prev = hs.pasteboard.getContents()
    hs.pasteboard.setContents(text)
    hs.timer.doAfter(0.05, function()
        hs.eventtap.keyStroke({"cmd"}, "v")
        hs.timer.doAfter(0.5, function()
            if prev then
                hs.pasteboard.setContents(prev)
            end
        end)
    end)
end

-- Toggle STT function
local function toggleSTT()
    if busy then return end
    busy = true

    -- If recording too short — cancel instantly
    if recording then
        stopLevelsPolling()
        local elapsed = hs.timer.secondsSinceEpoch() - recordingStartTime
        if elapsed < MIN_RECORDING_SEC then
            recording = false
            busy = false
            escHotkey:disable()
            hidePill()
            hs.http.asyncPost(DAEMON .. "/cancel", "", nil, function() end)
            return
        end
        if pill then pill:evaluateJavaScript("fadeOut()") end
        hs.timer.doAfter(0.3, function()
            showPill("transcribing")
        end)
    end

    hs.http.asyncPost(
        DAEMON .. "/toggle",
        "",
        nil,
        function(code, body, headers)
            if code ~= 200 or not body then
                busy = false
                hidePill()
                hs.alert.show("STT daemon not running", 1.5)
                return
            end

            local ok, data = pcall(hs.json.decode, body)
            if not ok or not data then
                busy = false
                hidePill()
                return
            end

            if data.status == "recording" then
                recording = true
                recordingStartTime = hs.timer.secondsSinceEpoch()
                busy = false
                escHotkey:enable()
                showPill("recording")
                startLevelsPolling()

            elseif data.status == "done" then
                recording = false
                escHotkey:disable()
                hidePill()
                if data.text and #data.text > 0 then
                    hs.timer.doAfter(0.1, function()
                        pasteText(data.text)
                    end)
                else
                    hs.alert.show("(silence)", 0.5)
                end
                busy = false

            elseif data.status == "loading" then
                busy = false
                hs.alert.show("Model loading...", 1)

            elseif data.status == "transcribing" then
                busy = false
                showPill("transcribing")

            else
                busy = false
            end
        end
    )
end

-- Cmd+F5 hotkey
hs.hotkey.bind({"cmd"}, "F5", function()
    toggleSTT()
end)

-- Escape to cancel recording (only active while recording)
escHotkey = hs.hotkey.new({}, "escape", function()
    recording = false
    busy = false
    stopLevelsPolling()
    hidePill()
    escHotkey:disable()
    hs.http.asyncPost(DAEMON .. "/cancel", "", nil, function() end)
end)

-- Menubar for model selection
local menubar = hs.menubar.new()
local activeModel = "turbo"

local function updateMenubar()
    menubar:setTitle("W:" .. activeModel)
end

local function switchModel(name)
    hs.alert.show("Loading " .. name .. "...", 1)
    hs.http.asyncPost(
        DAEMON .. "/model",
        hs.json.encode({ model = name }),
        { ["Content-Type"] = "application/json" },
        function(code, body)
            if code == 200 then
                local ok, data = pcall(hs.json.decode, body)
                if ok and data and not data.error then
                    activeModel = name
                    updateMenubar()
                    hs.alert.show("Model: " .. name, 1)
                else
                    hs.alert.show("Error: " .. (data and data.error or "unknown"), 2)
                end
            else
                hs.alert.show("Daemon error", 1)
            end
        end
    )
end

menubar:setMenu(function()
    return {
        { title = "turbo (fast)", fn = function() switchModel("turbo") end,
          checked = (activeModel == "turbo") },
        { title = "medium", fn = function() switchModel("medium") end,
          checked = (activeModel == "medium") },
        { title = "large (best)", fn = function() switchModel("large") end,
          checked = (activeModel == "large") },
        { title = "-" },
        { title = "Cmd+F5 to record", disabled = true },
    }
end)

-- Sync model state from daemon on startup
hs.http.asyncGet(DAEMON .. "/status", nil, function(code, body)
    if code == 200 and body then
        local ok, data = pcall(hs.json.decode, body)
        if ok and data and data.model then
            activeModel = data.model
            updateMenubar()
        end
    end
end)

updateMenubar()
hs.alert.show("Whisper STT loaded", 1)
