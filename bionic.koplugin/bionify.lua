--[[
Bionic Reading text transformation.

This module has NO KOReader dependencies: it takes an (X)HTML string and
returns an (X)HTML string with word prefixes wrapped in <b> (or <u>, <i>, ...).

Algorithm:
  * a "word" is a run of letters (/\p{L}+/u); an apostrophe BETWEEN two letters belongs to
    the word (isn't, John's - literal ' ’ ʼ or the &rsquo; &apos; &#39; entities); a word that
    contains a digit (C3PO, 3.5kg, R2-D2) is left untouched
  * stem length  = word has > 3 letters and round(len * stem_pct) or the whole word
  * the stem is cut into min(max_parts, stem_len) parts of ceil(stem_len/parts) chars
  * "fixation strength" k = the first k parts are emphasised
  * "saccades" s = emphasise 1 word, leave s words de-emphasised, repeat
    (counted per text node, like the CSS nth-of-type rule)
  * de-emphasised text ("edge") is dimmed by "edge_opacity" (100 = untouched)
  * emphasis look: "style" (bold / semibold / heavy / underline / bold_underline / italic) and an
    optional colour ("color_on" + "color", for colour e-ink screens)
  * Chinese/Japanese/Korean text has its OWN independent settings (all prefixed "cjk_"): chunk size
    (0 = leave CJK alone), emphasised share, saccades, edge opacity, style and colour. The word
    counters of the two scripts are separate.
]]

local M = {}

M.DEFAULTS = {
    latin_on = false,      -- false = leave English / Latin-script text alone (e.g. emphasise only Chinese)
    stem_pct = 0.7,        -- share of a longer word that is emphasised
    max_parts = 4,         -- max number of parts a stem is cut into
    fixation_strength = 2, -- 1..4   (default 2)
    saccades = 0,          -- 0..4   (default 0 = every word)
    edge_opacity = 100,    -- 0..100 (100 = no dimming, best for e-ink)
    edge_theme = "light",  -- "light" = dark text on a light page, "dark" = light text on a dark page
                           -- (a property of the page, shared by both scripts)
    style = "bold",        -- see M.STYLES
    color_on = false,      -- colour the emphasised part (colour screens only)
    color = "red",         -- id from M.COLORS

    -- Chinese / Japanese / Korean. No spaces => no words, so every N characters count as one "word".
    cjk_chunk = 0,         -- 0 = leave CJK alone (default); N = chunk size
    cjk_ratio = 0.5,       -- share of each chunk that is emphasised
    cjk_saccades = 0,      -- same meaning as "saccades", counted separately from the Latin words
    cjk_edge_opacity = 100,
    cjk_style = "bold",
    cjk_color_on = false,
    cjk_color = "red",
}

-- Emphasis looks. tag/css describe the wrapper; "inner" adds a second nested tag.
-- semibold / heavy use CSS font-weight, which crengine only honours if the font family has
-- (or can synthesise) that weight - otherwise they look like regular or bold text.
local STYLE_DEFS = {
    bold           = { tag = "b" },
    semibold       = { tag = "span", css = "font-weight:600" },
    heavy          = { tag = "span", css = "font-weight:900" },
    underline      = { tag = "u" },
    bold_underline = { tag = "b", inner = "u" },
    italic         = { tag = "i" },
}
M.STYLES = { "bold", "semibold", "heavy", "underline", "bold_underline", "italic" } -- menu order

-- dark enough to stay readable on colour e-ink (Kaleido / Gallery panels are muted)
M.COLORS = {
    { id = "red",    hex = "#b3001b" },
    { id = "blue",   hex = "#0b3d91" },
    { id = "green",  hex = "#146b2e" },
    { id = "orange", hex = "#b85c00" },
    { id = "purple", hex = "#6a1b9a" },
    { id = "brown",  hex = "#6d4c41" },
}
local COLOR_HEX = {}
for _i, c in ipairs(M.COLORS) do COLOR_HEX[c.id] = c.hex end

-- Elements whose text must never be touched.
local SKIP_TAGS = {
    head = true, title = true, script = true, style = true,
    code = true, pre = true, kbd = true, samp = true,
    svg = true, math = true, rt = true, rp = true,
    textarea = true, input = true, select = true, option = true,
}

-- Character entities that are really an apostrophe. While a text node is processed they are
-- swapped for a control byte (\1..\6, which cannot occur in valid XHTML) so that they behave
-- like a literal apostrophe, and swapped back afterwards.
local ENTITY_TO_PH = {
    ["&rsquo;"] = "\1", ["&apos;"] = "\2", ["&#8217;"] = "\3",
    ["&#x2019;"] = "\4", ["&#39;"] = "\5", ["&#x27;"] = "\6",
}
local PH_TO_ENTITY = {}
for ent, ph in pairs(ENTITY_TO_PH) do PH_TO_ENTITY[ph] = ent end
local function entity_to_ph(ent) return ENTITY_TO_PH[ent] end -- nil keeps every other entity as is

--------------------------------------------------------------------------
-- UTF-8 helpers
--------------------------------------------------------------------------

local CHAR_PATTERN = "[%z\1-\127\194-\244][\128-\191]*"
local CHAR_PATTERN_AT = "^" .. CHAR_PATTERN

local function decode(ch)
    local b1, b2, b3, b4 = ch:byte(1, 4)
    if not b2 then return b1 end
    if b1 < 0xE0 then
        return (b1 - 0xC0) * 64 + (b2 - 0x80)
    elseif b1 < 0xF0 then
        return ((b1 - 0xE0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80)
    end
    return (((b1 - 0xF0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80)) * 64 + (b4 - 0x80)
end

-- "L" letter we bionify, "M" combining mark, "C" CJK, "D" digit,
-- "A" apostrophe (a word character only when it sits between two letters), "N" anything else
local function classify(ch)
    if #ch == 1 then
        local b = ch:byte()
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return "L" end
        if b >= 48 and b <= 57 then return "D" end
        if b == 39 then return "A" end
        return "N"
    end
    local cp = decode(ch)
    if cp < 0x80 then return "N" end
    if cp == 0x2019 or cp == 0x2BC then return "A" end          -- ’ ʼ
    if cp == 0xAA or cp == 0xB5 or cp == 0xBA then return "L" end
    if cp >= 0xC0 and cp <= 0x24F then
        if cp == 0xD7 or cp == 0xF7 then return "N" end
        return "L"
    end
    if cp >= 0x250 and cp <= 0x2AF then return "L" end         -- IPA
    if cp >= 0x300 and cp <= 0x36F then return "M" end         -- combining marks
    if cp >= 0x370 and cp <= 0x3FF then return "L" end         -- Greek
    if cp >= 0x400 and cp <= 0x52F then return "L" end         -- Cyrillic
    if cp >= 0x1E00 and cp <= 0x1FFF then return "L" end       -- Latin ext. additional / Greek ext.
    if (cp >= 0x3040 and cp <= 0x30FF)                         -- kana
        or (cp >= 0x3400 and cp <= 0x4DBF)                     -- CJK ext. A
        or (cp >= 0x4E00 and cp <= 0x9FFF)                     -- CJK unified
        or (cp >= 0xAC00 and cp <= 0xD7AF)                     -- Hangul
        or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0x20000 and cp <= 0x2FA1F) then
        return "C"
    end
    return "N"
end

-- classify() is pure: remember the answer per character (a book only has a few thousand distinct ones)
local CLS = setmetatable({}, { __index = function(t, ch)
    local c = classify(ch)
    rawset(t, ch, c)
    return c
end })

-- is the character starting at s[pos] a letter?
local function letter_at(s, pos)
    local b = s:byte(pos)
    if not b then return false end
    if b < 128 then return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) end
    local ch = s:match(CHAR_PATTERN_AT, pos)
    return ch ~= nil and classify(ch) == "L"
end

-- is the last character of s a letter (or a mark attached to one)?
local function ends_with_letter(s)
    local k = #s
    local b = s:byte(k)
    if not b then return false end
    if b < 128 then return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) end
    while k > 1 and s:byte(k) >= 128 and s:byte(k) < 192 do k = k - 1 end
    local c = classify(s:sub(k))
    return c == "L" or c == "M"
end

--------------------------------------------------------------------------
-- Core: emphasise one word
--------------------------------------------------------------------------

local function round(x) return math.floor(x + 0.5) end

-- the markup for one script: emphasised part and (optionally) dimmed part
local function look(style, color_on, color, edge_opacity, edge_theme)
    local open_emph, close_emph
    local def = STYLE_DEFS[style] or STYLE_DEFS.bold
    local css = def.css
    if color_on then
        local c = "color:" .. (COLOR_HEX[color] or COLOR_HEX.red)
        css = css and (css .. ";" .. c) or c
    end
    open_emph = "<" .. def.tag .. (css and (' style="' .. css .. '"') or "") .. ">"
    close_emph = "</" .. def.tag .. ">"
    if def.inner then
        open_emph = open_emph .. "<" .. def.inner .. ">"
        close_emph = "</" .. def.inner .. ">" .. close_emph
    end

    local open_edge, close_edge = "", ""
    if edge_opacity < 100 then
        -- crengine has no opacity, so blend text colour towards the page colour by hand
        local g
        if edge_theme == "dark" then
            g = math.floor(255 * edge_opacity / 100)        -- white text fading to black
        else
            g = math.floor(255 * (100 - edge_opacity) / 100) -- black text fading to white
        end
        open_edge = string.format('<span style="color:#%02x%02x%02x">', g, g, g)
        close_edge = "</span>"
    end
    return open_emph, close_emph, open_edge, close_edge
end

-- WHY PIECES: LuaJIT interns every string, and the (older) LuaJIT shipped with KOReader hashes a
-- string from only a few sampled bytes (the first and last 4, plus two spots in the middle). The
-- dimmed markup  <b>ab</b><span style="color:#808080">cd</span>  is long and almost constant, so
-- hundreds of thousands of different words/chunks produce the SAME hash: every new string then
-- walks a chain of thousands of entries (hundreds of seconds for a book). So no per-word long
-- string is ever built: the markup, the emphasised part and the rest are appended to the output
-- table as separate short pieces and only joined once, at the very end.

-- returns emit(first, rest, state), which APPENDS the pieces of one word. Every script keeps its own
-- running word counter in state[key].
local function make_emit(w, open_emph, close_emph, open_edge, close_edge, interval, key)
    return function(first, rest, state)
        local i = state[key] + 1
        state[key] = i
        if (i - 1) % interval ~= 0 then
            -- de-emphasised word (dimmed entirely)
            if open_edge == "" then
                w(first); w(rest)
            else
                w(open_edge); w(first); w(rest); w(close_edge)
            end
            return
        end
        w(open_emph); w(first); w(close_emph)
        if rest ~= "" then
            if open_edge == "" then
                w(rest)
            else
                w(open_edge); w(rest); w(close_edge)
            end
        end
    end
end

-- build(opts) returns transform_text(text, out, n) -> n: it appends the pieces of one text node to
-- the table "out" (which already holds n pieces) and returns the new count.
local function build(opts)
    local stem_pct, max_parts = opts.stem_pct, opts.max_parts
    local strength = opts.fixation_strength

    -- the output buffer of the text node being processed
    local ob, bn = nil, 0
    local function w(s) bn = bn + 1; ob[bn] = s end

    local latin_on = opts.latin_on ~= false
    local oe, ce, od, cd = look(opts.style, opts.color_on, opts.color, opts.edge_opacity, opts.edge_theme)
    local emit_latin
    if latin_on then
        emit_latin = make_emit(w, oe, ce, od, cd, opts.saccades + 1, "i")
    else
        emit_latin = function(first, rest) w(first); w(rest) end -- English switched off
    end

    local chunk = opts.cjk_chunk or 0
    local ratio = opts.cjk_ratio or 0.5
    oe, ce, od, cd = look(opts.cjk_style, opts.cjk_color_on, opts.cjk_color, opts.cjk_edge_opacity or 100,
        opts.edge_theme)
    local emit_cjk_part = make_emit(w, oe, ce, od, cd, (opts.cjk_saccades or 0) + 1, "ci")

    -- number of emphasised letters for a word of n letters (cached)
    local bold_cache = {}
    local function bold_len(n)
        local b = bold_cache[n]
        if not b then
            local stem = n > 3 and round(n * stem_pct) or n
            local parts = math.min(max_parts, stem)
            local width = math.ceil(stem / parts)
            b = math.min(stem, width * strength)
            bold_cache[n] = b
        end
        return b
    end

    local function emit_ascii(word, state)
        local b = bold_len(#word)
        emit_latin(word:sub(1, b), word:sub(b + 1), state)
    end

    -- units: the characters of one word (letters, plus apostrophes inside it); kind[i] is true for
    -- letter units. Only letters count towards the emphasised length.
    local function emit_units(units, kind, wn, lcount, state)
        local b = bold_len(lcount)
        local cut, seen = wn, 0
        for i = 1, wn do
            if kind[i] then
                seen = seen + 1
                if seen == b then cut = i; break end
            end
        end
        emit_latin(table.concat(units, "", 1, cut), table.concat(units, "", cut + 1, wn), state)
    end

    local function emit_cjk(units, n, state)
        local i = 1
        while i <= n do
            local j = math.min(i + chunk - 1, n)
            local m = j - i + 1
            local b = math.max(1, math.min(m, math.floor(m * ratio + 0.5)))
            emit_cjk_part(table.concat(units, "", i, i + b - 1), table.concat(units, "", i + b, j), state)
            i = j + 1
        end
    end

    -- General path, character by character. parts = { run, joiner, run, joiner, run ... }:
    -- odd entries are runs of [A-Za-z0-9\128-\255], even entries are the ASCII apostrophes /
    -- apostrophe placeholders that the caller found between two letters.
    -- The buffers below are shared by all calls (the function is never re-entered): entries past
    -- wn / cn are stale and are never read.
    local word, kind, cjk = {}, {}, {}
    local wn, lcount, tainted, cn, pend, cur
    local function flush_word()
        if wn > 0 then
            if tainted then
                w(table.concat(word, "", 1, wn)) -- contains a digit: leave alone
            else
                emit_units(word, kind, wn, lcount, cur)
            end
            wn, lcount, tainted = 0, 0, false
        end
    end
    local function flush_cjk()
        if cn > 0 then
            if chunk > 0 then emit_cjk(cjk, cn, cur) else w(table.concat(cjk, "", 1, cn)) end
            cn = 0
        end
    end
    local function drop_pending() -- the apostrophe was not between two letters
        if pend then flush_word(); w(pend); pend = nil end
    end

    local function handle_chars(parts, state)
        wn, lcount, tainted, cn, pend, cur = 0, 0, false, 0, nil, state
        -- pend: an apostrophe after a letter; it joins the word only if a letter follows
        for pi = 1, #parts do
            local part = parts[pi]
            if pi % 2 == 0 then
                wn = wn + 1; word[wn] = part; kind[wn] = false
            else
                for ch in part:gmatch(CHAR_PATTERN) do
                    local c = CLS[ch]
                    if pend then
                        if c == "L" then
                            wn = wn + 1; word[wn] = pend; kind[wn] = false; pend = nil
                        else
                            drop_pending()
                        end
                    end
                    if c == "L" then
                        if cn > 0 then flush_cjk() end
                        wn = wn + 1; word[wn] = ch; kind[wn] = true; lcount = lcount + 1
                    elseif c == "A" then
                        if wn > 0 and kind[wn] then pend = ch else flush_word(); flush_cjk(); w(ch) end
                    elseif c == "D" then
                        if cn > 0 then flush_cjk() end
                        wn = wn + 1; word[wn] = ch; kind[wn] = false; tainted = true
                    elseif c == "M" then
                        if wn > 0 then word[wn] = word[wn] .. ch
                        elseif cn > 0 then cjk[cn] = cjk[cn] .. ch
                        else w(ch) end
                    elseif c == "C" then
                        if wn > 0 then flush_word() end
                        cn = cn + 1; cjk[cn] = ch
                    else
                        flush_word(); flush_cjk(); w(ch)
                    end
                end
            end
        end
        if pend then drop_pending() end
        flush_word(); flush_cjk()
    end

    -- a single run of [A-Za-z0-9\128-\255]
    local function handle_run(run, state)
        if not run:find("[\128-\255]") then
            if run:find("%d") then w(run); return end -- words with digits are left alone
            return emit_ascii(run, state)
        end
        -- fast path: nothing we would ever emphasise unless CJK chunking is on
        if chunk == 0 and not run:find("[A-Za-z\194-\223\225]") then
            w(run)
            return
        end
        return handle_chars({ run }, state)
    end

    local ph_pattern = "['\1-\6]"

    -- word + apostrophe + word, all ASCII letters (isn't): no tables, no per-character work
    local function emit_pair(a, j, b, state)
        local la = #a
        local bl = bold_len(la + #b)
        if bl <= la then return emit_latin(a:sub(1, bl), a:sub(bl + 1) .. j .. b, state) end
        return emit_latin(a .. j .. b:sub(1, bl - la), b:sub(bl - la + 1), state)
    end

    -- joined group (runs and apostrophes alternating); ASCII letters take a shortcut.
    -- returns false when it produced nothing
    local function emit_joined(parts, state)
        local total, np = 0, #parts
        for i = 1, np, 2 do
            local p = parts[i]
            if p:find("[\128-\255]") then handle_chars(parts, state); return true end
            if p:find("%d") then w(table.concat(parts)); return true end -- contains a digit: leave alone
            total = total + #p
        end
        local bl, acc = bold_len(total), 0
        for i = 1, np, 2 do
            local l = #parts[i]
            if acc + l >= bl then
                local cut = bl - acc
                local first = table.concat(parts, "", 1, i - 1) .. parts[i]:sub(1, cut)
                local rest = parts[i]:sub(cut + 1) .. table.concat(parts, "", i + 1, np)
                emit_latin(first, rest, state)
                return true
            end
            acc = acc + l
        end
        return false
    end

    -- A token that contains apostrophes: split it into runs and apostrophes, join the runs that
    -- have a letter on both sides of an apostrophe (isn't), leave every other apostrophe alone.
    local function is_joiner(item) return #item == 1 and item:find(ph_pattern) ~= nil end
    local function handle_joined(tok, state)
        local items, n, pos, len = {}, 0, 1, #tok
        while pos <= len do
            local j = tok:find(ph_pattern, pos)
            if not j then n = n + 1; items[n] = tok:sub(pos); break end
            if j > pos then n = n + 1; items[n] = tok:sub(pos, j - 1) end
            n = n + 1; items[n] = tok:sub(j, j)
            pos = j + 1
        end
        local k = 1
        while k <= n do
            local it = items[k]
            k = k + 1
            if is_joiner(it) then
                w(it) -- apostrophe that is not between two letters
            else
                local parts = { it }
                while k + 1 <= n and is_joiner(items[k]) and not is_joiner(items[k + 1])
                        and ends_with_letter(parts[#parts]) and letter_at(items[k + 1], 1) do
                    parts[#parts + 1] = items[k]
                    parts[#parts + 1] = items[k + 1]
                    k = k + 2
                end
                if #parts == 1 then
                    handle_run(parts[1], state)
                else
                    local before = bn
                    if not emit_joined(parts, state) and bn == before then w(table.concat(parts)) end
                end
            end
        end
    end

    local state = { i = 0, ci = 0 } -- word counters of the text node being processed

    local find, sub = string.find, string.sub
    local function on_token(tok)
        -- the common case, a plain ASCII word (no digit, apostrophe or accented letter): one test
        if not find(tok, "[^A-Za-z]") then return emit_ascii(tok, state) end
        if not find(tok, ph_pattern) then return handle_run(tok, state) end
        local a, j, b = tok:match("^([A-Za-z]+)(['\1-\6])([A-Za-z]+)$")
        if a then return emit_pair(a, j, b, state) end
        return handle_joined(tok, state)
    end

    local TOKEN = "[A-Za-z0-9\128-\255][A-Za-z0-9\128-\255'\1-\6]*"

    -- When no word counter is involved (no saccades) the pieces of a token depend on the token only,
    -- so they are remembered. Long tokens (whole runs of Chinese text) are not stored.
    local cjk_pure = ((opts.cjk_saccades or 0) + 1) == 1
    local pure = (not latin_on or opts.saccades + 1 == 1) and (chunk == 0 or cjk_pure)
    local memo, memo_n = {}, 0
    local function token(tok)
        local before = bn
        if pure then
            local m = memo[tok]
            if m then
                for i = 1, #m do bn = bn + 1; ob[bn] = m[i] end
                return
            end
            on_token(tok)
            if bn == before then w(tok) return end
            if memo_n < 60000 and #tok <= 48 then
                local m2 = {}
                for i = before + 1, bn do m2[#m2 + 1] = ob[i] end
                memo[tok] = m2
                memo_n = memo_n + 1
            end
            return
        end
        on_token(tok)
        if bn == before then w(tok) end -- (nothing produced: keep the token as it was)
    end

    -- the words of a stretch of text with no entities in it
    local function scan(text)
        local pos, len = 1, #text
        while pos <= len do
            local s, e = find(text, TOKEN, pos)
            if not s then w(sub(text, pos)); return end
            if s > pos then w(sub(text, pos, s - 1)) end
            token(sub(text, s, e))
            pos = e + 1
        end
    end

    -- one text node (text between two tags); entities are passed through untouched
    local function transform_text(text, out, n)
        ob, bn = out, n
        if not text:find("[A-Za-z\128-\255]") then w(text); return bn end
        if not latin_on and chunk == 0 then w(text); return bn end -- nothing to do for either script
        state.i, state.ci = 0, 0
        if not find(text, "&", 1, true) then scan(text); return bn end -- no entities
        local first_piece = bn + 1
        local swapped = false
        local t, count = text:gsub("&#?[%w]+;", entity_to_ph)
        if count > 0 then
            swapped = text:find("[\1-\6]") == nil -- (a stray control byte in the source: do not touch)
            if swapped then text = t end
        end
        local pos = 1
        while true do
            local s, e = text:find("&#?[%w]+;", pos)
            local segment
            if s then segment = sub(text, pos, s - 1) else segment = sub(text, pos) end
            if segment ~= "" then scan(segment) end
            if not s then break end
            w(sub(text, s, e))
            pos = e + 1
        end
        if swapped then
            for i = first_piece, bn do
                local piece = ob[i]
                if find(piece, "[\1-\6]") then ob[i] = (piece:gsub("[\1-\6]", PH_TO_ENTITY)) end
            end
        end
        return bn
    end

    return transform_text
end

--------------------------------------------------------------------------
-- (X)HTML walker
--------------------------------------------------------------------------

function M.transform_html(html, user_opts)
    local opts = {}
    for k, v in pairs(M.DEFAULTS) do opts[k] = v end
    if user_opts then for k, v in pairs(user_opts) do opts[k] = v end end
    -- building (and the memo tables) can be reused by the next file of the same book
    local keys = {}
    for k in pairs(opts) do keys[#keys + 1] = k end
    table.sort(keys)
    for i = 1, #keys do keys[i] = keys[i] .. "=" .. tostring(opts[keys[i]]) end
    local sig = table.concat(keys, "|")
    if M._sig ~= sig then M._sig, M._fn = sig, build(opts) end
    local transform_text = M._fn

    local out, n = {}, 0
    local len = #html
    local pos = 1
    local counts, skip_total = {}, 0

    local function push(s) n = n + 1; out[n] = s end

    while pos <= len do
        local lt = html:find("<", pos, true)
        if not lt then
            if skip_total > 0 then push(html:sub(pos)) else n = transform_text(html:sub(pos), out, n) end
            break
        end
        if lt > pos then
            local text = html:sub(pos, lt - 1)
            if skip_total > 0 then push(text) else n = transform_text(text, out, n) end
        end

        local tag_end
        if html:sub(lt, lt + 3) == "<!--" then
            local e = html:find("-->", lt + 4, true)
            tag_end = e and (e + 2) or len
        elseif html:sub(lt, lt + 8) == "<![CDATA[" then
            local e = html:find("]]>", lt + 9, true)
            tag_end = e and (e + 2) or len
        else
            local from = lt + 1
            while true do
                local e = html:find(">", from, true)
                if not e then tag_end = len; break end
                -- a ">" inside a quoted attribute value does not end the tag
                local t = html:sub(lt, e):gsub('"[^"]*"', ""):gsub("'[^']*'", "")
                if not t:find("[\"']") then tag_end = e; break end
                from = e + 1
            end
        end

        local tag = html:sub(lt, tag_end)
        push(tag)

        local closing, name = tag:match("^<(/?)([%w:_%-]+)")
        if name then
            name = name:lower()
            if SKIP_TAGS[name] then
                if closing == "/" then
                    if (counts[name] or 0) > 0 then
                        counts[name] = counts[name] - 1
                        skip_total = skip_total - 1
                    end
                elseif tag:sub(-2, -2) ~= "/" then
                    counts[name] = (counts[name] or 0) + 1
                    skip_total = skip_total + 1
                end
            end
        end
        pos = tag_end + 1
    end

    return table.concat(out)
end

-- forget the reusable transformer (for benchmarks)
function M.reset_cache() M._sig, M._fn = nil, nil end

-- false when the file declares a non-UTF-8 encoding (we only handle UTF-8)
function M.is_utf8_html(data)
    local head = data:sub(1, 600):lower()
    local enc = head:match("encoding%s*=%s*[\"']([^\"']+)") or head:match("charset%s*=%s*([%w%-_]+)")
    if enc and enc ~= "utf-8" and enc ~= "utf8" then return false end
    return true
end

return M
