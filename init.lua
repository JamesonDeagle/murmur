-- Murmur — Option+Space toggle with waveform overlay
-- Daemon: http://127.0.0.1:19876

local DAEMON = "http://127.0.0.1:19876"
local DAEMON_SCRIPT = os.getenv("HOME") .. "/.whisper-stt/whisper-stt-daemon.py"
local DAEMON_PYTHON = os.getenv("HOME") .. "/.whisper-stt/venv/bin/python3"
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

-- Launch the STT daemon as a child process of Hammerspoon
-- so it inherits Hammerspoon's microphone permission from macOS.
-- A LaunchAgent cannot reliably get mic access as a background process.
local daemonTask = nil
local function ensureDaemon()
    local code = nil
    pcall(function()
        code = select(1, hs.http.get(DAEMON .. "/status", nil))
    end)
    if code == 200 then return end

    if daemonTask and daemonTask:isRunning() then return end

    daemonTask = hs.task.new(DAEMON_PYTHON, function(exitCode)
        print("Murmur daemon exited: " .. tostring(exitCode))
    end, {DAEMON_SCRIPT})
    daemonTask:setEnvironment({
        HOME = os.getenv("HOME"),
        PATH = os.getenv("HOME") .. "/.whisper-stt/venv/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    })
    daemonTask:start()
end

ensureDaemon()
hs.timer.doEvery(30, ensureDaemon)

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

-- Config file for persistent hotkey settings
local CONFIG_PATH = os.getenv("HOME") .. "/.whisper-stt/config.json"

local function loadConfig()
    local f = io.open(CONFIG_PATH, "r")
    if not f then return { mods = {"alt"}, key = "space" } end
    local raw = f:read("*a")
    f:close()
    local ok, data = pcall(hs.json.decode, raw)
    if ok and data and data.key then return data end
    return { mods = {"alt"}, key = "space" }
end

local function saveConfig(cfg)
    os.execute("mkdir -p " .. os.getenv("HOME") .. "/.whisper-stt")
    local f = io.open(CONFIG_PATH, "w")
    if f then
        f:write(hs.json.encode(cfg))
        f:close()
    end
end

local config = loadConfig()
local mainHotkey = nil

local function formatHotkey(cfg)
    local parts = {}
    for _, m in ipairs(cfg.mods or {}) do
        table.insert(parts, m:sub(1,1):upper() .. m:sub(2))
    end
    table.insert(parts, cfg.key)
    return table.concat(parts, "+")
end

local function bindMainHotkey(cfg)
    if mainHotkey then mainHotkey:delete() end
    mainHotkey = hs.hotkey.bind(cfg.mods, cfg.key, function()
        toggleSTT()
    end)
end

bindMainHotkey(config)

-- Escape to cancel recording (only active while recording)
escHotkey = hs.hotkey.new({}, "escape", function()
    recording = false
    busy = false
    stopLevelsPolling()
    hidePill()
    escHotkey:disable()
    hs.http.asyncPost(DAEMON .. "/cancel", "", nil, function() end)
end)

-- Capture new hotkey from user
local function captureHotkey(callback)
    hs.alert.show("Press new hotkey...", 3)
    local tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
        local flags = event:getFlags()
        local key = hs.keycodes.map[event:getKeyCode()]
        if not key then return true end

        local mods = {}
        if flags.cmd then table.insert(mods, "cmd") end
        if flags.alt then table.insert(mods, "alt") end
        if flags.ctrl then table.insert(mods, "ctrl") end
        if flags.shift then table.insert(mods, "shift") end

        callback({ mods = mods, key = key })
        return true
    end)
    tap:start()
    -- Auto-stop after first key
    hs.timer.doAfter(5, function() tap:stop() end)
    -- Stop after capture via callback wrapper
    local origCallback = callback
    callback = function(cfg) -- luacheck: ignore
        tap:stop()
        origCallback(cfg)
    end
end

-- Menubar for model selection
local menubar = hs.menubar.new()
local activeModel = "turbo"

local function updateMenubar()
    local iconPath = os.getenv("HOME") .. "/.hammerspoon/icon.pdf"
    menubar:setIcon(iconPath, true)
    menubar:setTitle("")
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
        { title = formatHotkey(config) .. " — record / stop", fn = function()
            hs.alert.show("Press new hotkey...", 3)
            local tap
            tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
                local flags = event:getFlags()
                local key = hs.keycodes.map[event:getKeyCode()]
                if not key then return true end
                local mods = {}
                if flags.cmd then table.insert(mods, "cmd") end
                if flags.alt then table.insert(mods, "alt") end
                if flags.ctrl then table.insert(mods, "ctrl") end
                if flags.shift then table.insert(mods, "shift") end
                config = { mods = mods, key = key }
                saveConfig(config)
                bindMainHotkey(config)
                tap:stop()
                hs.alert.show("Hotkey: " .. formatHotkey(config), 1.5)
                return true
            end)
            tap:start()
            hs.timer.doAfter(5, function() if tap:isEnabled() then tap:stop(); hs.alert.show("Cancelled", 0.5) end end)
        end },
        { title = "Escape — cancel", disabled = true },
        { title = "-" },
        { title = "Model", menu = {
            { title = "turbo (fast)", fn = function() switchModel("turbo") end,
              checked = (activeModel == "turbo") },
            { title = "large (best quality)", fn = function() switchModel("large") end,
              checked = (activeModel == "large") },
        }},
        { title = "-" },
        { title = "Reload Config", fn = function() hs.reload() end },
        { title = "Daemon Status", fn = function()
            hs.http.asyncGet(DAEMON .. "/status", nil, function(code, body)
                if code == 200 then
                    hs.alert.show("Daemon: " .. body, 2)
                else
                    hs.alert.show("Daemon offline", 2)
                end
            end)
        end },
        { title = "-" },
        { title = "Quit Murmur", fn = function()
            if daemonTask and daemonTask:isRunning() then
                daemonTask:terminate()
            end
            if mainHotkey then mainHotkey:delete() end
            stopLevelsPolling()
            hidePill()
            if menubar then menubar:delete() end
            hs.alert.show("Murmur stopped", 1)
        end },
    }
end)

-- Hide Hammerspoon's own menubar icon
hs.dockicon.hide()
if hs.menuIcon then hs.menuIcon(false) end

-- Sync model state from daemon on startup
local function syncDaemon()
    hs.http.asyncGet(DAEMON .. "/status", nil, function(code, body)
        if code == 200 and body then
            local ok, data = pcall(hs.json.decode, body)
            if ok and data and data.model then
                activeModel = data.model
                updateMenubar()
            end
        end
    end)
end

updateMenubar()
syncDaemon()

-- Pre-create pill webview so first Cmd+F5 is instant
createPill()

-- Warm up HTTP connection to daemon
hs.http.asyncGet(DAEMON .. "/status", nil, function() end)

hs.alert.show("Murmur ready", 1)
