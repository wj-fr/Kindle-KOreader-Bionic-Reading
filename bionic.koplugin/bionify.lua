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
    latin_on = true,       -- false = leave English / Latin-script text alone (e.g. emphasise only Chinese)
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

-- returns emit(first, rest, state): "first" is the part that gets emphasised. Every script keeps
-- its own running word counter in state[key].
local function make_emit(open_emph, close_emph, open_edge, close_edge, interval, key)
    return function(first, rest, state)
        local i = state[key] + 1
        state[key] = i
        if (i - 1) % interval ~= 0 then
            -- de-emphasised word (dimmed entirely)
            if open_edge == "" then return first .. rest end
            return open_edge .. first .. rest .. close_edge
        end
        if rest == "" or open_edge == "" then
            return open_emph .. first .. close_emph .. rest
        end
        return open_emph .. first .. close_emph .. open_edge .. rest .. close_edge
    end
end

local function build(opts)
    local stem_pct, max_parts = opts.stem_pct, opts.max_parts
    local strength = opts.fixation_strength

    local latin_on = opts.latin_on ~= false
    local oe, ce, od, cd = look(opts.style, opts.color_on, opts.color, opts.edge_opacity, opts.edge_theme)
    local emit_latin
    if latin_on then
        emit_latin = make_emit(oe, ce, od, cd, opts.saccades + 1, "i")
    else
        emit_latin = function(first, rest) return first .. rest end -- English switched off
    end

    local chunk = opts.cjk_chunk or 0
    local ratio = opts.cjk_ratio or 0.5
    oe, ce, od, cd = look(opts.cjk_style, opts.cjk_color_on, opts.cjk_color, opts.cjk_edge_opacity or 100,
        opts.edge_theme)
    local emit_cjk_part = make_emit(oe, ce, od, cd, (opts.cjk_saccades or 0) + 1, "ci")

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
        return emit_latin(word:sub(1, b), word:sub(b + 1), state)
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
        return emit_latin(table.concat(units, "", 1, cut), table.concat(units, "", cut + 1, wn), state)
    end

    local function emit_cjk(units, n, state)
        local out, i = {}, 1
        while i <= n do
            local j = math.min(i + chunk - 1, n)
            local m = j - i + 1
            local b = math.max(1, math.min(m, math.floor(m * ratio + 0.5)))
            out[#out + 1] = emit_cjk_part(table.concat(units, "", i, i + b - 1),
                                          table.concat(units, "", i + b, j), state)
            i = j + 1
        end
        return table.concat(out)
    end

    -- General path, character by character. parts = { run, joiner, run, joiner, run ... }:
    -- odd entries are runs of [A-Za-z0-9\128-\255], even entries are the ASCII apostrophes /
    -- apostrophe placeholders that the caller found between two letters.
    -- The buffers below are shared by all calls (the function is never re-entered): entries past
    -- wn / cn / on are stale and are never read.
    local word, kind, cjk, out = {}, {}, {}, {}
    local wn, lcount, tainted, cn, on, pend, cur
    local function put(s) on = on + 1; out[on] = s end
    local function flush_word()
        if wn > 0 then
            if tainted then
                put(table.concat(word, "", 1, wn)) -- contains a digit: leave alone
            else
                put(emit_units(word, kind, wn, lcount, cur))
            end
            wn, lcount, tainted = 0, 0, false
        end
    end
    local function flush_cjk()
        if cn > 0 then
            if chunk > 0 then put(emit_cjk(cjk, cn, cur)) else put(table.concat(cjk, "", 1, cn)) end
            cn = 0
        end
    end
    local function drop_pending() -- the apostrophe was not between two letters
        if pend then flush_word(); put(pend); pend = nil end
    end

    local function handle_chars(parts, state)
        wn, lcount, tainted, cn, on, pend, cur = 0, 0, false, 0, 0, nil, state
        -- pend: an apostrophe after a letter; it joins the word only if a letter follows
        for pi = 1, #parts do
            local part = parts[pi]
            if pi % 2 == 0 then
                wn = wn + 1; word[wn] = part; kind[wn] = false
            else
                for ch in part:gmatch(CHAR_PATTERN) do
                    local c = classify(ch)
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
                        if wn > 0 and kind[wn] then pend = ch else flush_word(); flush_cjk(); put(ch) end
                    elseif c == "D" then
                        if cn > 0 then flush_cjk() end
                        wn = wn + 1; word[wn] = ch; kind[wn] = false; tainted = true
                    elseif c == "M" then
                        if wn > 0 then word[wn] = word[wn] .. ch
                        elseif cn > 0 then cjk[cn] = cjk[cn] .. ch
                        else put(ch) end
                    elseif c == "C" then
                        if wn > 0 then flush_word() end
                        cn = cn + 1; cjk[cn] = ch
                    else
                        flush_word(); flush_cjk(); put(ch)
                    end
                end
            end
        end
        if pend then drop_pending() end
        flush_word(); flush_cjk()
        return table.concat(out, "", 1, on)
    end

    -- a single run of [A-Za-z0-9\128-\255]
    local function handle_run(run, state)
        if not run:find("[\128-\255]") then
            if run:find("%d") then return run end -- words with digits are left alone
            return emit_ascii(run, state)
        end
        -- fast path: nothing we would ever emphasise unless CJK chunking is on
        if chunk == 0 and not run:find("[A-Za-z\194-\223\225]") then
            return run
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

    -- joined group (runs and apostrophes alternating); ASCII letters take a shortcut
    local function emit_joined(parts, state)
        local total, np = 0, #parts
        for i = 1, np, 2 do
            local p = parts[i]
            if p:find("[\128-\255]") then return handle_chars(parts, state) end
            if p:find("%d") then return table.concat(parts) end -- contains a digit: leave alone
            total = total + #p
        end
        local bl, acc = bold_len(total), 0
        for i = 1, np, 2 do
            local l = #parts[i]
            if acc + l >= bl then
                local cut = bl - acc
                local first = table.concat(parts, "", 1, i - 1) .. parts[i]:sub(1, cut)
                local rest = parts[i]:sub(cut + 1) .. table.concat(parts, "", i + 1, np)
                return emit_latin(first, rest, state)
            end
            acc = acc + l
        end
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
        local out, on, k = {}, 0, 1
        while k <= n do
            local it = items[k]
            k = k + 1
            if is_joiner(it) then
                on = on + 1; out[on] = it -- apostrophe that is not between two letters
            else
                local parts = { it }
                while k + 1 <= n and is_joiner(items[k]) and not is_joiner(items[k + 1])
                        and ends_with_letter(parts[#parts]) and letter_at(items[k + 1], 1) do
                    parts[#parts + 1] = items[k]
                    parts[#parts + 1] = items[k + 1]
                    k = k + 2
                end
                on = on + 1
                if #parts == 1 then out[on] = handle_run(parts[1], state)
                else out[on] = emit_joined(parts, state) end
            end
        end
        return table.concat(out)
    end

    local state = { i = 0, ci = 0 } -- word counters of the text node being processed

    local function on_token(tok)
        if not tok:find(ph_pattern) then return handle_run(tok, state) end
        local a, j, b = tok:match("^([A-Za-z]+)(['\1-\6])([A-Za-z]+)$")
        if a then return emit_pair(a, j, b, state) end
        return handle_joined(tok, state)
    end

    local TOKEN = "[A-Za-z0-9\128-\255][A-Za-z0-9\128-\255'\1-\6]*"

    -- one text node (text between two tags); entities are passed through untouched
    local function transform_text(text)
        if not text:find("[A-Za-z\128-\255]") then return text end
        if not latin_on and chunk == 0 then return text end -- nothing to do for either script
        state.i, state.ci = 0, 0
        local swapped = false
        if text:find("&", 1, true) then
            local t, count = text:gsub("&#?[%w]+;", entity_to_ph)
            if count > 0 then
                swapped = text:find("[\1-\6]") == nil -- (a stray control byte in the source: do not touch)
                if swapped then text = t end
            end
        end
        local out, pos = {}, 1
        while true do
            local s, e = text:find("&#?[%w]+;", pos)
            local segment
            if s then segment = text:sub(pos, s - 1) else segment = text:sub(pos) end
            if segment ~= "" then
                out[#out + 1] = (segment:gsub(TOKEN, on_token))
            end
            if not s then break end
            out[#out + 1] = text:sub(s, e)
            pos = e + 1
        end
        local result = table.concat(out)
        if swapped then result = result:gsub("[\1-\6]", PH_TO_ENTITY) end
        return result
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
    local transform_text = build(opts)

    local out, n = {}, 0
    local len = #html
    local pos = 1
    local counts, skip_total = {}, 0

    local function push(s) n = n + 1; out[n] = s end

    while pos <= len do
        local lt = html:find("<", pos, true)
        if not lt then
            if skip_total > 0 then push(html:sub(pos)) else push(transform_text(html:sub(pos))) end
            break
        end
        if lt > pos then
            local text = html:sub(pos, lt - 1)
            if skip_total > 0 then push(text) else push(transform_text(text)) end
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

-- false when the file declares a non-UTF-8 encoding (we only handle UTF-8)
function M.is_utf8_html(data)
    local head = data:sub(1, 600):lower()
    local enc = head:match("encoding%s*=%s*[\"']([^\"']+)") or head:match("charset%s*=%s*([%w%-_]+)")
    if enc and enc ~= "utf-8" and enc ~= "utf8" then return false end
    return true
end

return M
