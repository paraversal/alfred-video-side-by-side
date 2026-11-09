-- Side by Side — OSD labels and timeline for the split-screen comparison.
--
-- The shell script passes four already-formatted strings:
--   sbs-left-main   e.g. "42.1 MB · −68%"
--   sbs-left-note   e.g. "compressed · 3.1× smaller"
--   sbs-right-main  e.g. "131.5 MB"
--   sbs-right-note  e.g. "original"
--
-- The timeline reads time-pos and duration directly from the player.
--
-- Everything is drawn with ASS overlay events, so it stays sharp, costs no
-- video processing, and works even when FFmpeg has no font support.

local mp = require("mp")

local function option(name, fallback)
    local value = mp.get_opt(name)
    if value == nil or value == "" then
        return fallback
    end
    return value
end

local left_main = option("sbs-left-main", "Compressed")
local left_note = option("sbs-left-note", "")
local right_main = option("sbs-right-main", "Original")
local right_note = option("sbs-right-note", "")

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 100

local timeline_position = 0
local duration = 0
local pending = false
local attempts = 0
local draw

local function schedule(delay)
    if pending then
        return
    end
    pending = true
    mp.add_timeout(delay or 0.05, function()
        pending = false
        local ok, err = pcall(function()
            draw()
        end)
        if not ok then
            mp.msg.warn("side-by-side labels: " .. tostring(err))
        end
    end)
end

local function ass_text(text, size, bold, color, alpha, border)
    -- ASS colours are &HBBGGRR, alpha is &HAA (00 opaque, FF transparent).
    return string.format(
        "{\\fs%d\\b%d\\1c&H%s&\\1a&H%s&\\bord%d\\shad0\\blur0}" ..
        "{\\3c&H000000&\\3a&H30&}%s",
        size, bold, color, alpha, border, text
    )
end

local function format_time(seconds)
    seconds = tonumber(seconds)
    if seconds == nil or seconds < 0 or seconds == math.huge then
        return "--:--"
    end

    local total = math.floor(seconds + 0.5)
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local secs = total % 60

    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%d:%02d", minutes, secs)
end

draw = function()
    local dims = mp.get_property_native("osd-dimensions")
    local w = dims and dims.w or 0
    local h = dims and dims.h or 0

    if w < 2 or h < 2 then
        attempts = attempts + 1
        if attempts < 40 then
            schedule(0.1)
        end
        return
    end
    attempts = 0

    local base = math.min(w, h)
    local main_size = math.max(11, math.floor(math.min(h * 0.034, w * 0.045)))
    local note_size = math.max(8, math.floor(main_size * 0.76))
    local pad = math.max(7, math.floor(base * 0.018))
    local border = math.max(1, math.floor(main_size / 8.0))
    local line_gap = math.floor(main_size * 1.34)

    -- The seam is the exact centre of the composed hstack frame.
    local seam_w = math.max(1, math.floor(base * 0.0015))
    local seam_x = math.floor((w - seam_w) / 2.0)
    local seam = string.format(
        "{\\an7\\pos(%d,0)\\p1\\bord0\\shad0\\1c&HFFFFFF&\\1a&H50&}" ..
        "m 0 0 l %d 0 %d %d 0 %d{\\p0}",
        seam_x, seam_w, seam_w, h, h
    )

    local lines = { seam }

    lines[#lines + 1] = string.format(
        "{\\an7\\pos(%d,%d)}%s",
        pad, pad,
        ass_text(left_main, main_size, 1, "FFFFFF", "00", border)
    )
    if left_note ~= "" then
        lines[#lines + 1] = string.format(
            "{\\an7\\pos(%d,%d)}%s",
            pad, pad + line_gap,
            ass_text(left_note, note_size, 0, "D8D8D8", "10", math.max(1, border - 1))
        )
    end

    lines[#lines + 1] = string.format(
        "{\\an9\\pos(%d,%d)}%s",
        w - pad, pad,
        ass_text(right_main, main_size, 1, "FFFFFF", "00", border)
    )
    if right_note ~= "" then
        lines[#lines + 1] = string.format(
            "{\\an9\\pos(%d,%d)}%s",
            w - pad, pad + line_gap,
            ass_text(right_note, note_size, 0, "D8D8D8", "10", math.max(1, border - 1))
        )
    end

    -- A quiet progress rail along the bottom. Arrow keys and the mouse already
    -- seek; this just makes the current position visible without the full OSC.
    local bar_h = math.max(3, math.floor(base * 0.006))
    local bar_x = pad
    local bar_y = h - pad - bar_h
    local bar_w = w - pad * 2
    local timeline_size = math.max(9, math.floor(base * 0.016))

    local current_duration = duration
    if current_duration <= 0 then
        current_duration = mp.get_property_number("duration", 0) or 0
    end
    local current_position = timeline_position
    if current_position < 0 then
        current_position = 0
    end

    local progress = 0
    if current_duration > 0 then
        progress = math.min(1, math.max(0, current_position / current_duration))
    end
    local fill_w = math.floor(bar_w * progress + 0.5)
    local time_label = format_time(current_position) .. " / " .. format_time(current_duration)

    lines[#lines + 1] = string.format(
        "{\\an7\\pos(%d,%d)\\p1\\bord0\\shad0\\1c&H000000&\\1a&H60&}" ..
        "m 0 0 l %d 0 %d %d 0 %d{\\p0}",
        bar_x, bar_y, bar_w, bar_w, bar_h, bar_h
    )

    if fill_w > 0 then
        local fill_x = bar_x
        if fill_w > bar_w then
            fill_w = bar_w
        end
        lines[#lines + 1] = string.format(
            "{\\an7\\pos(%d,%d)\\p1\\bord0\\shad0\\1c&H0B9EF5&\\1a&H00&}" ..
            "m 0 0 l %d 0 %d %d 0 %d{\\p0}",
            fill_x, bar_y, fill_w, fill_w, bar_h, bar_h
        )

        local head_w = math.max(2, math.floor(base * 0.002))
        local head_h = bar_h + math.max(2, math.floor(base * 0.004))
        local head_x = math.max(bar_x, fill_x + fill_w - math.floor(head_w / 2))
        local head_y = bar_y - math.floor((head_h - bar_h) / 2)
        lines[#lines + 1] = string.format(
            "{\\an7\\pos(%d,%d)\\p1\\bord0\\shad0\\1c&HFFFFFF&\\1a&H00&}" ..
            "m 0 0 l %d 0 %d %d 0 %d{\\p0}",
            head_x, head_y, head_w, head_w, head_h, head_h
        )
    end

    lines[#lines + 1] = string.format(
        "{\\an9\\pos(%d,%d)}%s",
        w - pad, bar_y - 6,
        ass_text(time_label, timeline_size, 0, "FFFFFF", "20", 1)
    )

    overlay.res_x = math.floor(w + 0.5)
    overlay.res_y = math.floor(h + 0.5)
    overlay.data = table.concat(lines, "\n")
    overlay:update()
end

-- Re-draw when the window/video area changes and after the file is loaded.
mp.observe_property("osd-dimensions", "native", function()
    schedule(0.05)
end)
mp.observe_property("time-pos", "number", function(_, value)
    if value then
        timeline_position = value
        schedule(0.08)
    end
end)
mp.observe_property("duration", "number", function(_, value)
    duration = value or 0
    schedule(0.08)
end)
mp.register_event("file-loaded", function()
    attempts = 0
    timeline_position = 0
    duration = mp.get_property_number("duration", 0) or 0
    schedule(0.15)
end)
mp.register_event("playback-restart", function()
    schedule(0.15)
end)

schedule(0.2)
