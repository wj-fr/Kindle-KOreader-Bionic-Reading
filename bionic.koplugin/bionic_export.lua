--[[
Helpers for exporting a converted EPUB: file names, the book title inside the EPUB, re-packing.
Only repack() needs KOReader's archiver (passed in, so the rest can be tested anywhere).
]]

local X = {}

X.TITLE_SUFFIX = " (Bionic)"

-- keep whole UTF-8 characters when cutting to a byte length
local function cut_utf8(s, maxbytes)
    if #s <= maxbytes then return s end
    local cut = maxbytes
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 128 or b >= 192 then break end -- next byte starts a character
        cut = cut - 1
    end
    return s:sub(1, cut)
end

-- a name that every file system we meet (FAT on Kindle included) and every mail program accepts
function X.safe_name(s, maxbytes)
    s = tostring(s or ""):gsub('[\\/:*?"<>|%c]', "_"):gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    s = cut_utf8(s, maxbytes or 120)
    s = s:gsub("[%s%.]+$", "")
    if s == "" then s = "book" end
    return s
end

-- "/dir/My Book.epub" -> "My Book (bionic).epub"
function X.export_name(orig_path)
    local base = orig_path:match("([^/]+)$") or orig_path
    base = base:gsub("%.[eE][pP][uU][bB]$", "")
    -- a book that was already exported once keeps a single "(bionic)"
    base = base:gsub("%s*%([bB]ionic%)$", "")
    return X.safe_name(base, 110) .. " (bionic).epub"
end

-- META-INF/container.xml -> path of the package document
function X.find_opf(container_xml)
    if not container_xml then return nil end
    return container_xml:match('full%-path%s*=%s*"([^"]+)"') or container_xml:match("full%-path%s*=%s*'([^']+)'")
end

-- append suffix to the first <dc:title>; returns new xml, changed
function X.retitle(opf, suffix)
    if not opf or suffix == nil or suffix == "" then return opf, false end
    local s, e, open, text, close = opf:find("(<dc:title[^>]*>)(.-)(</dc:title>)")
    if not s then return opf, false end
    local trimmed = text:gsub("%s+$", "")
    if trimmed == "" then return opf, false end
    if trimmed:sub(-#suffix) == suffix then return opf, false end
    return opf:sub(1, s - 1) .. open .. trimmed .. suffix .. close .. opf:sub(e + 1), true
end

function X.copy_file(src, dst)
    local f = io.open(src, "rb")
    if not f then return nil, "cannot read " .. src end
    local tmp = dst .. ".tmp"
    local out = io.open(tmp, "wb")
    if not out then f:close(); return nil, "cannot write " .. dst end
    local ok = true
    while true do
        local chunk = f:read(65536)
        if not chunk then break end
        if not out:write(chunk) then ok = false; break end
    end
    f:close()
    if not out:close() then ok = false end
    if not ok then os.remove(tmp); return nil, "cannot write " .. dst end
    os.remove(dst)
    if not os.rename(tmp, dst) then os.remove(tmp); return nil, "cannot write " .. dst end
    return true
end

-- Copy an EPUB into dst, adding `suffix` to the book title. store_ext: extensions that are stored
-- uncompressed (images, fonts). Returns true, retitled | nil, error text
function X.repack(src, dst, suffix, store_ext, Archiver)
    Archiver = Archiver or require("ffi/archiver")
    store_ext = store_ext or {}
    local reader = Archiver.Reader:new()
    if not reader:open(src) then return nil, "cannot open the converted EPUB" end
    local opf_path = X.find_opf(reader:extractToMemory("META-INF/container.xml"))
    local writer = Archiver.Writer:new{}
    local tmp = dst .. ".tmp"
    if not writer:open(tmp, "epub") then
        reader:close()
        return nil, "cannot create the export file"
    end
    local ok, err, retitled = true, nil, false
    local mtime = os.time()
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local path = entry.path
            local data = reader:extractToMemory(path)
            if not data then ok, err = false, "failed to read " .. path; break end
            if opf_path and path == opf_path then
                data, retitled = X.retitle(data, suffix)
            end
            local ext = (path:match("%.([^./]+)$") or ""):lower()
            writer:setZipCompression((path == "mimetype" or store_ext[ext]) and "store" or "deflate")
            if not writer:addFileFromMemory(path, data, mtime) then
                ok, err = false, "failed to write " .. path
                break
            end
        end
    end
    reader:close()
    writer:close()
    if not ok then os.remove(tmp); return nil, err end
    os.remove(dst)
    if not os.rename(tmp, dst) then os.remove(tmp); return nil, "cannot save the export file" end
    return true, retitled
end

return X
