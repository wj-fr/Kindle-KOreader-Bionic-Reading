--[[--
Bionic Reading for KOReader  -  v2

How it works
------------
crengine (KOReader's EPUB renderer) cannot be hooked at DOM level from Lua, so
the EPUB is rewritten (word prefixes wrapped in <b>) into a cache copy.

v1 opened that copy as a *different book*. That broke everything keyed by file
path (title/author/progress/history shown by KOReader and its skins).

v2 keeps the book identity: KOReader still believes it is reading the ORIGINAL
file (same path, same sidecar, same history, same progress). Only the one call
that hands the file to crengine is redirected to the converted copy.

月读 (Moon) online sources deliver every chapter as its own HTML file and parse that file
themselves to compute crengine XPointers (paragraph-review marks, WeChat highlights...).
For those chapter files the redirect trick would make KOReader and 月读 disagree about the
DOM, so they are converted IN PLACE instead (original kept as "<n>.html.bionic", restored
when bionic reading is turned off). Both sides then read the very same bytes.
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local I18n = require("bionic_i18n")
local _ = I18n.tr
local T = ffiUtil.template

local Bionify = require("bionify")
local Export = require("bionic_export")
local Update = require("bionic_update")

-- where this plugin lives (needed by the in-app uninstaller); nil if it cannot be determined
local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]+$")

local SCHEMA = 4 -- bump to invalidate old caches when the algorithm changes

-- settings that only matter while English / Latin text is switched on
local LATIN_KEYS = { fixation_strength = true, saccades = true, stem_pct = true, edge_opacity = true,
                     style = true, color_on = true, color = true }

local Bionic = WidgetContainer:extend{
    name = "bionic",
    fullname = _("Bionic reading"),
}

-- ONE settings object shared by every plugin instance and by the document hook
Bionic.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/bionic_reading.lua")

--------------------------------------------------------------------------
-- Paths / prefs
--------------------------------------------------------------------------

function Bionic:cacheDir()
    local dir = DataStorage:getDataDir() .. "/bionic_cache"
    if lfs.attributes(dir, "mode") ~= "directory" then util.makePath(dir) end
    return dir
end

function Bionic:isCacheFile(path)
    return path ~= nil and path:sub(1, #self:cacheDir() + 1) == self:cacheDir() .. "/"
end

function Bionic:isEpub(path)
    return path ~= nil and path:lower():match("%.epub$") ~= nil
end

-- <DATA>/.moon/cache/<source>/book/<slug>/<n>.html  (月读 online-source chapter)
function Bionic:isMoonChapter(path)
    return path ~= nil and path:match("/%.moon/cache/[^/]+/book/%x+/%d+%.html$") ~= nil
end

-- books are identified by file (EPUB) or by their chapter directory (月读 chapter books)
function Bionic:bookKey(file)
    if self:isMoonChapter(file) then return (file:gsub("/[^/]+$", "")) end
    return file
end

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

-- Effective settings: built-in defaults < global settings < this book's own settings (if it has any).
-- Without a file only the global level applies (file browser).
function Bionic:prefs(file)
    local p = {}
    for k, v in pairs(Bionify.DEFAULTS) do p[k] = v end
    for k, v in pairs(self.settings:readSetting("prefs", {})) do p[k] = v end
    if file then
        local bp = self.settings:readSetting("book_prefs", {})[self:bookKey(file)]
        if bp then for k, v in pairs(bp) do p[k] = v end end
    end
    return p
end

-- what the settings menu shows / edits: the open book's settings, or the global ones
function Bionic:viewPrefs()
    return self:prefs(self:currentFile())
end

function Bionic:hasBookPrefs(file)
    return file ~= nil and self.settings:readSetting("book_prefs", {})[self:bookKey(file)] ~= nil
end

-- Edits go to the open book when it has its own settings, otherwise to the global ones.
function Bionic:setPrefs(values)
    local file = self:currentFile()
    if self:hasBookPrefs(file) then
        local bps = self.settings:readSetting("book_prefs", {})
        local bp = bps[self:bookKey(file)]
        for k, v in pairs(values) do bp[k] = v end
        self.settings:saveSetting("book_prefs", bps)
    else
        local p = self.settings:readSetting("prefs", {})
        for k, v in pairs(values) do p[k] = v end
        self.settings:saveSetting("prefs", p)
    end
    self.settings:flush()
end

function Bionic:setPref(key, value)
    self:setPrefs({ [key] = value })
end

-- Change one setting from the menu; the open book is only re-rendered when that actually changes
-- the converted text (e.g. the Chinese look settings do nothing while Chinese text is off).
function Bionic:applyPref(key, value, touchmenu_instance)
    local file = self:currentFile()
    local before = file and hash(self:prefsSignature(file))
    self:setPref(key, value)
    if touchmenu_instance then touchmenu_instance:updateItems() end
    if file and hash(self:prefsSignature(file)) ~= before then self:reapplyIfActive() end
end

-- give the open book its own settings (starting from what it uses now) or hand it back to the global ones
function Bionic:toggleBookPrefs()
    local file = self:currentFile()
    if not file then return end
    local key = self:bookKey(file)
    local before = hash(self:prefsSignature(file))
    local bps = self.settings:readSetting("book_prefs", {})
    if bps[key] ~= nil then
        bps[key] = nil
    else
        bps[key] = self:prefs(file)
    end
    self.settings:saveSetting("book_prefs", bps)
    self.settings:flush()
    if hash(self:prefsSignature(file)) ~= before then self:reapplyIfActive() end
end

function Bionic:prefsSignature(file)
    local p, keys = self:prefs(file), {}
    local cjk_off = (p.cjk_chunk or 0) == 0
    local latin_off = p.latin_on == false
    for k in pairs(p) do
        -- the look settings of a script change nothing while that script is switched off
        local skip = (cjk_off and k ~= "cjk_chunk" and k:sub(1, 4) == "cjk_")
            or (latin_off and LATIN_KEYS[k])
        if not skip then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = { "v" .. SCHEMA }
    for _i, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(p[k]) end
    return table.concat(parts, ";")
end

function Bionic:cachePathFor(orig)
    local attr = lfs.attributes(orig) or {}
    local _dir, fname = util.splitFilePathName(orig)
    local base = (fname:gsub("%.[^.]*$", ""):gsub("[^%w%-_]", "_")):sub(1, 40)
    local book_id = hash(orig)
    local sig = hash(self:prefsSignature(orig) .. "|" .. tostring(attr.size) .. "|" .. tostring(attr.modification))
    return string.format("%s/%s.%s.%s.epub", self:cacheDir(), base, book_id, sig), base .. "." .. book_id .. "."
end

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

function Bionic:currentFile()
    return self.ui and self.ui.document and self.ui.document.file
end

-- true when the open document is currently being rendered from a converted copy
function Bionic:isActive()
    local doc = self.ui and self.ui.document
    return doc ~= nil and (doc._bionic_file ~= nil or doc._bionic_inplace == true)
end

function Bionic:canToggle()
    local f = self:currentFile()
    if f == nil or self.ui.rolling == nil then return false end
    return self:isMoonChapter(f) or (self:isEpub(f) and not self:isCacheFile(f))
end

function Bionic:wantsBionic(file)
    local key = self:bookKey(file) -- the file itself (EPUB) or the chapter directory (月读 chapter book)
    local books = self.settings:readSetting("books", {})
    if books[key] ~= nil then return books[key] end
    if self:isMoonChapter(file) then return self.settings:isTrue("always_on_chapters") end
    return self.settings:isTrue("always_on")
end

function Bionic:setBook(orig, value)
    local books = self.settings:readSetting("books", {})
    books[orig] = value
    self.settings:saveSetting("books", books)
    self.settings:flush()
end

-- "orig" or the settings signature of the bionic rendering currently in use
function Bionic:currentSig()
    return self:isActive() and hash(self:prefsSignature(self:currentFile())) or "orig"
end

--------------------------------------------------------------------------
-- Conversion
--------------------------------------------------------------------------

local TEXT_EXT = { xhtml = true, html = true, htm = true }
local STORE_EXT = { jpg = true, jpeg = true, png = true, gif = true, webp = true, mp3 = true, mp4 = true,
                    woff = true, woff2 = true, ttf = true, otf = true }

-- returns the converted file path, or nil + error message
function Bionic:convert(orig)
    local dest, prefix = self:cachePathFor(orig)
    if lfs.attributes(dest, "mode") == "file" then return dest, nil, prefix end

    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(orig) then return nil, _("Cannot open the EPUB file.") end

    local writer = Archiver.Writer:new{}
    local tmp = dest .. ".tmp"
    if not writer:open(tmp, "epub") then
        reader:close()
        return nil, _("Cannot create the converted file.")
    end

    local opts = self:prefs(orig)
    local mtime = os.time()
    local ok, err = true, nil
    local changed_files = 0

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local path = entry.path
            if path:lower() == "meta-inf/rights.xml" then
                ok, err = false, _("This book appears to be DRM-protected; it cannot be converted.")
                break
            end
            local data = reader:extractToMemory(path)
            if not data then
                ok, err = false, _("Failed to read a file inside the EPUB.")
                break
            end
            local ext = (path:match("%.([^./]+)$") or ""):lower()
            if TEXT_EXT[ext] and Bionify.is_utf8_html(data) then
                local okt, res = pcall(Bionify.transform_html, data, opts)
                if okt then
                    data = res
                    changed_files = changed_files + 1
                else
                    logger.warn("bionic: transform failed for", path, res)
                end
            end
            writer:setZipCompression((path == "mimetype" or STORE_EXT[ext]) and "store" or "deflate")
            if not writer:addFileFromMemory(path, data, mtime) then
                ok, err = false, _("Failed to write the converted file.")
                break
            end
        end
    end
    reader:close()
    writer:close()

    if ok and changed_files == 0 then
        ok, err = false, _("No convertible text was found in this EPUB.")
    end
    if not ok then
        os.remove(tmp)
        return nil, err
    end
    os.remove(dest)
    if not os.rename(tmp, dest) then return nil, _("Cannot save the converted file.") end
    return dest, nil, prefix
end

-- delete older conversions of the same book (made with previous settings)
function Bionic:cleanupStale(current)
    local name = current:match("([^/]+)$")
    local prefix = name and name:match("^(.-%.%x+%.)%x+%.epub$")
    if not prefix then return end
    local dir = self:cacheDir()
    for f in lfs.dir(dir) do
        local full = dir .. "/" .. f
        if f:sub(1, #prefix) == prefix and full ~= current then self:removeCacheFile(full) end
    end
end

function Bionic:removeCacheFile(path)
    if self.ui and self.ui.document and self.ui.document._bionic_file == path then return false end
    pcall(function() require("docsettings"):open(path):purge() end)
    pcall(function() require("readhistory"):removeItemByPath(path) end)
    os.remove(path)
    return true
end

--------------------------------------------------------------------------
-- The hook: redirect what crengine loads, keep doc.file untouched
--------------------------------------------------------------------------

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

-- write to a side file, then rename over the target (same trick 月读 uses for its own chapters)
local function writeAtomic(path, data)
    local tmp = path .. ".bpart"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local wrote = f:write(data)
    local closed = f:close()
    if not wrote or not closed then os.remove(tmp); return false end
    if not os.rename(tmp, path) then os.remove(tmp); return false end
    return true
end

local MARKER_PATTERN = "<!%-%-bionic:(%x+)%-%->%s*$"

-- Bring one 月读 chapter file into the wanted state. Returns true when it is bionic afterwards.
--   original  --(want)-->  [backup "<n>.html.bionic"] + bionic text + trailing marker comment
--   bionic    --(!want)->  original restored from the backup
function Bionic:applyChapter(file)
    local data = readFile(file)
    if not data then return false end
    local marked = data:sub(-80):match(MARKER_PATTERN)
    local backup = file .. ".bionic"

    if not self:wantsBionic(file) then
        if marked then
            if lfs.attributes(backup, "mode") == "file" then
                if not os.rename(backup, file) then logger.warn("bionic: cannot restore", file) end
            else
                logger.warn("bionic: backup missing, cannot restore", file)
            end
        end
        return false
    end

    local sig = hash(self:prefsSignature(file))
    if marked == sig then return true end

    local original
    if marked then -- converted with other settings: start again from the original
        original = readFile(backup)
        if not original then
            logger.warn("bionic: backup missing for", file, "- keeping the current version")
            return true
        end
    else
        -- unpurchased-chapter notices are temporary documents 月读 re-fetches every time
        if data:find("<!--moon:temp-->", 1, true) then return false end
        if not Bionify.is_utf8_html(data) then return false end
        if not writeAtomic(backup, data) then
            logger.warn("bionic: cannot write backup for", file)
            return false
        end
        original = data
    end

    local okt, out = pcall(Bionify.transform_html, original, self:prefs(file))
    if not okt then
        logger.warn("bionic: transform failed for", file, out)
        if not marked then os.remove(backup) end
        return false
    end
    if not writeAtomic(file, out .. "<!--bionic:" .. sig .. "-->") then
        if not marked then os.remove(backup) end
        return false
    end
    return true
end

-- backups whose chapter 月读 has deleted (reload / clear cache) are garbage
function Bionic:sweepBackups(file)
    local dir = file:gsub("/[^/]+$", "")
    pcall(function()
        for name in lfs.dir(dir) do
            local base = name:match("^(%d+%.html)%.bionic$")
            if base and lfs.attributes(dir .. "/" .. base, "mode") ~= "file" then
                os.remove(dir .. "/" .. name)
            end
        end
    end)
end

-- Put EVERY 月读 chapter back to its original (use before uninstalling the plugin).
-- Returns restored, removed_orphans
function Bionic:restoreAllChapters()
    local restored, orphans = 0, 0
    local root = DataStorage:getDataDir() .. "/.moon/cache"
    local function each_dir(path, fn)
        local ok = pcall(function()
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then fn(name) end
            end
        end)
        return ok
    end
    each_dir(root, function(source)
        local bdir = root .. "/" .. source .. "/book"
        each_dir(bdir, function(slug)
            local dir = bdir .. "/" .. slug
            each_dir(dir, function(name)
                local base = name:match("^(%d+%.html)%.bionic$")
                if not base then return end
                local html, backup = dir .. "/" .. base, dir .. "/" .. name
                local data = readFile(html)
                if data and data:sub(-80):match(MARKER_PATTERN) then
                    if os.rename(backup, html) then restored = restored + 1 end
                else
                    os.remove(backup) -- chapter missing or already original: the backup is garbage
                    orphans = orphans + 1
                end
            end)
        end)
    end)
    self.settings:saveSetting("books", {})
    self.settings:flush()
    return restored, orphans
end

-- Remove everything this plugin ever put on the device. Returns a list of problems (empty = clean).
-- Only fixed, known paths are touched. The plugin folder itself is only removed when its name is
-- exactly "bionic.koplugin".
--
-- What the user keeps is put in koreader/bionic_save: always the text file with the highlights and
-- notes made in bionic renderings, and with keep_backup also the latest backup. All other manual
-- backups (koreader/bionic_backups) are deleted.
--
-- Returns problems, restored, text_file, exported, kept   |   nil, path (nothing was changed)
-- kept: path of the backup that was kept, false when there was none to keep
function Bionic:uninstall(keep_backup)
    local problems = {}
    local data_dir = DataStorage:getDataDir()
    -- 1) keep what the user wrote in bionic renderings; if that cannot be saved, change nothing
    local exported, text_file = self:exportBionicAnnotations()
    if exported == nil then return nil, text_file end
    -- 2) optionally keep the latest backup; if that cannot be done, change nothing
    local kept = nil
    if keep_backup then
        local ok, res, err = pcall(self.keepLatestBackup, self)
        if not ok then return nil, tostring(res) end
        if res == nil then return nil, tostring(err) end
        kept = res
    end
    -- 3) now the books can go back to the original text
    local restored = self:restoreAllChapters()
    pcall(self.restoreAnnotations, self)

    ffiUtil.purgeDir(data_dir .. "/bionic_cache")
    ffiUtil.purgeDir(self:backupRoot())
    local settings_dir = DataStorage:getSettingsDir()

    -- from now on this session does nothing and writes nothing (so no settings file reappears)
    Bionic.uninstalled = true
    self.settings.flush = function() end
    os.remove(settings_dir .. "/bionic_reading.lua")
    os.remove(settings_dir .. "/bionic_reading.lua.old")

    if PLUGIN_DIR and PLUGIN_DIR:match("/bionic%.koplugin$") then
        ffiUtil.purgeDir(PLUGIN_DIR)
        if lfs.attributes(PLUGIN_DIR, "mode") == "directory" then
            problems[#problems + 1] = PLUGIN_DIR
        end
    else
        problems[#problems + 1] = "plugins/bionic.koplugin"
    end
    logger.info("bionic: uninstalled, chapters restored:", restored, "highlights saved:", exported)
    return problems, restored, text_file, exported, kept
end

-- KOReader before 2024 shows a long title with ButtonDialogTitle, newer versions with ButtonDialog itself
local function newButtonDialog(title, buttons)
    local okt, BDT = pcall(require, "ui/widget/buttondialogtitle")
    if okt and type(BDT) == "table" then
        return BDT:new{ title = title, title_align = "left", buttons = buttons }
    end
    local BD = require("ui/widget/buttondialog")
    return BD:new{ title = title, title_align = "left", buttons = buttons }
end

function Bionic:confirmUninstall()
    local dlg
    local function go(keep)
        UIManager:close(dlg)
        UIManager:nextTick(function() self:runUninstall(keep) end)
    end
    dlg = newButtonDialog(
        _("If you uninstall Bionic Reading, your books go back to the original text. Highlights and notes made under the bionic effect may be lost, so they are saved to a text file by default. You can also keep the latest backup. The backup data and the text file are stored in koreader/bionic_save."),
        {
            { { text = _("Cancel"), callback = function() UIManager:close(dlg) end } },
            { { text = _("Uninstall"), callback = function() go(false) end } },
            { { text = _("Uninstall and keep backup"), callback = function() go(true) end } },
        })
    UIManager:show(dlg)
end

function Bionic:runUninstall(keep_backup)
    local ConfirmBox = require("ui/widget/confirmbox")
    local problems, _restored, text_file, exported, kept = self:uninstall(keep_backup)
    if not problems then
        -- the notes could not be saved, so nothing was changed
        UIManager:show(InfoMessage:new{
            text = T(_("Could not save your highlights and notes to %1. Nothing was uninstalled."), tostring(text_file)),
        })
        return
    end
    local text = #problems == 0
        and _("Bionic Reading has been uninstalled. Restart KOReader now?")
        or T(_("Almost done. Please delete this folder by hand: %1. Restart KOReader now?"), problems[1])
    if exported and exported > 0 then
        text = text .. "\n\n" .. T(_("Your highlights and notes from bionic renderings were saved to: %1"), text_file)
    end
    if keep_backup then
        if kept then
            text = text .. "\n\n" .. T(_("The latest backup was kept in: %1"), kept)
        else
            text = text .. "\n\n" .. _("There was no backup to keep (no highlights or notes were found).")
        end
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Restart"),
        cancel_text = _("Later"),
        ok_callback = function() UIManager:restartKOReader() end,
    })
end

-- called from CreDocument:loadDocument for every full load of a book.
-- returns "inplace" (chapter file now bionic), "alt", path (render this copy instead), or nil
function Bionic:resolve(file)
    if not file or Bionic.uninstalled then return nil end
    if self:isMoonChapter(file) then
        return self:applyChapter(file) and "inplace" or nil
    end
    if not self:isEpub(file) or self:isCacheFile(file) then return nil end
    if not self:wantsBionic(file) then return nil end
    local dest, err = self:convert(file)
    if not dest then
        logger.warn("bionic: conversion failed for", file, err)
        self:setBook(file, false) -- don't retry (and don't re-show the error) on every open
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{ text = err or _("Conversion failed.") })
        end)
        return nil
    end
    return "alt", dest
end

local function installHook()
    local ok, CreDocument = pcall(require, "document/credocument")
    if not ok or type(CreDocument) ~= "table" or CreDocument._bionic_hooked then return end
    local original = CreDocument.loadDocument
    if type(original) ~= "function" then return end

    CreDocument.loadDocument = function(doc, full_document)
        -- metadata-only loads (file browser, covers...) and already loaded docs: untouched
        if doc._loaded or full_document == false or not doc._document then
            return original(doc, full_document)
        end
        local okr, kind, alt = pcall(Bionic.resolve, Bionic, doc.file)
        if okr and kind == "inplace" then
            doc._bionic_inplace = true -- the file itself is already bionic; load it normally
        elseif okr and kind == "alt" and alt then
            logger.dbg("bionic: loading", alt, "in place of", doc.file)
            if doc._document:loadDocument(alt, false) then
                doc._loaded = true
                doc._bionic_file = alt
                return true
            end
            logger.warn("bionic: crengine could not load the converted file, using the original")
        elseif not okr then
            logger.warn("bionic: resolve error:", alt)
        end
        return original(doc, full_document)
    end
    CreDocument._bionic_hooked = true
end

installHook()

--------------------------------------------------------------------------
-- Toggle / events
--------------------------------------------------------------------------

function Bionic:toggle()
    if not self:canToggle() then
        UIManager:show(InfoMessage:new{ text = _("Bionic reading works on EPUB books only.") })
        return
    end
    local file = self:currentFile()
    self:setBook(self:bookKey(file), not self:isActive())
    -- onCloseDocument remembers the position, onReaderReady restores it for the new rendering
    self.ui:reloadDocument(nil, false)
end

function Bionic:reapplyIfActive()
    if self:isActive() then self.ui:reloadDocument(nil, false) end
end

function Bionic:onBionicToggle()
    self:toggle()
    return true
end

function Bionic:onDispatcherRegisterActions()
    Dispatcher:registerAction("bionic_toggle", {
        category = "none", event = "BionicToggle", title = _("Bionic reading: toggle"), reader = true,
    })
end

-- remember where we were, and in which rendering (original / bionic with these settings)
function Bionic:onCloseDocument()
    local file = self:currentFile()
    if not file or not self.ui.rolling or self:isMoonChapter(file) then return end
    local ok, pct = pcall(function() return self.ui.rolling:getLastPercent() end)
    if not ok or not pct then return end
    local positions = self.settings:readSetting("positions", {})
    positions[file] = { sig = self:currentSig(), pct = pct }
    self.settings:saveSetting("positions", positions)
    self.settings:flush()
end

-- if the rendering changed since last time, XPointers saved by the other rendering are
-- unreliable: jump by percentage instead
function Bionic:onReaderReady()
    local file = self:currentFile()
    if not file or not self.ui.rolling then return end
    if self:isMoonChapter(file) then
        -- 月读 restores the position of a chapter itself (saved fraction); just tidy up
        self:sweepBackups(file)
        return
    end
    if self.ui.document._bionic_file then self:cleanupStale(self.ui.document._bionic_file) end
    local rec = self.settings:readSetting("positions", {})[file]
    if rec and rec.pct and rec.sig ~= self:currentSig() then
        self.ui:registerPostReaderReadyCallback(function()
            if self.ui.rolling then self.ui.rolling:onGotoPercent(rec.pct * 100) end
        end)
    end
end

--------------------------------------------------------------------------
-- Highlights / notes
--
-- KOReader stores them as crengine XPointers (DOM paths + character offsets). The bionic copy
-- of a book has a different DOM from the original (extra <b> nodes, split text nodes), so an
-- XPointer made in one rendering points at the wrong place - or nowhere - in another. Offsets
-- also shift whenever a setting that changes the DOM changes (strength, saccades, stem length,
-- CJK chunking, emphasis tag, edge dimming on/off).
--
-- So every distinct DOM ("structure signature") gets its OWN set of annotations. When a book is
-- opened with a different structure than the one its sidecar annotations were made in, the
-- sidecar set is parked in our settings file and the matching parked set (if any) is put back.
-- Nothing is converted or deleted; sets only move. Colour, edge brightness value and page theme
-- do not change the DOM, so they never swap anything.
--------------------------------------------------------------------------

-- the DOM-shaping part of the settings
function Bionic:structureSig(file)
    local p = self:prefs(file)
    local cjk = "cjk=0"
    if (p.cjk_chunk or 0) > 0 then
        cjk = string.format("cjk=%g/%g/%g/%s/%s", p.cjk_chunk, p.cjk_ratio, p.cjk_saccades,
            tostring(p.cjk_style), tostring(p.cjk_edge_opacity < 100))
    end
    -- SCHEMA is part of it: a new tokenizer (apostrophes, digits...) builds a different DOM
    if p.latin_on == false then return string.format("b%d|lat=0|%s", SCHEMA, cjk) end
    return string.format("b%d|fs=%g|sa=%g|stem=%g|%s|style=%s|edge=%s", SCHEMA, p.fixation_strength,
        p.saccades, p.stem_pct, cjk, tostring(p.style), tostring(p.edge_opacity < 100))
end

function Bionic:annotationSig(document)
    local active
    if document._loaded then
        active = document._bionic_file ~= nil
    else
        active = self:wantsBionic(document.file)
    end
    return active and self:structureSig(document.file) or "orig"
end

local function countItems(list)
    return type(list) == "table" and #list or 0
end

-- Returns the number of annotations that were moved out of sight (0 = nothing swapped).
-- doc_settings is the live DocSettings of the book that is being opened.
function Bionic:syncAnnotations(doc_settings, document)
    local file = document and document.file
    -- 月读 chapters are handled by 月读 itself; cache copies are never opened as books
    if Bionic.uninstalled or not file or not self:isEpub(file) or self:isCacheFile(file) then return 0 end

    local target = self:annotationSig(document)
    local sigs = self.settings:readSetting("annot_sig", {})
    local current = sigs[file]
    if current == nil then
        -- first time we see this book: whatever is in the sidecar stays, and counts as made in
        -- the rendering that is open now
        sigs[file] = target
        self.settings:saveSetting("annot_sig", sigs)
        self.settings:flush()
        return 0
    end
    if current == target then return 0 end

    local live = doc_settings:readSetting("annotations")
    local store = self.settings:readSetting("annot_store", {})
    local sets = store[file] or {}
    local incoming = sets[target]

    -- 1) park the sidecar set under the structure it belongs to, take the matching one out;
    --    persist our side FIRST so that a crash can never lose a set
    sets[target] = nil
    if live ~= nil and countItems(live) > 0 then sets[current] = live else sets[current] = nil end
    store[file] = next(sets) ~= nil and sets or nil
    sigs[file] = target
    self.settings:saveSetting("annot_store", store)
    self.settings:saveSetting("annot_sig", sigs)
    self.settings:flush()

    -- 2) put the matching set (or an empty one) in the sidecar. A book that has no "annotations"
    --    at all keeps none, so KOReader's own old-format migration is not disturbed.
    if live ~= nil or incoming ~= nil then
        doc_settings:saveSetting("annotations", incoming or {})
    end
    return countItems(live)
end

-- KOReader sends this to every module right after it opened the book's sidecar and BEFORE any
-- module (ReaderAnnotation included) reads it.
function Bionic:onDocSettingsLoad(doc_settings, document)
    local ok, moved = pcall(self.syncAnnotations, self, doc_settings, document)
    if not ok then
        logger.warn("bionic: annotation sync failed:", moved)
        return
    end
    if moved and moved > 0 then
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{
                text = T(_("%1 highlights/notes belong to a different bionic rendering of this book. They are kept and will come back when you switch back."), moved),
                timeout = 6,
            })
        end)
    end
end

-- Highlights and notes made in a bionic rendering cannot be moved into the original text (their
-- positions only exist in the converted text). Before they are removed they are written to a
-- plain text file so that what the user wrote is not lost.
function Bionic:backupDir()
    local data_dir = DataStorage:getDataDir()
    local docs = (data_dir:gsub("/[^/]+$", "")) .. "/documents"
    if lfs.attributes(docs, "mode") == "directory" then return docs end
    return data_dir
end

-- every highlight/note that exists only for a bionic rendering: the parked sets, plus the set in
-- the sidecar when the book was last read in a bionic rendering. Read-only.
function Bionic:collectBionicAnnotations()
    local sigs = self.settings:readSetting("annot_sig", {})
    local store = self.settings:readSetting("annot_store", {})
    local okds, DocSettings = pcall(require, "docsettings")
    local names, seen = {}, {}
    for f in pairs(sigs) do if not seen[f] then seen[f] = true; names[#names + 1] = f end end
    for f in pairs(store) do if not seen[f] then seen[f] = true; names[#names + 1] = f end end
    table.sort(names)
    local books = {}
    for _i, file in ipairs(names) do
        local lists = {}
        for psig, items in pairs(store[file] or {}) do
            if psig ~= "orig" and type(items) == "table" then lists[#lists + 1] = items end
        end
        local sig = sigs[file]
        if okds and sig ~= nil and sig ~= "orig" and lfs.attributes(file, "mode") == "file" then
            local ok, live = pcall(function() return DocSettings:open(file):readSetting("annotations") end)
            if ok and type(live) == "table" then lists[#lists + 1] = live end
        end
        local entries = {}
        for _j, items in ipairs(lists) do
            for _k, it in ipairs(items) do
                if type(it) == "table" and (it.text or it.note) then entries[#entries + 1] = it end
            end
        end
        if #entries > 0 then
            table.sort(entries, function(a, b) return tostring(a.datetime or "") < tostring(b.datetime or "") end)
            books[#books + 1] = { file = file, entries = entries }
        end
    end
    return books
end

-- koreader/bionic_save: what the uninstaller leaves behind. Created at uninstall time, and only
-- when there is something to put in it.
function Bionic:saveDir()
    return DataStorage:getDataDir() .. "/bionic_save"
end

-- returns count, path (count 0: nothing to save, no file written) or nil, path when the file
-- could not be written. The file goes to koreader/bionic_save.
function Bionic:exportBionicAnnotations()
    local books = self:collectBionicAnnotations()
    local total = 0
    local out = { "Bionic Reading - highlights and notes made while reading a bionic version",
                  "Saved " .. os.date("%Y-%m-%d %H:%M"), "" }
    for _i, book in ipairs(books) do
        out[#out + 1] = "== " .. book.file .. " =="
        for _j, it in ipairs(book.entries) do
            total = total + 1
            local head = {}
            if it.chapter and it.chapter ~= "" then head[#head + 1] = "[" .. tostring(it.chapter) .. "]" end
            if it.datetime then head[#head + 1] = tostring(it.datetime) end
            out[#out + 1] = string.format("#%d %s", total, table.concat(head, " "))
            if it.text and it.text ~= "" then
                out[#out + 1] = "  Text: " .. tostring(it.text):gsub("\n", "\n        ")
            end
            if it.note and it.note ~= "" then
                out[#out + 1] = "  Note: " .. tostring(it.note):gsub("\n", "\n        ")
            end
            out[#out + 1] = ""
        end
    end
    if total == 0 then return 0 end
    util.makePath(self:saveDir())
    local path = self:saveDir() .. "/bionic_highlights_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
    local f = io.open(path, "w")
    if not f then return nil, path end
    local ok = f:write(table.concat(out, "\n"), "\n")
    local closed = f:close()
    if not ok or not closed then
        os.remove(path)
        return nil, path
    end
    return total, path
end

-- Uninstall helper: books go back to the original text. A book that was last read in a bionic
-- rendering has bionic positions in its sidecar: replace them with the highlights it had in the
-- original text (or none). Call exportBionicAnnotations() first. Returns the number of books changed.
function Bionic:restoreAnnotations()
    local sigs = self.settings:readSetting("annot_sig", {})
    local store = self.settings:readSetting("annot_store", {})
    local n = 0
    local okds, DocSettings = pcall(require, "docsettings")
    if not okds then return 0 end
    for file, sig in pairs(sigs) do
        if sig ~= "orig" and lfs.attributes(file, "mode") == "file" then
            local orig = store[file] and store[file].orig
            local ok = pcall(function()
                local ds = DocSettings:open(file)
                -- a book without any "annotations" has nothing to replace (and keeps KOReader's own migration)
                if ds:readSetting("annotations") ~= nil then
                    ds:saveSetting("annotations", orig or {})
                    ds:flush()
                end
            end)
            if ok then n = n + 1 end
        end
    end
    return n
end

--------------------------------------------------------------------------
-- Menu
--------------------------------------------------------------------------

local function dirSize(dir)
    local total, count = 0, 0
    for f in lfs.dir(dir) do
        local a = lfs.attributes(dir .. "/" .. f)
        if a and a.mode == "file" then total = total + a.size; count = count + 1 end
    end
    return total, count
end

function Bionic:spinItem(fmt, key, min, max, step, default, opts)
    opts = opts or {}
    local function shown()
        local v = self:viewPrefs()[key]
        if opts.to_ui then v = opts.to_ui(v) end
        return v
    end
    return {
        text_func = function()
            local v = shown()
            if opts.zero_text and v == 0 then return T(_(fmt), _(opts.zero_text)) end
            return T(_(fmt), v)
        end,
        enabled_func = opts.enabled,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text = _(opts.title),
                info_text = opts.info and _(opts.info) or nil,
                value = shown(), value_min = min, value_max = max, value_step = step,
                default_value = opts.to_ui and opts.to_ui(default) or default,
                ok_always_enabled = true,
                callback = function(spin)
                    local nv = spin.value
                    if opts.from_ui then nv = opts.from_ui(nv) end
                    self:applyPref(key, nv, touchmenu_instance)
                end,
            })
        end,
    }
end

function Bionic:lang()
    return self.settings:readSetting("lang") or I18n.detect()
end

local STYLE_LABELS = {
    bold = "Bold", semibold = "Semi-bold (font dependent)", heavy = "Extra bold (font dependent)",
    underline = "Underline", bold_underline = "Bold + underline", italic = "Italic",
}
local COLOR_LABELS = {
    red = "Red", blue = "Blue", green = "Green", orange = "Orange", purple = "Purple", brown = "Brown",
}

-- radio list of one pref: items = { {id, label}, ... }
function Bionic:radioItems(key, items)
    local out = {}
    for _i, it in ipairs(items) do
        local id, label = it[1], it[2]
        out[#out + 1] = {
            text_func = function() return _(label) end,
            radio = true,
            keep_menu_open = true,
            checked_func = function() return self:viewPrefs()[key] == id end,
            callback = function(touchmenu_instance)
                self:applyPref(key, id, touchmenu_instance)
            end,
        }
    end
    return out
end

-- emphasis style / colour items for one script. prefix = "" (English) or "cjk_" (Chinese)
function Bionic:lookItems(prefix, enabled)
    local k_style, k_on, k_color = prefix .. "style", prefix .. "color_on", prefix .. "color"
    local styles, colors = {}, {}
    for _i, id in ipairs(Bionify.STYLES) do styles[#styles + 1] = { id, STYLE_LABELS[id] } end
    for _i, c in ipairs(Bionify.COLORS) do colors[#colors + 1] = { c.id, COLOR_LABELS[c.id] } end
    return {
        {
            text_func = function()
                return T(_("Emphasis style: %1"), _(STYLE_LABELS[self:viewPrefs()[k_style]] or STYLE_LABELS.bold))
            end,
            enabled_func = enabled,
            keep_menu_open = true,
            sub_item_table = self:radioItems(k_style, styles),
        },
        {
            text_func = function() return _("Emphasis colour (colour screens)") end,
            enabled_func = enabled,
            checked_func = function() return self:viewPrefs()[k_on] == true end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:applyPref(k_on, not (self:viewPrefs()[k_on] == true), touchmenu_instance)
            end,
        },
        {
            text_func = function()
                return T(_("Colour: %1"), _(COLOR_LABELS[self:viewPrefs()[k_color]] or COLOR_LABELS.red))
            end,
            enabled_func = enabled,
            keep_menu_open = true,
            sub_item_table = self:radioItems(k_color, colors),
        },
    }
end

-- English and other Latin-script text (also Greek / Cyrillic)
function Bionic:latinItems()
    local D = Bionify.DEFAULTS
    local on = function() return self:viewPrefs().latin_on ~= false end
    local items = {
        {
            text_func = function() return _("Bionic effect on English text") end,
            checked_func = on,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:applyPref("latin_on", not on(), touchmenu_instance)
            end,
            separator = true,
        },
        self:spinItem("Fixation strength: %1", "fixation_strength", 1, 4, 1, D.fixation_strength, {
            title = "Fixation strength", enabled = on,
            info = "How much of each word is emphasised (1 = least, 4 = whole word stem)." }),
        self:spinItem("Saccades interval: %1", "saccades", 0, 4, 1, D.saccades, {
            title = "Saccades interval", enabled = on,
            info = "Words left un-emphasised between emphasised words. 0 = every word." }),
        self:spinItem("Word stem length: %1%", "stem_pct", 30, 100, 5, D.stem_pct, {
            title = "Word stem length (%)", enabled = on,
            info = "Share of a longer word that can be emphasised. Default is 70.",
            to_ui = function(v) return math.floor(v * 100 + 0.5) end,
            from_ui = function(v) return v / 100 end }),
        self:spinItem("Edge opacity: %1%", "edge_opacity", 20, 100, 10, D.edge_opacity, {
            title = "Edge opacity (%)", enabled = on,
            info = "Brightness of the un-emphasised part of words. 100 = unchanged (best for e-ink)." }),
    }
    for _i, it in ipairs(self:lookItems("", on)) do items[#items + 1] = it end
    items[#items].separator = true
    items[#items + 1] = self:presetMenuItem("latin")
    return items
end

-- Chinese / Japanese / Korean: independent settings, off until a chunk size is chosen
function Bionic:cjkItems()
    local D = Bionify.DEFAULTS
    local on = function() return (self:viewPrefs().cjk_chunk or 0) > 0 end
    local items = {
        self:spinItem("Bionic effect on Chinese text: %1", "cjk_chunk", 0, 6, 1, D.cjk_chunk, {
            title = "Chunk size", zero_text = "off",
            info = "Chinese/Japanese/Korean have no spaces, so words cannot be detected. If set to N, every N characters are treated as one 'word'. 0 = leave CJK text alone." }),
        self:spinItem("Emphasised share: %1%", "cjk_ratio", 20, 80, 10, D.cjk_ratio, {
            title = "Emphasised share (%)", enabled = on,
            info = "Share of each chunk that is emphasised. 50 = the first half.",
            to_ui = function(v) return math.floor(v * 100 + 0.5) end,
            from_ui = function(v) return v / 100 end }),
        self:spinItem("Saccades interval: %1", "cjk_saccades", 0, 4, 1, D.cjk_saccades, {
            title = "Saccades interval", enabled = on,
            info = "Chunks left un-emphasised between emphasised chunks. 0 = every chunk." }),
        self:spinItem("Edge opacity: %1%", "cjk_edge_opacity", 20, 100, 10, D.cjk_edge_opacity, {
            title = "Edge opacity (%)", enabled = on,
            info = "Brightness of the un-emphasised part of each chunk. 100 = unchanged." }),
    }
    for _i, it in ipairs(self:lookItems("cjk_", on)) do items[#items + 1] = it end
    items[#items].separator = true
    items[#items + 1] = self:presetMenuItem("cjk")
    return items
end

--------------------------------------------------------------------------
-- Export the bionic EPUB
--
-- The converted EPUB is what KOReader reads. Export copies it to a visible folder (with
-- " (Bionic)" added to the book title inside the file, so it does not collide with the original
-- in a library the file is copied into).
--------------------------------------------------------------------------

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

function Bionic:exportDir()
    local d = trim(self.settings:readSetting("export_dir"))
    if d ~= "" then return (d:gsub("/+$", "")) end
    return self:backupDir() .. "/bionic_export"
end

function Bionic:canExport()
    local file = self:currentFile()
    return file ~= nil and self:isEpub(file) and not self:isCacheFile(file) and not self:isMoonChapter(file)
end

function Bionic:exportEpub()
    local file = self:currentFile()
    if not self:canExport() then
        UIManager:show(InfoMessage:new{ text = _("Only EPUB books can be exported.") })
        return
    end
    local busy = InfoMessage:new{ text = _("Preparing the bionic EPUB…") }
    UIManager:show(busy)
    UIManager:forceRePaint()
    local converted, err = self:convert(file)
    local out, e
    if converted then
        local dir = self:exportDir()
        if lfs.attributes(dir, "mode") ~= "directory" then util.makePath(dir) end
        if lfs.attributes(dir, "mode") ~= "directory" then
            e = T(_("Cannot create the export folder: %1"), dir)
        else
            out = dir .. "/" .. Export.export_name(file)
            local suffix = self.settings:readSetting("export_suffix") ~= false and Export.TITLE_SUFFIX or ""
            local ok
            if suffix == "" then ok, e = Export.copy_file(converted, out)
            else ok, e = Export.repack(converted, out, suffix, STORE_EXT) end
            if not ok then out = nil end
        end
    else
        e = err
    end
    UIManager:close(busy)
    if not out then
        UIManager:show(InfoMessage:new{ text = T(_("Export failed: %1"), tostring(e)) })
        return
    end
    self:afterExport(out)
end

function Bionic:afterExport(out)
    UIManager:show(InfoMessage:new{ text = T(_("Exported to: %1"), out) })
end

function Bionic:exportFolderDialog(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Export folder"),
        input = self:exportDir(),
        input_hint = _("Folder for exported EPUB files"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Default"), callback = function()
                self.settings:delSetting("export_dir"); self.settings:flush()
                UIManager:close(dlg)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local d = trim(dlg:getInputText()):gsub("/+$", "")
                if d == "" then self.settings:delSetting("export_dir") else self.settings:saveSetting("export_dir", d) end
                self.settings:flush()
                UIManager:close(dlg)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Bionic:exportItems()
    return {
        {
            text_func = function() return _("Export bionic EPUB") end,
            enabled_func = function() return self:canExport() end,
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                UIManager:nextTick(function() self:exportEpub() end)
            end,
        },
        {
            text_func = function() return _("Add \"(Bionic)\" to the book title in the exported file") end,
            checked_func = function() return self.settings:readSetting("export_suffix") ~= false end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.settings:saveSetting("export_suffix", not (self.settings:readSetting("export_suffix") ~= false))
                self.settings:flush()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function() return T(_("Export folder: %1"), self:exportDir()) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:exportFolderDialog(touchmenu_instance) end,
        },
    }
end

--------------------------------------------------------------------------
-- Presets: named copies of the English settings or of the Chinese settings
--------------------------------------------------------------------------
-- Each script has its own list, so an English preset never touches the Chinese settings and the
-- other way round. A preset stores what the settings menu shows right now (the open book's own
-- settings when it has any, otherwise the global ones) and applies to the same place.
-- A preset never switches the bionic effect on or off: the user does that by hand and then picks
-- a preset. So the English switch is not stored at all, and the Chinese chunk size - which is
-- also the Chinese switch (0 = off) - is only applied while the Chinese effect is already on.
-- Stored in the plugin's settings file under "presets" = { latin = { {name=, values=} ... }, cjk = ... }.

local PRESET_KEYS = {
    latin = { "fixation_strength", "saccades", "stem_pct", "edge_opacity", "style", "color_on", "color" },
    cjk = { "cjk_chunk", "cjk_ratio", "cjk_saccades", "cjk_edge_opacity", "cjk_style", "cjk_color_on", "cjk_color" },
}

local function sameValue(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-9 end
    return a == b
end

function Bionic:presetList(kind)
    local list = self.settings:readSetting("presets", {})[kind]
    return type(list) == "table" and list or {}
end

function Bionic:currentPresetValues(kind)
    local p, v = self:viewPrefs(), {}
    for _i, k in ipairs(PRESET_KEYS[kind]) do v[k] = p[k] end
    if kind == "cjk" and (p.cjk_chunk or 0) <= 0 then v.cjk_chunk = nil end -- switched off: nothing to store
    return v
end

-- what a preset really changes right now: only its own keys, and never a switch
function Bionic:presetToApply(kind, values)
    local out = {}
    for _i, k in ipairs(PRESET_KEYS[kind]) do
        if values[k] ~= nil then out[k] = values[k] end
    end
    if kind == "cjk" then
        local chunk = values.cjk_chunk
        if (self:viewPrefs().cjk_chunk or 0) > 0 and type(chunk) == "number" and chunk > 0 then
            out.cjk_chunk = chunk
        else
            out.cjk_chunk = nil
        end
    end
    return out
end

-- true when everything the preset stores is what the menu shows now (drives the tick)
function Bionic:presetMatches(kind, values)
    local p = self:viewPrefs()
    for k, v in pairs(self:presetToApply(kind, values)) do
        if not sameValue(p[k], v) then return false end
    end
    return true
end

-- returns the name used, and true when an existing preset of that name was replaced
function Bionic:savePreset(kind, name)
    name = trim(name)
    local list = self:presetList(kind)
    if name == "" then
        local n = #list + 1
        local function taken(nm)
            for _i, p in ipairs(list) do if p.name == nm then return true end end
            return false
        end
        name = T(_("Preset %1"), n)
        while taken(name) do n = n + 1; name = T(_("Preset %1"), n) end
    end
    local values = self:currentPresetValues(kind)
    local replaced = false
    for _i, p in ipairs(list) do
        if p.name == name then p.values = values; replaced = true end
    end
    if not replaced then list[#list + 1] = { name = name, values = values } end
    local all = self.settings:readSetting("presets", {})
    all[kind] = list
    self.settings:saveSetting("presets", all)
    self.settings:flush()
    return name, replaced
end

function Bionic:deletePreset(kind, name)
    local list, kept, found = self:presetList(kind), {}, false
    for _i, p in ipairs(list) do
        if p.name == name then found = true else kept[#kept + 1] = p end
    end
    if not found then return false end
    local all = self.settings:readSetting("presets", {})
    all[kind] = kept
    self.settings:saveSetting("presets", all)
    self.settings:flush()
    return true
end

-- like applyPref, for several settings at once; the open book is only re-rendered when the
-- converted text really changes
function Bionic:applyPreset(kind, values, touchmenu_instance)
    local file = self:currentFile()
    local before = file and hash(self:prefsSignature(file))
    self:setPrefs(self:presetToApply(kind, values))
    if touchmenu_instance then touchmenu_instance:updateItems() end
    if file and hash(self:prefsSignature(file)) ~= before then self:reapplyIfActive() end
end

function Bionic:presetNameDialog(kind, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Name this preset"),
        input = "",
        input_hint = T(_("Preset name (empty = %1)"), T(_("Preset %1"), #self:presetList(kind) + 1)),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = trim(dlg:getInputText())
                UIManager:close(dlg)
                local used, replaced = self:savePreset(kind, name)
                -- the list is built when the menu opens, so close the menu: it is up to date next time
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                UIManager:show(InfoMessage:new{
                    text = T(replaced and _("Preset updated: %1") or _("Preset saved: %1"), used),
                })
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Bionic:confirmDeletePreset(kind, name, touchmenu_instance)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete preset \"%1\"?"), name),
        ok_text = _("Delete"),
        ok_callback = function()
            self:deletePreset(kind, name)
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            UIManager:show(InfoMessage:new{ text = _("Preset deleted.") })
        end,
    })
end

function Bionic:presetItems(kind)
    local items = {
        {
            text_func = function() return _("Save current settings as preset…") end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:presetNameDialog(kind, touchmenu_instance) end,
            separator = true,
        },
    }
    -- built in: the plugin's own defaults, so there is always a way back
    local defaults = {}
    for _i, k in ipairs(PRESET_KEYS[kind]) do defaults[k] = Bionify.DEFAULTS[k] end
    items[#items + 1] = {
        text_func = function() return _("Default settings") end,
        keep_menu_open = true,
        checked_func = function() return self:presetMatches(kind, defaults) end,
        callback = function(touchmenu_instance) self:applyPreset(kind, defaults, touchmenu_instance) end,
    }
    local list = self:presetList(kind)
    for _i, p in ipairs(list) do
        items[#items + 1] = {
            text_func = function() return p.name end,
            keep_menu_open = true,
            checked_func = function() return self:presetMatches(kind, p.values) end,
            callback = function(touchmenu_instance) self:applyPreset(kind, p.values, touchmenu_instance) end,
        }
    end
    local del = {}
    for _i, p in ipairs(list) do
        del[#del + 1] = {
            text_func = function() return p.name end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:confirmDeletePreset(kind, p.name, touchmenu_instance) end,
        }
    end
    items[#items].separator = true
    items[#items + 1] = {
        text_func = function() return _("Delete preset") end,
        enabled_func = function() return #list > 0 end,
        keep_menu_open = true,
        sub_item_table = #del > 0 and del or { { text_func = function() return _("No presets yet") end,
                                                 enabled_func = function() return false end } },
    }
    return items
end

function Bionic:presetMenuItem(kind)
    local count = #self:presetList(kind)
    return {
        text_func = function() return T(_("Presets (%1)"), count) end,
        keep_menu_open = true,
        sub_item_table = self:presetItems(kind),
    }
end

--------------------------------------------------------------------------
-- Manual backups of highlights and notes
--------------------------------------------------------------------------
-- <data dir>/bionic_backups/<id>/info.lua    name, date, counts (small; this is what the list reads)
--                                 backup.lua  the annotations of every book + this plugin's parked sets
--                                 backup.txt  the same highlights and notes as readable text
-- <id> is the date and time (YYYYmmdd_HHMMSS). The name the user typed is stored inside info.lua,
-- so it may contain any characters. Updates of KOReader / this plugin and the uninstaller never
-- touch this folder.

local BACKUP_ANNOT_KEYS = { "annotations", "highlight", "bookmarks" }

function Bionic:backupRoot()
    return DataStorage:getDataDir() .. "/bionic_backups"
end

-- plain tree copy, so that no table is shared between two places of what gets written
local function treeCopy(v, depth)
    if type(v) ~= "table" then return v end
    depth = depth or 0
    if depth > 20 then return nil end
    local out = {}
    for k, x in pairs(v) do
        if type(x) ~= "function" and type(x) ~= "userdata" and type(x) ~= "thread" then
            out[k] = treeCopy(x, depth + 1)
        end
    end
    return out
end

local function countAnnotations(data)
    local n = 0
    if type(data.annotations) == "table" then
        n = #data.annotations
    elseif type(data.highlight) == "table" then -- old KOReader format: { [page] = { ... } }
        for _k, list in pairs(data.highlight) do
            if type(list) == "table" then n = n + #list end
        end
    end
    return n
end

local function fileHasContent(path)
    local a = lfs.attributes(path)
    return a ~= nil and a.mode == "file" and (a.size or 0) > 0
end

-- every book that may have highlights: the reading history, the books this plugin has seen and
-- the open book. Cache copies and online-source chapters are left out.
function Bionic:backupBookFiles()
    local files, seen = {}, {}
    local function add(f)
        if type(f) ~= "string" or seen[f] then return end
        seen[f] = true
        if self:isCacheFile(f) or self:isMoonChapter(f) then return end
        if lfs.attributes(f, "mode") ~= "file" then return end
        files[#files + 1] = f
    end
    local okh, ReadHistory = pcall(require, "readhistory")
    if okh and type(ReadHistory) == "table" and type(ReadHistory.hist) == "table" then
        for _i, item in ipairs(ReadHistory.hist) do add(item.file) end
    end
    for f in pairs(self.settings:readSetting("annot_sig", {})) do add(f) end
    for f in pairs(self.settings:readSetting("annot_store", {})) do add(f) end
    local doc = self.ui and self.ui.document
    if doc then add(doc.file) end
    table.sort(files)
    return files
end

-- the annotations of one book (nil when it has none)
function Bionic:backupReadBook(file)
    local data, props = {}, nil
    local okd, DocSettings = pcall(require, "docsettings")
    if okd then
        local okr = pcall(function()
            local ds = DocSettings:open(file)
            for _i, key in ipairs(BACKUP_ANNOT_KEYS) do
                local v = ds:readSetting(key)
                if v ~= nil then data[key] = v end
            end
            props = ds:readSetting("doc_props")
        end)
        if not okr then data, props = {}, nil end
    end
    -- the book that is open: what is on screen is newer than its sidecar on disk
    local doc = self.ui and self.ui.document
    if doc and doc.file == file and self.ui.annotation and type(self.ui.annotation.annotations) == "table" then
        data.annotations = self.ui.annotation.annotations
    end
    local n = countAnnotations(data)
    if n == 0 then return nil end
    data = treeCopy(data)
    local title = type(props) == "table" and props.title or nil
    if type(title) ~= "string" or title == "" then title = (file:match("([^/]+)$") or file) end
    return { annotations = data, title = title, count = n }
end

local function indentLines(s)
    return (tostring(s):gsub("\n", "\n        "))
end

-- Returns notes, books, name, dir  |  0 (nothing to back up)  |  nil, error
function Bionic:createBackup(name)
    local now = os.time()
    name = trim(name)
    if name == "" then name = os.date("%Y-%m-%d %H:%M", now) end

    local books, text = {}, {}
    local nbooks, nnotes = 0, 0
    for _i, file in ipairs(self:backupBookFiles()) do
        local b = self:backupReadBook(file)
        if b then
            nbooks = nbooks + 1
            nnotes = nnotes + b.count
            books[file] = { title = b.title, count = b.count, data = b.annotations }
            text[#text + 1] = "== " .. b.title .. " ==\n" .. file
            local list = b.annotations.annotations
            if type(list) == "table" then
                local sorted = {}
                for _j, it in ipairs(list) do if type(it) == "table" then sorted[#sorted + 1] = it end end
                table.sort(sorted, function(x, y) return tostring(x.datetime or "") < tostring(y.datetime or "") end)
                for j, it in ipairs(sorted) do
                    local head = {}
                    if it.chapter and it.chapter ~= "" then head[#head + 1] = "[" .. tostring(it.chapter) .. "]" end
                    if it.datetime then head[#head + 1] = tostring(it.datetime) end
                    text[#text + 1] = string.format("#%d %s", j, table.concat(head, " "))
                    if it.text and it.text ~= "" then text[#text + 1] = "  Text: " .. indentLines(it.text) end
                    if it.note and it.note ~= "" then text[#text + 1] = "  Note: " .. indentLines(it.note) end
                end
            else
                text[#text + 1] = "(old KOReader format: see backup.lua)"
            end
            text[#text + 1] = ""
        end
    end
    if nnotes == 0 then return 0 end

    local root = self:backupRoot()
    local id0 = os.date("%Y%m%d_%H%M%S", now)
    local id, dir, k = id0, root .. "/" .. id0, 1
    while lfs.attributes(dir, "mode") ~= nil do
        k = k + 1
        id = id0 .. "_" .. k
        dir = root .. "/" .. id
    end
    util.makePath(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then return nil, dir end

    local function fail(what)
        ffiUtil.purgeDir(dir)
        return nil, what
    end

    -- 1) the restorable copy
    local data_file = LuaSettings:open(dir .. "/backup.lua")
    data_file:saveSetting("name", name)
    data_file:saveSetting("created", now)
    data_file:saveSetting("books", books)
    data_file:saveSetting("plugin", {
        annot_sig = treeCopy(self.settings:readSetting("annot_sig", {})),
        annot_store = treeCopy(self.settings:readSetting("annot_store", {})),
    })
    data_file:flush()
    if not fileHasContent(dir .. "/backup.lua") then return fail(dir .. "/backup.lua") end

    -- 2) the readable copy
    local f = io.open(dir .. "/backup.txt", "w")
    if not f then return fail(dir .. "/backup.txt") end
    local head = string.format("Bionic Reading - backup \"%s\"\nCreated %s\n%d books, %d highlights/notes\n\n",
        name, os.date("%Y-%m-%d %H:%M", now), nbooks, nnotes)
    local wrote = f:write(head, table.concat(text, "\n"), "\n")
    local closed = f:close()
    if not wrote or not closed then return fail(dir .. "/backup.txt") end

    -- 3) the small info file LAST: a backup that was interrupted never shows up in the list
    local info = LuaSettings:open(dir .. "/info.lua")
    info:saveSetting("name", name)
    info:saveSetting("created", now)
    info:saveSetting("books", nbooks)
    info:saveSetting("notes", nnotes)
    info:flush()
    if not fileHasContent(dir .. "/info.lua") then return fail(dir .. "/info.lua") end

    return nnotes, nbooks, name, dir
end

-- newest first
function Bionic:listBackups()
    local list = {}
    local root = self:backupRoot()
    if lfs.attributes(root, "mode") ~= "directory" then return list end
    for id in lfs.dir(root) do
        local info_path = root .. "/" .. id .. "/info.lua"
        if id:match("^[%w_]+$") and lfs.attributes(info_path, "mode") == "file" then
            local ok, s = pcall(LuaSettings.open, LuaSettings, info_path)
            if ok and s then
                list[#list + 1] = {
                    id = id,
                    name = s:readSetting("name") or id,
                    created = s:readSetting("created") or 0,
                    books = s:readSetting("books") or 0,
                    notes = s:readSetting("notes") or 0,
                }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.created ~= b.created then return a.created > b.created end
        return a.id > b.id
    end)
    return list
end

function Bionic:deleteBackup(b)
    if not (b and type(b.id) == "string" and b.id:match("^[%w_]+$")) then return false end
    local dir = self:backupRoot() .. "/" .. b.id
    if lfs.attributes(dir, "mode") ~= "directory" then return true end
    ffiUtil.purgeDir(dir)
    return lfs.attributes(dir, "mode") == nil
end

local function copyFile(src, dst)
    local fi = io.open(src, "rb")
    if not fi then return false end
    local data = fi:read("*a")
    fi:close()
    local fo = io.open(dst, "wb")
    if not fo then return false end
    local ok = fo:write(data)
    local closed = fo:close()
    return (ok and closed) and true or false
end

-- Uninstall helper: the latest backup goes to koreader/bionic_save/backup_<id>/. A fresh backup is
-- made first, because that is the newest one there can be; when there is nothing to back up (no
-- highlights at all) the newest existing backup is kept instead.
-- To use it again later, copy that folder into koreader/bionic_backups/.
-- Returns the path of the kept folder, false when there is nothing to keep, nil + path on failure.
function Bionic:keepLatestBackup()
    local notes, books, _shown, dir = self:createBackup(_("Before uninstall"))
    if notes == nil then return nil, books end
    if notes == 0 then
        local list = self:listBackups()
        if #list == 0 then return false end
        dir = self:backupRoot() .. "/" .. list[1].id
    end
    local id = dir:match("([^/]+)$")
    util.makePath(self:saveDir())
    local target, k = self:saveDir() .. "/backup_" .. id, 1
    while lfs.attributes(target, "mode") ~= nil do
        k = k + 1
        target = self:saveDir() .. "/backup_" .. id .. "_" .. k
    end
    if not os.rename(dir, target) then
        -- another file system or similar: copy the three files instead
        util.makePath(target)
        for _i, name in ipairs({ "backup.lua", "backup.txt", "info.lua" }) do
            if lfs.attributes(dir .. "/" .. name, "mode") == "file"
                and not copyFile(dir .. "/" .. name, target .. "/" .. name) then
                ffiUtil.purgeDir(target)
                return nil, target
            end
        end
        if not fileHasContent(target .. "/backup.lua") then
            ffiUtil.purgeDir(target)
            return nil, target
        end
    end
    return target
end

function Bionic:runBackup(name, touchmenu_instance)
    local info = InfoMessage:new{ text = _("Backing up…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok, notes, books, shown, dir = pcall(self.createBackup, self, name)
    UIManager:close(info)
    local text
    if not ok then
        logger.warn("bionic: backup failed:", notes)
        text = T(_("Backup failed: %1"), tostring(notes))
    elseif notes == 0 then
        text = _("Nothing to back up: no highlights or notes were found.")
    elseif notes == nil then
        text = T(_("Backup failed: %1"), tostring(books))
    else
        text = T(_("Backed up %1 highlights/notes from %2 books as \"%3\".\nSaved in: %4"), notes, books, shown, dir)
    end
    UIManager:show(InfoMessage:new{ text = text })
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

function Bionic:backupNowDialog(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local default_name = os.date("%Y-%m-%d %H:%M")
    local dlg
    dlg = InputDialog:new{
        title = _("Name this backup"),
        input = "",
        input_hint = T(_("Backup name (empty = %1)"), default_name),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Back up"), is_enter_default = true, callback = function()
                local name = trim(dlg:getInputText())
                UIManager:close(dlg)
                UIManager:nextTick(function() self:runBackup(name, touchmenu_instance) end)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Bionic:confirmDeleteBackup(b, touchmenu_instance)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete backup \"%1\"?\n%2 books, %3 highlights/notes, made %4."),
            b.name, b.books, b.notes, os.date("%Y-%m-%d %H:%M", b.created)),
        ok_text = _("Delete"),
        ok_callback = function()
            local text = self:deleteBackup(b) and _("Backup deleted.") or _("Could not delete the backup.")
            -- the list is built when the menu opens, so close the menu: it is up to date next time
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            UIManager:show(InfoMessage:new{ text = text })
        end,
    })
end

function Bionic:confirmDeleteAllBackups(touchmenu_instance)
    local ConfirmBox = require("ui/widget/confirmbox")
    local list = self:listBackups()
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete all %1 backups? This cannot be undone."), #list),
        ok_text = _("Delete"),
        ok_callback = function()
            local deleted = 0
            for _i, b in ipairs(list) do
                if self:deleteBackup(b) then deleted = deleted + 1 end
            end
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            UIManager:show(InfoMessage:new{ text = T(_("Deleted %1 backups."), deleted) })
        end,
    })
end

--------------------------------------------------------------------------
-- Restoring a backup
--
-- Only ADDS what is missing from the books: nothing that is already there is removed or changed.
-- A highlight counts as the same one when position, date, text and note are all equal.
-- Each highlight goes back to where it belongs under the "one set per structure signature"
-- rule (see the annotation section): into the sidecar when it was made in the rendering the
-- sidecar belongs to, otherwise into the parked sets of this plugin.
-- Only done while no book is open, because an open book writes its own highlights back to the
-- sidecar when it is closed.
--------------------------------------------------------------------------

local function keyPart(v)
    if type(v) ~= "table" then return tostring(v == nil and "" or v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _i, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. keyPart(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function annotKey(it)
    return table.concat({ keyPart(it.page), keyPart(it.pos0), keyPart(it.pos1),
                          keyPart(it.datetime), keyPart(it.text), keyPart(it.note) }, "\31")
end

-- position in the book: crengine XPointers like /body/DocFragment[3]/body/div/p[7]/text().15
local function xpointerSteps(x)
    local t = {}
    for tok in tostring(x):gmatch("[^/]+") do
        local name, idx = tok:match("^([^%[]+)%[(%d+)%]$")
        if name then
            t[#t + 1] = { name, tonumber(idx) }
        else
            local off = tok:match("^text%(%)%.(%d+)$")
            t[#t + 1] = off and { "text()", tonumber(off) } or { tok, 1 }
        end
    end
    return t
end

-- <0 / >0 when the order of a and b is known, 0 when it cannot be told
local function comparePositions(a, b)
    local x, y = a.pos0 or a.page, b.pos0 or b.page
    if type(x) == "number" and type(y) == "number" then
        return x == y and 0 or (x < y and -1 or 1)
    end
    if type(x) ~= "string" or type(y) ~= "string" or x:sub(1, 1) ~= "/" or y:sub(1, 1) ~= "/" then return 0 end
    local sa, sb = xpointerSteps(x), xpointerSteps(y)
    for i = 1, math.min(#sa, #sb) do
        if sa[i][1] ~= sb[i][1] then return sa[i][1] < sb[i][1] and -1 or 1 end
        if sa[i][2] ~= sb[i][2] then return sa[i][2] < sb[i][2] and -1 or 1 end
    end
    return #sa == #sb and 0 or (#sa < #sb and -1 or 1)
end

-- adds the items of src that dest does not have; the items already in dest keep their order.
-- Returns the list and how many items were added.
local function mergeAnnotations(dest, src)
    local out = type(dest) == "table" and dest or {}
    local into_empty = #out == 0
    local seen = {}
    for _i, it in ipairs(out) do
        if type(it) == "table" then seen[annotKey(it)] = true end
    end
    local added = 0
    for _i, it in ipairs(src) do
        if type(it) == "table" then
            local key = annotKey(it)
            if not seen[key] then
                seen[key] = true
                local copy = treeCopy(it)
                local at = #out + 1
                if not into_empty then -- an empty book simply gets the backup's own order
                    for j = 1, #out do
                        if type(out[j]) == "table" and comparePositions(copy, out[j]) < 0 then at = j; break end
                    end
                end
                table.insert(out, at, copy)
                added = added + 1
            end
        end
    end
    return out, added
end

-- Returns added, books_changed, books_missing, books_failed  |  nil, error
function Bionic:restoreBackup(b)
    if self.ui and self.ui.document then return nil, "a book is open" end
    if not (b and type(b.id) == "string" and b.id:match("^[%w_]+$")) then return nil, "bad backup" end
    local path = self:backupRoot() .. "/" .. b.id .. "/backup.lua"
    if not fileHasContent(path) then return nil, path end
    local okd, DocSettings = pcall(require, "docsettings")
    if not okd then return nil, "docsettings" end

    local data = LuaSettings:open(path)
    local books = data:readSetting("books", {})
    local plugin = data:readSetting("plugin", {})
    local bsigs = type(plugin.annot_sig) == "table" and plugin.annot_sig or {}
    local bstore = type(plugin.annot_store) == "table" and plugin.annot_store or {}

    local sigs = self.settings:readSetting("annot_sig", {})
    local store = self.settings:readSetting("annot_store", {})
    local added, changed, missing, failed = 0, 0, 0, 0
    local writes, plugin_changed = {}, false

    for file, book in pairs(books) do
        if lfs.attributes(file, "mode") ~= "file" then
            missing = missing + 1
        else
            local ann = type(book) == "table" and type(book.data) == "table" and book.data or {}
            local ds = DocSettings:open(file)
            local live = ds:readSetting("annotations")
            local live_had_key = live ~= nil
            local bsig = bsigs[file]
            local cur = sigs[file]
            -- a book this plugin has not seen yet: its sidecar takes over the signature of the backup
            if cur == nil and bsig ~= nil then cur = bsig; sigs[file] = bsig; plugin_changed = true end
            local sets = store[file] or {}
            local book_added, sidecar_changed, sets_changed = 0, false, false

            local function put(list, sig)
                if type(list) ~= "table" or #list == 0 then return end
                if sig == nil or sig == cur then
                    local merged, n = mergeAnnotations(live, list)
                    if n > 0 then live = merged; sidecar_changed = true; book_added = book_added + n end
                else
                    local merged, n = mergeAnnotations(sets[sig], list)
                    if n > 0 then sets[sig] = merged; sets_changed = true; book_added = book_added + n end
                end
            end
            put(ann.annotations, bsig)
            for sig, list in pairs(bstore[file] or {}) do put(list, sig) end

            -- very old KOReader format: only when the book has nothing of its own, so that
            -- KOReader's own migration can run
            local legacy = nil
            if not live_had_key and ann.annotations == nil and ds:readSetting("highlight") == nil then
                if ann.highlight ~= nil or ann.bookmarks ~= nil then
                    legacy = { highlight = treeCopy(ann.highlight), bookmarks = treeCopy(ann.bookmarks) }
                    book_added = book_added + countAnnotations(ann)
                end
            end

            if sets_changed then
                store[file] = next(sets) ~= nil and sets or nil
                plugin_changed = true
            end
            if book_added > 0 then
                added = added + book_added
                changed = changed + 1
                writes[#writes + 1] = { ds = ds, live = sidecar_changed and live or nil, legacy = legacy }
            end
        end
    end

    -- our own side first: whatever happens to a sidecar, no parked set can be lost
    if plugin_changed then
        self.settings:saveSetting("annot_sig", sigs)
        self.settings:saveSetting("annot_store", store)
        self.settings:flush()
    end
    for _i, w in ipairs(writes) do
        local ok = pcall(function()
            if w.live ~= nil then w.ds:saveSetting("annotations", w.live) end
            if w.legacy ~= nil then
                if w.legacy.highlight ~= nil then w.ds:saveSetting("highlight", w.legacy.highlight) end
                if w.legacy.bookmarks ~= nil then w.ds:saveSetting("bookmarks", w.legacy.bookmarks) end
            end
            w.ds:flush()
        end)
        if not ok then failed = failed + 1 end
    end
    return added, changed, missing, failed
end

function Bionic:runRestore(b, touchmenu_instance)
    local info = InfoMessage:new{ text = _("Restoring…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok, added, changed, missing, failed = pcall(self.restoreBackup, self, b)
    UIManager:close(info)
    local text
    if not ok then
        logger.warn("bionic: restore failed:", added)
        text = T(_("Restore failed: %1"), tostring(added))
    elseif added == nil then
        text = T(_("Restore failed: %1"), tostring(changed))
    elseif added == 0 and (missing or 0) == 0 then
        text = _("Nothing to restore: everything in this backup is already in your books.")
    else
        local parts = {}
        if added > 0 then parts[#parts + 1] = T(_("Restored %1 highlights/notes in %2 books."), added, changed) end
        if missing > 0 then parts[#parts + 1] = T(_("%1 books were not found and skipped."), missing) end
        if failed > 0 then parts[#parts + 1] = T(_("%1 books could not be written."), failed) end
        text = table.concat(parts, "\n")
    end
    if touchmenu_instance then touchmenu_instance:closeMenu() end
    UIManager:show(InfoMessage:new{ text = text })
end

function Bionic:confirmRestoreBackup(b, touchmenu_instance)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Restore \"%1\"?\nHighlights and notes that are missing from your books are added back (this backup has %2 books, %3 highlights/notes). Nothing already in your books is removed or changed."),
            b.name, b.books, b.notes),
        ok_text = _("Restore"),
        ok_callback = function()
            UIManager:nextTick(function() self:runRestore(b, touchmenu_instance) end)
        end,
    })
end

function Bionic:restoreBackupItems()
    local items = {}
    local list = self:listBackups()
    for _i, b in ipairs(list) do
        items[#items + 1] = {
            text_func = function()
                return T(_("%1 (%2 books, %3 notes)"), b.name, b.books, b.notes)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:confirmRestoreBackup(b, touchmenu_instance) end,
        }
    end
    if #list == 0 then
        items[1] = { text_func = function() return _("No backups yet") end, enabled_func = function() return false end }
    end
    return items
end

function Bionic:deleteBackupItems()
    local items = {}
    local list = self:listBackups()
    for _i, b in ipairs(list) do
        items[#items + 1] = {
            text_func = function()
                return T(_("%1 (%2 books, %3 notes)"), b.name, b.books, b.notes)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:confirmDeleteBackup(b, touchmenu_instance) end,
        }
    end
    if #list == 0 then
        items[1] = { text_func = function() return _("No backups yet") end, enabled_func = function() return false end }
    else
        items[#items].separator = true
        items[#items + 1] = {
            text_func = function() return _("Delete all backups") end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:confirmDeleteAllBackups(touchmenu_instance) end,
        }
    end
    return items
end

function Bionic:backupItems()
    local count = #self:listBackups()
    return {
        {
            text_func = function() return _("Back up now…") end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:backupNowDialog(touchmenu_instance) end,
        },
        {
            -- an open book writes its own highlights back when it is closed, so restoring is done
            -- from the file browser only
            text_func = function()
                if self.ui.document then return _("Restore backup: close the book first") end
                return T(_("Restore backup (%1)"), count)
            end,
            enabled_func = function() return count > 0 and not self.ui.document end,
            keep_menu_open = true,
            sub_item_table = self:restoreBackupItems(),
        },
        {
            text_func = function() return T(_("Delete backups (%1)"), count) end,
            enabled_func = function() return count > 0 end,
            keep_menu_open = true,
            sub_item_table = self:deleteBackupItems(),
        },
        {
            text_func = function() return T(_("Backups folder: %1"), self:backupRoot()) end,
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{ text = self:backupRoot() })
            end,
        },
    }
end

function Bionic:addToMainMenu(menu_items)
    menu_items.bionic_reading = {
        text_func = function() return _("Bionic reading") end,
        sorting_hint = self.ui.document and "typeset" or "more_tools",
        sub_item_table = {
            {
                text_func = function() return _("Bionic reading for this book") end,
                enabled_func = function() return self:canToggle() end,
                checked_func = function() return self:isActive() end,
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:toggle()
                end,
            },
            {
                text_func = function() return _("Always on for EPUB books") end,
                checked_func = function() return self.settings:isTrue("always_on") end,
                callback = function()
                    self.settings:toggle("always_on")
                    self.settings:flush()
                end,
            },
            {
                text_func = function() return _("Always on for online-source chapters") end,
                checked_func = function() return self.settings:isTrue("always_on_chapters") end,
                callback = function()
                    self.settings:toggle("always_on_chapters")
                    self.settings:flush()
                end,
                separator = true,
            },
            {
                -- ticked: the settings below belong to the open book only; unticked: shared by all books
                text_func = function() return _("Separate settings for this book") end,
                enabled_func = function() return self:canToggle() end,
                checked_func = function() return self:hasBookPrefs(self:currentFile()) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:toggleBookPrefs()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                separator = true,
            },
            {
                text_func = function() return _("English / Latin text") end,
                keep_menu_open = true,
                sub_item_table = self:latinItems(),
            },
            {
                text_func = function() return _("Chinese (Han characters)") end,
                keep_menu_open = true,
                sub_item_table = self:cjkItems(),
            },
            {
                -- a property of the page, so it is shared by both scripts
                text_func = function()
                    return T(_("Page theme for dimming: %1"),
                        _(self:viewPrefs().edge_theme == "dark" and "Dark page (light text)" or "Light page (dark text)"))
                end,
                keep_menu_open = true,
                sub_item_table = self:radioItems("edge_theme", {
                    { "light", "Light page (dark text)" },
                    { "dark", "Dark page (light text)" },
                }),
                separator = true,
            },
            {
                text_func = function() return _("Export") end,
                keep_menu_open = true,
                sub_item_table = self:exportItems(),
                separator = true,
            },
            {
                text_func = function() return _("Backup highlights and notes") end,
                keep_menu_open = true,
                sub_item_table = self:backupItems(),
                separator = true,
            },
            {
                text_func = function() return _("Restore original online-source chapters") end,
                enabled_func = function() return not self:isActive() or not self:isMoonChapter(self:currentFile()) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local restored = self:restoreAllChapters()
                    UIManager:show(InfoMessage:new{ text = T(_("Restored %1 chapter files."), restored) })
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text_func = function()
                    local size, count = dirSize(self:cacheDir())
                    return T(_("Clear conversion cache (%1 files, %2)"), count, util.getFriendlySize(size))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local dir = self:cacheDir()
                    for f in lfs.dir(dir) do
                        if f ~= "." and f ~= ".." then self:removeCacheFile(dir .. "/" .. f) end
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                separator = true,
            },
            Update.menuItem(PLUGIN_DIR),
            {
                text_func = function() return _("Uninstall Bionic Reading…") end,
                -- only from the file browser: no book is open, so nothing is in use
                enabled_func = function() return not self.ui.document and not Bionic.uninstalled end,
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:confirmUninstall()
                end,
                separator = true,
            },
            {
                -- always shown bilingually so it can be found whatever the current language
                text_func = function()
                    return "Language / 语言: " .. (self:lang() == "zh" and "中文" or "English")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local new = self:lang() == "zh" and "en" or "zh"
                    self.settings:saveSetting("lang", new)
                    self.settings:flush()
                    I18n.setLang(new)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        },
    }
end

-- v1 opened the converted copy as a separate book and left a history entry / sidecar for it.
-- Clean those up once.
function Bionic:migrateFromV1()
    local origins = self.settings:readSetting("origins")
    if not origins then return end
    for cache_path in pairs(origins) do
        pcall(function() require("docsettings"):open(cache_path):purge() end)
        pcall(function() require("readhistory"):removeItemByPath(cache_path) end)
    end
    self.settings:delSetting("origins")
    self.settings:flush()
end

-- The full version of this plugin stored e-mail settings (including a password) here. This
-- version has no use for them and no way to show or delete them, so they are removed.
function Bionic:purgeMailSettings()
    local found = false
    for _i, key in ipairs({ "mail", "mail_queue", "mail_auto" }) do
        if self.settings:readSetting(key) ~= nil then
            self.settings:delSetting(key)
            found = true
        end
    end
    if found then self.settings:flush() end
end

function Bionic:init()
    I18n.setLang(self:lang())
    self:migrateFromV1()
    self:purgeMailSettings()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

return Bionic
