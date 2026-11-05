--[[
In-plugin updater: asks GitHub for the latest release of this plugin, downloads it and swaps the
plugin folder. Needs a network connection. Settings, caches and backups live outside the plugin
folder, so they are kept. The previous version stays next to it as "bionic.koplugin.old"
(KOReader ignores it) so you can roll back by hand if you ever need to.

Maintainer notes
  * U.VERSION must match the tag of each GitHub release you publish (tag "v1.2.0" <-> "1.2.0").
  * U.REPO must be set to "<your GitHub name>/<repository name>".
  * Attach a zip made like:  zip -r bionic.koplugin-v1.2.0.zip bionic.koplugin
    (the zip may also hold the files at its top level; GitHub's automatic source zip works too).
]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local I18n = require("bionic_i18n")
local _ = I18n.tr
local T = ffiUtil.template

local U = {}

U.VERSION = "1.0.0"
U.REPO = "wj-fr/Kindle-KOreader-Bionic-Reading"

--------------------------------------------------------------------------
-- Pure helpers (no KOReader needed)
--------------------------------------------------------------------------

-- "v1.2.3-beta" -> { 1, 2, 3 }
function U.parse_version(s)
    local t = {}
    local str = tostring(s or ""):gsub("^%s*[vV]?", "")
    local core = str:match("^[%d%.]+") or ""
    for n in core:gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

-- 1 if a is newer than b, -1 if older, 0 if equal
function U.compare(a, b)
    local x, y = U.parse_version(a), U.parse_version(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p > q then return 1 end
        if p < q then return -1 end
    end
    return 0
end

-- Directory prefix (with trailing "/", or "" for the zip top level) that holds the plugin:
-- the shallowest folder containing both main.lua and _meta.lua.
function U.find_root(paths)
    local set = {}
    for _i, p in ipairs(paths) do set[p] = true end
    local best
    for _i, p in ipairs(paths) do
        local dir = p:match("^(.*/)main%.lua$")
        if dir == nil and p == "main.lua" then dir = "" end
        if dir and set[dir .. "_meta.lua"] then
            if not best or #dir < #best then best = dir end
        end
    end
    return best
end

-- never write outside the staging folder
local function safe_rel(p)
    if p:find("^/") or p:find("^%a:") or p:find("%.%.") or p:find("\\", 1, true) then return false end
    return true
end

local function cut_utf8(s, maxbytes)
    if #s <= maxbytes then return s end
    local cut = maxbytes
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 128 or b >= 192 then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. "…"
end

--------------------------------------------------------------------------
-- Network
--------------------------------------------------------------------------

-- GET url. Returns the body (string), or true when to_file is given; nil, err on failure.
-- Redirects are followed by hand so that https -> https hops (GitHub downloads) always use
-- the right transport.
local function fetch(url, to_file)
    local socket = require("socket")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    for _hop = 1, 6 do
        local http = url:match("^https:") and require("ssl.https") or require("socket.http")
        local chunks, fh = {}, nil
        local sink
        if to_file then
            fh = io.open(to_file, "wb")
            if not fh then return nil, "cannot write " .. tostring(to_file) end
            sink = ltn12.sink.file(fh)
        else
            sink = ltn12.sink.table(chunks)
        end

        socketutil:set_timeout(15, to_file and 120 or 30)
        local code, headers = socket.skip(1, http.request{
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "bionic.koplugin/" .. U.VERSION,
                ["Accept"] = "application/vnd.github+json, application/octet-stream, */*",
            },
            sink = sink,
            redirect = false,
        })
        socketutil:reset_timeout()
        if fh then pcall(fh.close, fh) end

        if type(code) ~= "number" then
            if to_file then os.remove(to_file) end
            return nil, tostring(code)
        end
        if code >= 300 and code < 400 and headers and headers.location then
            url = socket_url.absolute(url, headers.location)
            if to_file then os.remove(to_file) end
        elseif code == 200 then
            if to_file then return true end
            return table.concat(chunks)
        else
            if to_file then os.remove(to_file) end
            return nil, "HTTP " .. tostring(code)
        end
    end
    return nil, "too many redirects"
end

function U.fetch_latest()
    local body, err = fetch("https://api.github.com/repos/" .. U.REPO .. "/releases/latest")
    if not body then
        if err == "HTTP 404" then return nil, _("No release was found on GitHub.") end
        return nil, err
    end
    local ok, JSON = pcall(require, "json")
    if not ok then return nil, "json module missing" end
    local ok2, rel = pcall(JSON.decode, body)
    if not ok2 or type(rel) ~= "table" or not rel.tag_name then
        return nil, _("Unexpected reply from GitHub.")
    end
    return rel
end

function U.pick_download(rel)
    for _i, a in ipairs(rel.assets or {}) do
        if type(a) == "table" and a.browser_download_url
            and tostring(a.name):lower():match("%.zip$") then
            return a.browser_download_url
        end
    end
    return rel.zipball_url
end

--------------------------------------------------------------------------
-- Install
--------------------------------------------------------------------------

local function mkdirs(path)
    local cur = path:match("^/") and "" or "."
    for part in path:gmatch("[^/]+") do
        cur = cur .. "/" .. part
        if lfs.attributes(cur, "mode") ~= "directory" then
            if not lfs.mkdir(cur) then return false end
        end
    end
    return true
end

local function purge(dir)
    if lfs.attributes(dir, "mode") == "directory" then
        pcall(ffiUtil.purgeDir, dir)
    end
end

local REQUIRED = { "main.lua", "_meta.lua", "bionify.lua" }

-- Downloads the release and replaces the plugin folder. Returns true, or nil + message.
function U.install(plugin_dir, rel)
    local parent = plugin_dir:match("^(.*)/[^/]+$")
    if not parent then return nil, "plugin folder unknown" end

    local url = U.pick_download(rel)
    if not url then return nil, _("This release has no downloadable file.") end

    local zip = DataStorage:getDataDir() .. "/bionic_update.zip"
    local ok, err = fetch(url, zip)
    if not ok then return nil, err end

    -- read the zip into memory (the plugin is small)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(zip) then
        os.remove(zip)
        return nil, _("The downloaded file is not a valid zip.")
    end
    local files, paths = {}, {}
    for entry in reader:iterate() do
        if entry.mode == "file" and safe_rel(entry.path) then
            local data = reader:extractToMemory(entry.path)
            if not data then
                reader:close(); os.remove(zip)
                return nil, _("Failed to read a file inside the zip.")
            end
            files[entry.path] = data
            paths[#paths + 1] = entry.path
        end
    end
    reader:close()
    os.remove(zip)

    local root = U.find_root(paths)
    if not root then return nil, _("The download does not look like this plugin.") end

    -- write everything to a staging folder first
    local staging = parent .. "/bionic.update.tmp"
    purge(staging)
    if not mkdirs(staging) then return nil, _("Cannot create a temporary folder.") end

    local rels = {}
    for _i, p in ipairs(paths) do
        if p:sub(1, #root) == root and #p > #root then
            local rpath = p:sub(#root + 1)
            local dir = rpath:match("^(.*)/[^/]+$")
            if dir and not mkdirs(staging .. "/" .. dir) then
                purge(staging)
                return nil, _("Cannot create a temporary folder.")
            end
            local fh = io.open(staging .. "/" .. rpath, "wb")
            if not fh then purge(staging); return nil, _("Cannot write the new files.") end
            fh:write(files[p])
            fh:close()
            rels[#rels + 1] = rpath
        end
    end

    -- sanity checks: required files present and every Lua file compiles
    local have = {}
    for _i, r in ipairs(rels) do have[r] = true end
    for _i, r in ipairs(REQUIRED) do
        if not have[r] then purge(staging); return nil, T(_("The download is missing %1."), r) end
    end
    for _i, r in ipairs(rels) do
        if r:match("%.lua$") then
            local f, e = loadfile(staging .. "/" .. r)
            if not f then
                logger.warn("bionic: update check failed for", r, e)
                purge(staging)
                return nil, T(_("The downloaded file %1 is broken."), r)
            end
        end
    end

    -- swap folders; the old version is kept as <plugin>.old
    local old = plugin_dir .. ".old"
    purge(old)
    if not os.rename(plugin_dir, old) then
        purge(staging)
        return nil, _("Cannot replace the plugin folder.")
    end
    if not os.rename(staging, plugin_dir) then
        os.rename(old, plugin_dir)
        purge(staging)
        return nil, _("Cannot replace the plugin folder.")
    end
    return true
end

--------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------

local function say(text) UIManager:show(InfoMessage:new{ text = text }) end

local function run_install(plugin_dir, rel)
    local msg = InfoMessage:new{ text = _("Downloading update…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        local ok, a, b = pcall(U.install, plugin_dir, rel)
        UIManager:close(msg)
        local done, err = false, a
        if ok then done, err = a, b end
        if done then
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = T(_("Updated to %1. Restart KOReader now to use the new version?"), tostring(rel.tag_name)),
                ok_text = _("Restart"),
                cancel_text = _("Later"),
                ok_callback = function() UIManager:restartKOReader() end,
            })
        else
            say(T(_("Update failed: %1"), tostring(err)))
        end
    end)
end

local function run_check(plugin_dir)
    local msg = InfoMessage:new{ text = _("Checking for updates…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        local ok, rel, err = pcall(U.fetch_latest)
        UIManager:close(msg)
        if not ok then rel, err = nil, rel end
        if not rel then
            say(T(_("Could not check for updates: %1"), tostring(err)))
            return
        end
        if U.compare(rel.tag_name, U.VERSION) <= 0 then
            say(T(_("You already have the latest version (v%1)."), U.VERSION))
            return
        end
        local ConfirmBox = require("ui/widget/confirmbox")
        local text = T(_("New version %1 is available (you have v%2). Update now?"),
            tostring(rel.tag_name), U.VERSION)
        local notes = tostring(rel.body or ""):gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if notes ~= "" then text = text .. "\n\n" .. cut_utf8(notes, 500) end
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = _("Update"),
            cancel_text = _("Later"),
            ok_callback = function() run_install(plugin_dir, rel) end,
        })
    end)
end

function U.run(plugin_dir)
    if not plugin_dir then say(_("Cannot find the plugin folder.")); return end
    if U.REPO:find("YOUR_GITHUB_NAME", 1, true) then
        say(_("The update source is not configured yet (set REPO in bionic_update.lua)."))
        return
    end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function() run_check(plugin_dir) end)
    else
        run_check(plugin_dir)
    end
end

-- the menu entry used by main.lua
function U.menuItem(plugin_dir)
    return {
        text_func = function() return T(_("Check for updates (current v%1)"), U.VERSION) end,
        enabled_func = function() return plugin_dir ~= nil end,
        callback = function(touchmenu_instance)
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            U.run(plugin_dir)
        end,
        separator = true,
    }
end

return U
