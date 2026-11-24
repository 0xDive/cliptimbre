-- GNU AGPL version 3 only. See LICENSE and LICENSE-RESOLVE-EXCEPTION.md.

local M = {}

local PATH_SEP = package.config:sub(1, 1)
local IS_WINDOWS = PATH_SEP == "\\"
local IS_LINUX = not IS_WINDOWS and jit and jit.os == "Linux"
local HOME = IS_WINDOWS and (os.getenv("USERPROFILE") or os.getenv("HOME") or "") or (os.getenv("HOME") or os.getenv("USERPROFILE") or "")
local data_dir_override = ...
local APP_DIR = type(data_dir_override) == "string" and data_dir_override or os.getenv("STREAMER_VOICE_DATA_DIR") or HOME .. "/.streamer_voice"
local windows = IS_WINDOWS and assert(loadfile(APP_DIR .. "/resolve/windows_process.lua"))()
local STATE_PATH = APP_DIR .. "/state.txt"
local CONFIG_PATH = APP_DIR .. "/config.json"
local LOG_PATH = APP_DIR .. "/streamer_voice.log"
local BACKEND_PATH = APP_DIR .. "/backend/analyze.py"
local PAUSE_BACKEND_PATH = APP_DIR .. "/backend/pauses.py"
local VIDEO_PAUSE_BACKEND_PATH = APP_DIR .. "/backend/video_pauses.py"
local PROFILE_BACKEND_PATH = APP_DIR .. "/backend/profile.py"
local AD_SAFETY_BACKEND_PATH = APP_DIR .. "/backend/ad_safety.py"
local CENSOR_BACKEND_PATH = APP_DIR .. "/backend/censor.py"
local TIMELINE_FADES_BACKEND_PATH = APP_DIR .. "/backend/timeline_fades.py"
local UPDATE_BACKEND_PATH = APP_DIR .. "/backend/check_updates.py"
local UPDATE_CACHE_PATH = APP_DIR .. "/updates.txt"
local GITHUB_URL = "https://github.com/0xDive/cliptimbre"
local TELEGRAM_URL = "https://t.me/dev_dive"
local AD_SAFETY_TERMS_PATH = APP_DIR .. "/ad_safety_terms.json"
local ACTIVE_PROFILE_PATH = APP_DIR .. "/active_profile.txt"
local LATEST_RESULT_PATH = APP_DIR .. "/latest_result.json"
local LATEST_PAUSES_PATH = APP_DIR .. "/latest_pauses.tsv"
local LATEST_PAUSES_JSON_PATH = APP_DIR .. "/latest_pauses.json"
local PAUSE_STATE_PATH = APP_DIR .. "/pause_state.txt"
local ANALYSIS_STATE_PATH = APP_DIR .. "/analysis_state.txt"
local LATEST_MANIFEST_PATH = APP_DIR .. "/latest_timeline_manifest.json"
local LATEST_AD_SAFETY_PATH = APP_DIR .. "/latest_ad_safety.tsv"
local LATEST_AD_SAFETY_JSON_PATH = APP_DIR .. "/latest_ad_safety.json"
local YOUTUBE_STATE_PATH = APP_DIR .. "/youtube_state.txt"
local CENSORED_DIR = APP_DIR .. "/censored"
local VENV_PYTHON = APP_DIR .. (IS_WINDOWS and "/.venv/Scripts/pythonw.exe" or "/.venv/bin/python")
local MARKER_PREFIX = "[SV]"
local MARKER_CUSTOM = "streamer_voice_match_v1"
local REF_CUSTOM = "streamer_voice_reference_v1"
local PAUSE_CUSTOM = "streamer_voice_pause_v1"
local PAUSE_REVIEW_CUSTOM = "streamer_voice_pause_review_v1"
local VIDEO_HOLD_CUSTOM = "cliptimbre_video_hold_v1"
local YT_REVIEW_CUSTOM = "streamer_voice_youtube_review_v1"
local YT_HIGH_CUSTOM = "streamer_voice_youtube_high_v1"
local YT_MUTED_CUSTOM = "streamer_voice_youtube_muted_v1"
-- Distinct from Voice (Green/Yellow/Blue) and Pauses (Purple/Red).
local YT_REVIEW_COLOR = "Cyan"
local YT_HIGH_COLOR = "Pink"
local YT_PERSONAL_COLOR = "Sand"
local YT_MUTED_COLOR = "Fuchsia"

local defaults = {
    reference_duration_seconds = 10.0,
    threshold = 0.35,
    high_confidence_margin = 0.12,
    window_seconds = 2.4,
    hop_seconds = 0.8,
    min_speech_seconds = 0.55,
    merge_gap_seconds = 0.7,
    pause_merge_gap_seconds = 3.0,
    pause_speech_tolerance_seconds = 0.65,
    long_silence_merge_gap_seconds = 5.0,
    long_silence_speech_tolerance_seconds = 0.15,
    marker_pad_before_seconds = 0.0,
    marker_pad_after_seconds = 0.0,
    vad_pad_ms = 20,
    vad_min_silence_ms = 120,
    refine_boundaries = true,
    boundary_vad_snap_seconds = 0.75,
    boundary_search_seconds = 0.90,
    boundary_step_seconds = 0.10,
    boundary_window_seconds = 0.90,
    boundary_threshold_relax = 0.04,
    boundary_min_contrast = 0.035,
    cache_enabled = true,
    batch_size = 24,
    pause_trim_min_seconds = 0.80,
    pause_trim_target_seconds = 0.22,
    pause_trim_max_auto_seconds = 4.0,
    pause_trim_review_max_seconds = 8.0,
    pause_trim_edge_protect_seconds = 1.5,
    pause_trim_min_delete_seconds = 0.35,
    pause_trim_require_backup = true,
    pause_trim_ui_delay_seconds = 0.08,
    device = "auto",
    speaker_model = "speechbrain/spkrec-ecapa-voxceleb",
    audio_source_mode = "auto",
    ad_safety_model = "small",
    ad_safety_language = "auto",
    ad_safety_device = "auto",
    ad_safety_engine = "auto",
    ad_safety_chunk_seconds = 600.0,
    ad_safety_stall_timeout_seconds = 900.0,
    ad_safety_model_load_timeout_seconds = 1800.0,
    ad_safety_marker_pad_seconds = 0.15,
    youtube_censor_pad_before_seconds = 0.08,
    youtube_censor_pad_after_seconds = 0.12,
    youtube_censor_beep_hz = 1000.0,
    youtube_censor_beep_db = -12.0,
    youtube_censor_fade_ms = 70.0,
    youtube_censor_beep_duck_db = -36.0,
    youtube_censor_flatten_audio = true,
    youtube_censor_track_name = "YT Censored Mix",
}

local function shell_quote(s)
    s = tostring(s or "")
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function shell_command(args)
    local quoted = {}
    for i, arg in ipairs(args) do quoted[i] = shell_quote(arg) end
    return table.concat(quoted, " ")
end

local function mkdir_p(path)
    if windows then return windows.mkdir_p(path) end
    os.execute("mkdir -p " .. shell_quote(path))
end

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_all(path, data)
    local f, err = io.open(path, "wb")
    if not f then error(err or ("Cannot write " .. path)) end
    f:write(data)
    f:close()
end

local function copy_file(src, dst)
    local input, err = io.open(src, "rb")
    if not input then error(err or ("Cannot read " .. tostring(src))) end
    local data = input:read("*a")
    input:close()
    write_all(dst, data)
end

local function windows_args(args)
    if args[1] ~= VENV_PYTHON then return args end
    local utf8_args = {VENV_PYTHON, "-X", "utf8"}
    for i = 2, #args do utf8_args[#utf8_args + 1] = args[i] end
    return utf8_args
end

local function remove_tree(path)
    if windows then
        windows.run(windows_args({VENV_PYTHON, "-c",
            "import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)", path}))
    else
        os.execute("rm -rf " .. shell_quote(path))
    end
end

local function run_capture(args, redirect_stderr)
    if windows then
        mkdir_p(APP_DIR .. "/tmp")
        local path = APP_DIR .. "/tmp/capture_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
        local ok, err = windows.run(windows_args(args), path, redirect_stderr and LOG_PATH or nil)
        local out = ok and read_all(path)
        os.remove(path)
        if err then error(err) end
        return out and (out:gsub("%s+$", "")) or nil
    end
    local suffix = redirect_stderr and " 2>>" .. shell_quote(LOG_PATH) or " 2>/dev/null"
    local p = io.popen(shell_command(args) .. suffix)
    if not p then return nil end
    local out = p:read("*a") or ""
    local ok, why, code = p:close()
    if ok == nil and tonumber(code or 1) ~= 0 then return nil end
    return (out:gsub("%s+$", ""))
end

local function run_powershell_capture(script)
    mkdir_p(APP_DIR .. "/tmp")
    local path = APP_DIR .. "/tmp/sv_ps_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".ps1"
    -- Windows PowerShell reads UTF-8 scripts with a BOM.
    write_all(path, "\239\187\191[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)\r\n" .. script)
    local out = run_capture({windows.system_exe("WindowsPowerShell\\v1.0\\powershell.exe"),
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path}, true)
    os.remove(path)
    return out
end

local function ps_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "''") .. "'"
end

local function find_first_file(dir, prefix)
    if windows then
        local name = windows.files(dir, prefix .. ".*", true)[1]
        return name and (dir .. "/" .. name) or nil
    end
    local cmd = "find " .. shell_quote(dir) .. " -maxdepth 1 -type f -name " .. shell_quote(prefix .. ".*") .. " -print | head -n 1"
    local p = io.popen(cmd)
    local media = p and p:read("*l") or nil
    if p then p:close() end
    return media
end

local function log(msg)
    mkdir_p(APP_DIR)
    local line = os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg)
    print(line)
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(line, "\n")
        f:close()
    end
end

local function notify(msg, title)
    title = title or "ClipTimbre"
    log(msg)
    if IS_WINDOWS then
        -- The panel status + log are enough on Windows; avoid spawning a modal
        -- PowerShell window for every navigation notification.
        return
    end
    if IS_LINUX then
        os.execute("notify-send -- " .. shell_quote(title) .. " " .. shell_quote(msg) .. " >/dev/null 2>&1 &")
        return
    end
    local script = 'display notification ' .. string.format('%q', tostring(msg)) .. ' with title ' .. string.format('%q', tostring(title))
    os.execute("osascript -e " .. shell_quote(script) .. " >/dev/null 2>&1 &")
end

local function fail(msg)
    notify("ERROR: " .. tostring(msg))
    error(msg)
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function parse_number(text, key, fallback)
    if not text then return fallback end
    local pat = '"' .. key .. '"%s*:%s*([%+%-]?[%d%.]+)'
    local v = text:match(pat)
    return tonumber(v) or fallback
end

local function parse_string(text, key, fallback)
    if not text then return fallback end
    local pat = '"' .. key .. '"%s*:%s*"([^"]*)"'
    return text:match(pat) or fallback
end

local function parse_bool(text, key, fallback)
    if not text then return fallback end
    local pat = '"' .. key .. '"%s*:%s*(%a+)'
    local v = text:match(pat)
    if v == "true" then return true end
    if v == "false" then return false end
    return fallback
end

local function load_config()
    local txt = read_all(CONFIG_PATH)
    local c = {}
    for k, v in pairs(defaults) do c[k] = v end
    c.reference_duration_seconds = parse_number(txt, "reference_duration_seconds", c.reference_duration_seconds)
    c.threshold = parse_number(txt, "threshold", c.threshold)
    c.high_confidence_margin = parse_number(txt, "high_confidence_margin", c.high_confidence_margin)
    c.window_seconds = parse_number(txt, "window_seconds", c.window_seconds)
    c.hop_seconds = parse_number(txt, "hop_seconds", c.hop_seconds)
    c.min_speech_seconds = parse_number(txt, "min_speech_seconds", c.min_speech_seconds)
    c.merge_gap_seconds = parse_number(txt, "merge_gap_seconds", c.merge_gap_seconds)
    c.pause_merge_gap_seconds = parse_number(txt, "pause_merge_gap_seconds", c.pause_merge_gap_seconds)
    c.pause_speech_tolerance_seconds = parse_number(txt, "pause_speech_tolerance_seconds", c.pause_speech_tolerance_seconds)
    c.long_silence_merge_gap_seconds = parse_number(txt, "long_silence_merge_gap_seconds", c.long_silence_merge_gap_seconds)
    c.long_silence_speech_tolerance_seconds = parse_number(txt, "long_silence_speech_tolerance_seconds", c.long_silence_speech_tolerance_seconds)
    c.marker_pad_before_seconds = parse_number(txt, "marker_pad_before_seconds", c.marker_pad_before_seconds)
    c.marker_pad_after_seconds = parse_number(txt, "marker_pad_after_seconds", c.marker_pad_after_seconds)
    c.vad_pad_ms = parse_number(txt, "vad_pad_ms", c.vad_pad_ms)
    c.vad_min_silence_ms = parse_number(txt, "vad_min_silence_ms", c.vad_min_silence_ms)
    c.refine_boundaries = parse_bool(txt, "refine_boundaries", c.refine_boundaries)
    c.boundary_vad_snap_seconds = parse_number(txt, "boundary_vad_snap_seconds", c.boundary_vad_snap_seconds)
    c.boundary_search_seconds = parse_number(txt, "boundary_search_seconds", c.boundary_search_seconds)
    c.boundary_step_seconds = parse_number(txt, "boundary_step_seconds", c.boundary_step_seconds)
    c.boundary_window_seconds = parse_number(txt, "boundary_window_seconds", c.boundary_window_seconds)
    c.boundary_threshold_relax = parse_number(txt, "boundary_threshold_relax", c.boundary_threshold_relax)
    c.boundary_min_contrast = parse_number(txt, "boundary_min_contrast", c.boundary_min_contrast)
    c.cache_enabled = parse_bool(txt, "cache_enabled", c.cache_enabled)
    c.batch_size = parse_number(txt, "batch_size", c.batch_size)
    c.pause_trim_min_seconds = parse_number(txt, "pause_trim_min_seconds", c.pause_trim_min_seconds)
    c.pause_trim_target_seconds = parse_number(txt, "pause_trim_target_seconds", c.pause_trim_target_seconds)
    c.pause_trim_max_auto_seconds = parse_number(txt, "pause_trim_max_auto_seconds", c.pause_trim_max_auto_seconds)
    c.pause_trim_review_max_seconds = parse_number(txt, "pause_trim_review_max_seconds", c.pause_trim_review_max_seconds)
    c.pause_trim_edge_protect_seconds = parse_number(txt, "pause_trim_edge_protect_seconds", c.pause_trim_edge_protect_seconds)
    c.pause_trim_min_delete_seconds = parse_number(txt, "pause_trim_min_delete_seconds", c.pause_trim_min_delete_seconds)
    c.pause_trim_require_backup = parse_bool(txt, "pause_trim_require_backup", c.pause_trim_require_backup)
    c.pause_trim_ui_delay_seconds = parse_number(txt, "pause_trim_ui_delay_seconds", c.pause_trim_ui_delay_seconds)
    c.device = parse_string(txt, "device", c.device)
    c.speaker_model = parse_string(txt, "speaker_model", c.speaker_model)
    c.audio_source_mode = parse_string(txt, "audio_source_mode", c.audio_source_mode)
    c.ad_safety_model = parse_string(txt, "ad_safety_model", c.ad_safety_model)
    c.ad_safety_language = parse_string(txt, "ad_safety_language", c.ad_safety_language)
    c.ad_safety_device = parse_string(txt, "ad_safety_device", c.ad_safety_device)
    c.ad_safety_engine = parse_string(txt, "ad_safety_engine", c.ad_safety_engine)
    c.ad_safety_chunk_seconds = parse_number(txt, "ad_safety_chunk_seconds", c.ad_safety_chunk_seconds)
    c.ad_safety_stall_timeout_seconds = parse_number(txt, "ad_safety_stall_timeout_seconds", c.ad_safety_stall_timeout_seconds)
    c.ad_safety_model_load_timeout_seconds = parse_number(txt, "ad_safety_model_load_timeout_seconds", c.ad_safety_model_load_timeout_seconds)
    c.ad_safety_marker_pad_seconds = parse_number(txt, "ad_safety_marker_pad_seconds", c.ad_safety_marker_pad_seconds)
    c.youtube_censor_pad_before_seconds = parse_number(txt, "youtube_censor_pad_before_seconds", c.youtube_censor_pad_before_seconds)
    c.youtube_censor_pad_after_seconds = parse_number(txt, "youtube_censor_pad_after_seconds", c.youtube_censor_pad_after_seconds)
    c.youtube_censor_beep_hz = parse_number(txt, "youtube_censor_beep_hz", c.youtube_censor_beep_hz)
    c.youtube_censor_beep_db = parse_number(txt, "youtube_censor_beep_db", c.youtube_censor_beep_db)
    c.youtube_censor_fade_ms = parse_number(txt, "youtube_censor_fade_ms", c.youtube_censor_fade_ms)
    c.youtube_censor_beep_duck_db = parse_number(txt, "youtube_censor_beep_duck_db", c.youtube_censor_beep_duck_db)
    c.youtube_censor_flatten_audio = parse_bool(txt, "youtube_censor_flatten_audio", c.youtube_censor_flatten_audio)
    c.youtube_censor_track_name = parse_string(txt, "youtube_censor_track_name", c.youtube_censor_track_name)
    return c
end

local function get_resolve()
    local r = nil
    if type(resolve) ~= "nil" and resolve then r = resolve end
    if not r and type(bmd) ~= "nil" and bmd and bmd.scriptapp then
        r = bmd.scriptapp("Resolve")
    end
    if not r and type(Resolve) == "function" then
        r = Resolve()
    end
    if not r then fail("Cannot connect to DaVinci Resolve from Lua") end
    return r
end

local function get_context()
    local r = get_resolve()
    local pm = r:GetProjectManager()
    local project = pm and pm:GetCurrentProject() or nil
    if not project then fail("No current project") end
    local timeline = project:GetCurrentTimeline()
    if not timeline then fail("No current timeline") end
    return r, project, timeline
end

local function unique_id(item)
    if not item then return nil end
    local ok, value = pcall(function() return item:GetUniqueId() end)
    if ok and value and tostring(value) ~= "" then return tostring(value) end
end

local function timeline_id(timeline)
    local id = unique_id(timeline)
    if id then return id end
    return tostring(timeline:GetName())
end

local function normalized_fps(value)
    local fps = tonumber(tostring(value or ""):match("^%s*(%d+%.?%d*)"))
    if not fps or fps < 1 or fps > 240 then return nil end
    for _, nominal in ipairs({24, 30, 48, 60, 120}) do
        local fractional = nominal * 1000 / 1001
        if math.abs(fps - fractional) < 0.02 then return fractional end
    end
    return fps
end

local function get_fps(timeline)
    local value = timeline:GetSetting("timelineFrameRate")
    local fps = normalized_fps(value)
    if not fps then fail("Could not determine timeline frame rate: " .. tostring(value)) end
    return fps
end

local function drop_params(fps)
    local nominal = math.floor(fps + 0.5)
    if math.abs(fps - 29.97) < 0.02 then return nominal, 2 end
    if math.abs(fps - 59.94) < 0.02 then return nominal, 4 end
    return nominal, 0
end

local function timecode_to_frames(tc, fps)
    if not tc then fail("Timeline returned no timecode") end
    local drop = tc:find(";", 1, true) ~= nil
    local clean = tc:gsub(";", ":")
    local hh, mm, ss, ff = clean:match("^(%d+):(%d+):(%d+):(%d+)$")
    if not hh then fail("Bad timecode: " .. tostring(tc)) end
    hh, mm, ss, ff = tonumber(hh), tonumber(mm), tonumber(ss), tonumber(ff)
    local nominal, drop_frames = drop_params(fps)
    local total_minutes = 60 * hh + mm
    local frames = ((hh * 3600 + mm * 60 + ss) * nominal) + ff
    if drop and drop_frames > 0 then
        frames = frames - drop_frames * (total_minutes - math.floor(total_minutes / 10))
    end
    return frames
end

local function frames_to_timecode(frames, fps, drop)
    frames = math.max(0, math.floor(frames + 0.5))
    local nominal, drop_frames = drop_params(fps)
    if not drop or drop_frames == 0 then
        local hh = math.floor(frames / (nominal * 3600))
        frames = frames % (nominal * 3600)
        local mm = math.floor(frames / (nominal * 60))
        frames = frames % (nominal * 60)
        local ss = math.floor(frames / nominal)
        local ff = frames % nominal
        return string.format("%02d:%02d:%02d:%02d", hh, mm, ss, ff)
    end

    local frames_per_10_minutes = nominal * 60 * 10 - drop_frames * 9
    local frames_per_minute = nominal * 60 - drop_frames
    local d = math.floor(frames / frames_per_10_minutes)
    local m = frames % frames_per_10_minutes
    local extra_minutes = 0
    if m >= drop_frames then
        extra_minutes = math.floor((m - drop_frames) / frames_per_minute)
    end
    local total_minutes = d * 10 + extra_minutes
    local dropped = drop_frames * (total_minutes - math.floor(total_minutes / 10))
    local tc_frames = frames + dropped
    local hh = math.floor(tc_frames / (nominal * 3600))
    tc_frames = tc_frames % (nominal * 3600)
    local mm = math.floor(tc_frames / (nominal * 60))
    tc_frames = tc_frames % (nominal * 60)
    local ss = math.floor(tc_frames / nominal)
    local ff = tc_frames % nominal
    return string.format("%02d:%02d:%02d;%02d", hh, mm, ss, ff)
end

local function current_relative_frame(timeline, fps)
    return timecode_to_frames(timeline:GetCurrentTimecode(), fps) - timecode_to_frames(timeline:GetStartTimecode(), fps)
end

local function relative_frame_to_timecode(timeline, rel_frame, fps)
    local start_tc = timeline:GetStartTimecode()
    local drop = start_tc:find(";", 1, true) ~= nil
    local absolute = timecode_to_frames(start_tc, fps) + rel_frame
    return frames_to_timecode(absolute, fps, drop)
end

local function marker_field(data, key)
    if type(data) ~= "table" then return "" end
    return tostring(data[key] or "")
end

local function delete_markers(timeline, kind)
    local deleted = 0
    local markers = timeline:GetMarkers() or {}
    for frame, data in pairs(markers) do
        local name = marker_field(data, "name")
        local custom = marker_field(data, "customData")
        local should = false
        if kind == "matches" then
            should = (custom == MARKER_CUSTOM) or (name:sub(1, #MARKER_PREFIX + 9) == MARKER_PREFIX .. " STREAMER")
        elseif kind == "reference" then
            should = (custom == REF_CUSTOM) or (name:sub(1, #MARKER_PREFIX + 10) == MARKER_PREFIX .. " REFERENCE")
        elseif kind == "pauses" then
            should = (custom == PAUSE_CUSTOM) or (custom == PAUSE_REVIEW_CUSTOM) or (name:sub(1, #MARKER_PREFIX + 6) == MARKER_PREFIX .. " PAUSE") or (name:sub(1, #MARKER_PREFIX + 11) == MARKER_PREFIX .. " LONG PAUSE")
        elseif kind == "video_holds" then
            should = custom == VIDEO_HOLD_CUSTOM
        elseif kind == "youtube" then
            should = (custom == YT_REVIEW_CUSTOM) or (custom == YT_HIGH_CUSTOM) or (name:sub(1, 4) == "[YT]")
        elseif kind == "all" then
            should = (custom == MARKER_CUSTOM) or (custom == REF_CUSTOM) or (custom == PAUSE_CUSTOM) or (custom == PAUSE_REVIEW_CUSTOM) or (custom == YT_REVIEW_CUSTOM) or (custom == YT_HIGH_CUSTOM) or (name:sub(1, #MARKER_PREFIX) == MARKER_PREFIX) or (name:sub(1, 4) == "[YT]")
        end
        if should then
            local ok = timeline:DeleteMarkerAtFrame(frame)
            if ok then deleted = deleted + 1 end
        end
    end
    return deleted
end

local function save_state(state)
    mkdir_p(APP_DIR)
    local lines = {}
    for k, v in pairs(state) do
        table.insert(lines, tostring(k) .. "=" .. tostring(v))
    end
    table.sort(lines)
    write_all(STATE_PATH, table.concat(lines, "\n") .. "\n")
end

local function load_state()
    local txt = read_all(STATE_PATH)
    if not txt then fail("No voice reference. Run 'Set Voice Reference' first.") end
    local state = {}
    for line in txt:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then state[k] = v end
    end
    return state
end

local function load_state_optional()
    local txt = read_all(STATE_PATH)
    if not txt then return nil end
    local state = {}
    for line in txt:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then state[k] = v end
    end
    return state
end

local function active_profile_name()
    local txt = read_all(ACTIVE_PROFILE_PATH)
    if txt then
        local name = txt:match("^%s*(.-)%s*$")
        if name and name ~= "" then return name end
    end
    return "Streamer"
end

local function active_profile_reference_count()
    local dir = APP_DIR .. "/profiles/" .. active_profile_name() .. "/refs"
    if windows then return #windows.files(dir, "ref_*.wav") end
    local cmd = "find " .. shell_quote(dir) .. " -maxdepth 1 -type f -name 'ref_*.wav' 2>/dev/null | wc -l"
    local p = io.popen(cmd)
    local value = p and p:read("*l") or "0"
    if p then p:close() end
    return tonumber((tostring(value):match("%d+"))) or 0
end

function M.set_reference()
    local _, _, timeline = get_context()
    local cfg = load_config()
    local fps = get_fps(timeline)
    local rel_frame = current_relative_frame(timeline, fps)
    local available = timeline:GetEndFrame() - timeline:GetStartFrame() - rel_frame
    local duration_frames = math.min(available, math.floor(cfg.reference_duration_seconds * fps + 0.5))
    if rel_frame < 0 or duration_frames / fps < 1 then
        fail("Move the playhead to a phrase with at least one second of audio remaining")
    end
    local duration_sec = duration_frames / fps

    delete_markers(timeline, "reference")
    local ok = timeline:AddMarker(
        rel_frame,
        "Blue",
        MARKER_PREFIX .. " REFERENCE",
        string.format("Voice reference: %.1fs from playhead", duration_sec),
        duration_frames,
        REF_CUSTOM
    )
    if not ok then fail("Resolve refused to add the reference marker") end

    save_state({
        version = 2,
        timeline_id = timeline_id(timeline),
        timeline_name = timeline:GetName(),
        reference_frame = rel_frame,
        reference_seconds = rel_frame / fps,
        reference_duration_seconds = duration_sec,
        fps = fps,
        timecode = timeline:GetCurrentTimecode(),
    })
    notify(string.format("Reference saved: %.1fs from %s", duration_sec, timeline:GetCurrentTimecode()))
end

local function safe_number_call(fn)
    local ok, value = pcall(fn)
    if ok and tonumber(value) then return tonumber(value) end
    return nil
end

local function optional_call(fn)
    local ok, value = pcall(fn)
    if ok then return value end
end

local function timeline_span(timeline)
    return timeline:GetEndFrame() - timeline:GetStartFrame()
end

local function timeline_layout(timeline, track_types)
    local values = {}
    local function add(value)
        local field = tostring(value):gsub("%%", "%%25"):gsub("\r", "%%0D"):gsub("\n", "%%0A")
        values[#values + 1] = #field .. ":" .. field
    end
    add(timeline:GetStartFrame())
    add(timeline:GetEndFrame())
    for _, kind in ipairs(track_types) do
        local count = timeline:GetTrackCount(kind) or 0
        add(count)
        for track = 1, count do
            add(optional_call(function() return timeline:GetIsTrackEnabled(kind, track) end))
            local items = timeline:GetItemListInTrack(kind, track) or {}
            add(#items)
            for _, item in ipairs(items) do
                add(optional_call(function() return item:GetUniqueId() end) or item:GetName())
                add(item:GetStart())
                add(item:GetEnd())
                add(optional_call(function() return item:GetSourceStartFrame() end))
                add(optional_call(function() return item:GetLeftOffset(true) end))
                add(optional_call(function() return item:GetSourceEndFrame() end))
                add(optional_call(function() return item:GetClipEnabled() end))
                if kind == "audio" then
                    local media = optional_call(function() return item:GetMediaPoolItem() end)
                    local path = media and optional_call(function() return media:GetClipProperty("File Path") end)
                    if type(path) == "table" then path = path["File Path"] end
                    local speed = optional_call(function() return item:GetProperty("Speed") end)
                    if type(speed) == "table" then speed = speed.Speed or speed.speed end
                    add(path)
                    add(optional_call(function() return item:GetSourceAudioChannelMapping() end))
                    add(speed)
                end
            end
        end
    end
    return table.concat(values)
end

local function json_escape(value)
    local v = tostring(value or "")
    v = v:gsub("\\", "\\\\")
    v = v:gsub('"', '\\"')
    v = v:gsub("\r", "\\r")
    v = v:gsub("\n", "\\n")
    v = v:gsub("\t", "\\t")
    return v
end

local function write_timeline_audio_manifest(timeline, fps, path)
    local timeline_start = safe_number_call(function() return timeline:GetStartFrame() end) or 0
    local timeline_end = safe_number_call(function() return timeline:GetEndFrame() end)
    if not timeline_end then
        fail("Could not determine timeline end frame for cut-timeline audio map")
    end
    local timeline_duration = math.max(0, (timeline_end - timeline_start) / fps)
    local track_count = safe_number_call(function() return timeline:GetTrackCount("audio") end) or 0
    local clips = {}
    local complete = true
    local unsupported = 0

    for track = 1, track_count do
        local track_enabled = true
        local enabled_ok, enabled_value = pcall(function() return timeline:GetIsTrackEnabled("audio", track) end)
        if enabled_ok and enabled_value == false then track_enabled = false end
        if track_enabled then
            local ok, items = pcall(function() return timeline:GetItemListInTrack("audio", track) end)
            if ok and type(items) == "table" then
                for _, item in ipairs(items) do
                    local clip_enabled = true
                    local ce_ok, ce = pcall(function() return item:GetClipEnabled() end)
                    if ce_ok and ce == false then clip_enabled = false end
                    if clip_enabled then
                        local item_start = safe_number_call(function() return item:GetStart() end)
                        local duration_frames = safe_number_call(function() return item:GetDuration() end)
                        local left = safe_number_call(function() return item:GetLeftOffset(true) end) or
                            safe_number_call(function() return item:GetLeftOffset() end)
                        local media = nil
                        pcall(function() media = item:GetMediaPoolItem() end)
                        local file_path = nil
                        if media then
                            pcall(function() file_path = media:GetClipProperty("File Path") end)
                            if type(file_path) == "table" then file_path = file_path["File Path"] end
                        end

                        local speed = nil
                        pcall(function() speed = item:GetProperty("Speed") end)
                        if type(speed) == "table" then speed = speed.Speed or speed.speed end
                        local speed_num = tonumber(speed)
                        local mapping = optional_call(function() return item:GetSourceAudioChannelMapping() end)
                        local linked = type(mapping) == "string" and mapping:match('"linked_audio"%s*:%s*{%s*([^%s}])')
                        local muted = type(mapping) == "string" and mapping:match('"mute"%s*:%s*true')
                        local isolation = optional_call(function() return item:GetVoiceIsolationState() end)
                        if linked or muted or (type(isolation) == "table" and isolation.isEnabled == true) then
                            complete = false
                            unsupported = unsupported + 1
                            log("Cut-timeline map requires a render for mapped or processed audio on track " .. tostring(track))
                        elseif speed_num and math.abs(speed_num - 100.0) > 0.01 and math.abs(speed_num - 1.0) > 0.001 then
                            complete = false
                            unsupported = unsupported + 1
                            log("Cut-timeline map skipped retimed audio item on track " .. tostring(track))
                        elseif item_start and duration_frames and left and file_path and tostring(file_path) ~= "" and file_exists(tostring(file_path)) then
                            local rel_start = (item_start - timeline_start) / fps
                            local duration = duration_frames / fps
                            local source_offset = left / fps
                            local source_fps = normalized_fps(optional_call(function() return media:GetClipProperty("FPS") end))
                            local source_frame = safe_number_call(function() return item:GetSourceStartFrame() end)
                            if source_fps and source_frame and source_frame >= 0 and left == math.floor(left) then
                                local precise_offset = source_frame / source_fps
                                if math.abs(precise_offset - source_offset) <= 1.1 / source_fps then
                                    source_offset = precise_offset
                                end
                            end
                            if rel_start < 0 then
                                local trim = -rel_start
                                source_offset = source_offset + trim
                                duration = duration - trim
                                rel_start = 0
                            end
                            if rel_start + duration > timeline_duration then
                                duration = timeline_duration - rel_start
                            end
                            if duration > 0.001 then
                                table.insert(clips, {
                                    path = tostring(file_path),
                                    timeline_start = rel_start,
                                    source_offset = source_offset,
                                    duration = duration,
                                    track = track,
                                })
                            end
                        else
                            complete = false
                            unsupported = unsupported + 1
                            log("Cut-timeline map found an audio item that cannot be mapped to a file source on track " .. tostring(track))
                        end
                    end
                end
            end
        end
    end

    if #clips == 0 then
        return {path=path, complete=false, clip_count=0, unsupported=unsupported, duration=timeline_duration}
    end

    table.sort(clips, function(a,b)
        if a.timeline_start == b.timeline_start then return a.track < b.track end
        return a.timeline_start < b.timeline_start
    end)
    local parts = {
        '{"version":1,"fps":' .. string.format("%.9f", fps) .. ',"duration_seconds":' .. string.format("%.9f", timeline_duration) .. ',"clips":['
    }
    for i, c in ipairs(clips) do
        if i > 1 then table.insert(parts, ",") end
        table.insert(parts, string.format(
            '{"path":"%s","timeline_start":%.9f,"source_offset":%.9f,"duration":%.9f,"track":%d}',
            json_escape(c.path), c.timeline_start, c.source_offset, c.duration, c.track
        ))
    end
    table.insert(parts, "]}\n")
    write_all(path, table.concat(parts))
    log(string.format("Cut-timeline audio map: clips=%d complete=%s unsupported=%d duration=%.3fs", #clips, tostring(complete), unsupported, timeline_duration))
    return {path=path, complete=complete, clip_count=#clips, first=clips[1], unsupported=unsupported, duration=timeline_duration}
end

local function find_audio_render_container(project)
    -- Resolve's scripting API currently exposes Wave/WAV with an empty codec
    -- list, and SetCurrentRenderFormatAndCodec() refuses an empty codec.  So an
    -- audio-only WAV render cannot be selected reliably through the API.
    --
    -- Instead, render an audio-only QuickTime file.  The container still has a
    -- normal video codec value (required by SetCurrentRenderFormatAndCodec),
    -- while ExportVideo=false means Resolve only writes the timeline audio mix.
    local formats = project:GetRenderFormats() or {}
    local format_ext = nil
    local format_name = nil

    -- Prefer QuickTime/mov because Linear PCM audio is available by default on
    -- macOS and, unlike Wave, mov exposes normal format/codec pairs to scripts.
    for name, ext in pairs(formats) do
        local e = tostring(ext):lower():gsub("^%.", "")
        local n = tostring(name):lower()
        if e == "mov" or n:find("quicktime", 1, true) then
            format_ext = e
            format_name = tostring(name)
            break
        end
    end
    if not format_ext then
        fail("Resolve render API did not expose a QuickTime/mov format for temporary audio export")
    end

    local available = {}
    local fallback = {}
    for _, value in pairs(project:GetRenderCodecs(format_ext) or {}) do
        if type(value) == "string" and value ~= "" then
            available[value:lower():gsub("[^%w]", "")] = value
            fallback[#fallback+1] = value
        end
    end
    local candidates = {}
    for _, key in ipairs({"h264", "prores422", "h265", "prores422lt"}) do
        if available[key] then candidates[#candidates+1] = available[key] end
    end
    if #candidates == 0 then
        table.sort(fallback)
        candidates[1] = fallback[1]
    end
    if #candidates == 0 then
        fail("Resolve exposed QuickTime/mov but no selectable codec for temporary audio")
    end

    log("Temporary audio render container: " .. tostring(format_name) .. " (" .. format_ext .. ")")
    return format_ext, candidates
end

local function wait_seconds(sec)
    sec = math.max(0.01, tonumber(sec) or 0.01)
    if type(bmd) ~= "nil" and bmd and bmd.wait then
        bmd.wait(sec)
    elseif windows then
        windows.sleep(sec)
    else
        os.execute("sleep " .. tostring(sec))
    end
end

local function render_timeline_audio(project, timeline, target_dir)
    if project:IsRenderingInProgress() then fail("Wait for the current Resolve render to finish") end
    mkdir_p(target_dir)
    local custom_name = "streamer_voice_timeline"
    local fmt, codecs = find_audio_render_container(project)
    local old = nil
    pcall(function() old = project:GetCurrentRenderFormatAndCodec() end)
    local old_mode = optional_call(function() return project:GetCurrentRenderMode() end)
    local preset_name = "__SV_Render_" .. target_dir:match("[^/\\]+$")
    local saved_preset = optional_call(function() return project:SaveAsNewRenderPreset(preset_name) end)
    local job_id = nil

    local function cleanup()
        if job_id then pcall(function() project:DeleteRenderJob(job_id) end) end
        if saved_preset then
            local restored = optional_call(function() return project:LoadRenderPreset(preset_name) end)
            optional_call(function() project:DeleteRenderPreset(preset_name) end)
            if restored then return end
            log("Resolve could not restore the full Deliver preset")
        end
        if old_mode ~= nil then optional_call(function() project:SetCurrentRenderMode(old_mode) end) end
        if type(old) == "table" then
            local old_fmt = old.format or old.Format
            local old_codec = old.codec or old.Codec
            if old_fmt and old_codec and tostring(old_fmt) ~= "" and tostring(old_codec) ~= "" then
                pcall(function() project:SetCurrentRenderFormatAndCodec(old_fmt, old_codec) end)
            end
        end
    end

    local ok, result = pcall(function()
        -- Even with video disabled, an audio-only QuickTime job requires a
        -- valid video codec. Try the available candidates without starting
        -- any other jobs in the user's queue.
        local settings = {
            TargetDir = target_dir,
            CustomName = custom_name,
            ExportVideo = false,
            ExportAudio = true,
            SelectAllFrames = true,
        }
        local started = false
        for _, codec in ipairs(codecs) do
            log("Trying temporary audio render with " .. codec)
            if project:SetCurrentRenderFormatAndCodec(fmt, codec) then
                local mode = optional_call(function() return project:GetCurrentRenderMode() end)
                if mode == 0 and not project:SetCurrentRenderMode(1) then
                    fail("Resolve could not switch to Single Clip rendering")
                end
                if project:SetRenderSettings(settings) then
                    job_id = project:AddRenderJob()
                    if job_id and job_id ~= "" then
                        started = optional_call(function() return project:StartRendering({job_id}, false) end)
                        if not started then
                            local status = project:GetRenderJobStatus(job_id) or {}
                            started = project:IsRenderingInProgress() or status.JobStatus == "Complete"
                        end
                        if not started then
                            started = optional_call(function() return project:StartRendering(job_id) end)
                        end
                        if started then break end
                        project:DeleteRenderJob(job_id)
                        job_id = nil
                    end
                end
            end
        end
        if not started then fail("Resolve could not start the temporary audio render with the available codecs") end

        notify("Rendering current timeline audio…")
        local deadline = os.time() + 4 * 60 * 60
        while project:IsRenderingInProgress() do
            if os.time() > deadline then
                pcall(function() project:StopRendering() end)
                fail("Timeline audio render timed out")
            end
            wait_seconds(0.5)
        end

        local status = project:GetRenderJobStatus(job_id) or {}
        local job_status = tostring(status.JobStatus or ""):lower()
        if job_status ~= "complete" and job_status ~= "completed" then
            fail("Resolve audio render did not complete: " .. tostring(status.JobStatus or "unknown status"))
        end
        -- Audio-only QuickTime normally produces .mov. Search by our unique
        -- basename rather than assuming an extension so this survives Resolve
        -- format changes.
        local media = find_first_file(target_dir, custom_name)
        if not media or media == "" then
            fail("Resolve finished rendering but no temporary audio media appeared in " .. target_dir)
        end
        log("Temporary timeline audio media: " .. tostring(media))
        return media
    end)
    cleanup()
    if not ok then error(result) end
    return result
end

local function prepare_timeline_audio_source(project, timeline, fps, run_dir, cfg)
    local manifest_path = run_dir .. "/timeline_audio_manifest.json"
    local manifest
    if cfg.audio_source_mode ~= "render" then manifest = write_timeline_audio_manifest(timeline, fps, manifest_path) end

    local clip = manifest and manifest.first
    if manifest and manifest.complete and manifest.clip_count == 1 and clip.timeline_start == 0 and
        math.abs(clip.duration - manifest.duration) < 1e-6 then
        return {
            kind = "audio", mode = "direct", path = clip.path,
            input_offset = clip.source_offset, input_duration = clip.duration,
        }
    end
    if manifest and manifest.complete and manifest.clip_count > 0 then
        return {
            kind = "manifest",
            mode = "cut_timeline",
            path = manifest.path,
            input_offset = 0,
            input_duration = nil,
            clip_count = manifest.clip_count,
        }
    end

    log(manifest and "Cut-timeline source map incomplete; using Resolve audio export" or "Using Resolve audio export from settings")
    local rendered = render_timeline_audio(project, timeline, run_dir)
    return {
        kind = "audio",
        mode = "render",
        path = rendered,
        input_offset = 0,
        input_duration = nil,
    }
end

local function command_ok(ret1, ret2, ret3)
    if ret1 == true then return true end
    if type(ret1) == "number" and ret1 == 0 then return true end
    if ret2 == "exit" and tonumber(ret3) == 0 then return true end
    return false
end

local function run_logged(args)
    if windows then
        local ok, err = windows.run(windows_args(args), LOG_PATH, LOG_PATH, true)
        if err then log(err) end
        return ok
    end
    return command_ok(os.execute(shell_command(args) .. " >>" .. shell_quote(LOG_PATH) .. " 2>&1"))
end

local function run_backend(source, state, cfg, out_json, out_tsv, analysis_id)
    if not file_exists(VENV_PYTHON) then fail("Python environment not found. Re-run the ClipTimbre installer") end
    if not file_exists(BACKEND_PATH) then fail("Voice backend not found. Re-run the ClipTimbre installer") end

    local args = { VENV_PYTHON, BACKEND_PATH }
    if source.kind == "manifest" then
        table.insert(args, "--manifest")
    else
        table.insert(args, "--audio")
    end
    table.insert(args, source.path)
    table.insert(args, "--input-offset")
    table.insert(args, tostring(source.input_offset or 0))
    if source.input_duration and tonumber(source.input_duration) and tonumber(source.input_duration) > 0 then
        table.insert(args, "--input-duration")
        table.insert(args, tostring(source.input_duration))
    end
    if source.mode == "render" then table.insert(args, "--rendered") end
    local rest = {
        "--data-dir", APP_DIR,
        "--reference-start", tostring(state.reference_seconds),
        "--reference-duration", tostring(state.reference_duration_seconds),
        "--threshold", tostring(cfg.threshold),
        "--window", tostring(cfg.window_seconds),
        "--hop", tostring(cfg.hop_seconds),
        "--min-speech", tostring(cfg.min_speech_seconds),
        "--merge-gap", tostring(cfg.merge_gap_seconds),
        "--pause-merge-gap", tostring(cfg.pause_merge_gap_seconds),
        "--pause-speech-tolerance", tostring(cfg.pause_speech_tolerance_seconds),
        "--long-silence-merge-gap", tostring(cfg.long_silence_merge_gap_seconds),
        "--long-silence-speech-tolerance", tostring(cfg.long_silence_speech_tolerance_seconds),
        "--pad-before", tostring(cfg.marker_pad_before_seconds),
        "--pad-after", tostring(cfg.marker_pad_after_seconds),
        "--vad-pad-ms", tostring(math.floor(cfg.vad_pad_ms)),
        "--vad-min-silence-ms", tostring(math.floor(cfg.vad_min_silence_ms)),
        "--boundary-vad-snap", tostring(cfg.boundary_vad_snap_seconds),
        "--boundary-search", tostring(cfg.boundary_search_seconds),
        "--boundary-step", tostring(cfg.boundary_step_seconds),
        "--boundary-window", tostring(cfg.boundary_window_seconds),
        "--boundary-threshold-relax", tostring(cfg.boundary_threshold_relax),
        "--boundary-min-contrast", tostring(cfg.boundary_min_contrast),
        "--cache-dir", APP_DIR .. "/cache",
        "--batch-size", tostring(math.floor(cfg.batch_size)),
        "--device", tostring(cfg.device),
        "--model", tostring(cfg.speaker_model),
        "--analysis-id", analysis_id,
        "--output", out_json,
        "--output-tsv", out_tsv,
    }
    for _, a in ipairs(rest) do table.insert(args, a) end
    table.insert(args, cfg.refine_boundaries and "--refine-boundaries" or "--no-refine-boundaries")
    table.insert(args, cfg.cache_enabled and "--cache" or "--no-cache")

    notify(source.kind == "manifest" and "Finding voice across cut timeline…" or "Finding voice…")
    log("Running backend source_mode=" .. tostring(source.mode or source.kind))
    if not run_logged(args) then
        fail("Voice analyzer failed. See " .. LOG_PATH)
    end
end


local function parse_tsv(path)
    local f = io.open(path, "r")
    if not f then fail("Analyzer produced no result TSV: " .. path) end
    local out = {}
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" and line ~= "" then
            local a,b,c,d,e = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
            if a then
                table.insert(out, {start=tonumber(a), finish=tonumber(b), score=tonumber(c), mean_score=tonumber(d), windows=tonumber(e)})
            end
        end
    end
    f:close()
    return out
end

local function add_result_markers(timeline, fps, segments, cfg)
    delete_markers(timeline, "matches")
    local threshold = tonumber(cfg.threshold)
    local high = threshold + tonumber(cfg.high_confidence_margin)
    local count = 0
    local limit = timeline_span(timeline)
    local occupied = timeline:GetMarkers() or {}
    for i, seg in ipairs(segments) do
        local start_frame = math.max(0, math.floor(seg.start * fps + 0.5))
        local end_frame = math.min(limit, math.max(start_frame + 1, math.floor(seg.finish * fps + 0.5)))
        -- Resolve allows one marker per frame. Keep a reference or a user's
        -- marker in place and use the next frame inside the detected region.
        while start_frame < end_frame and (occupied[start_frame] or occupied[tostring(start_frame)]) do
            start_frame = start_frame + 1
        end
        local duration = end_frame - start_frame
        local color = seg.score >= high and "Green" or "Yellow"
        local name = string.format("%s STREAMER %.2f", MARKER_PREFIX, seg.score)
        local note = string.format("Known-speaker match #%d\ncosine similarity: %.8f\nmean similarity: %.4f\nwindows: %d", i, seg.score, seg.mean_score or seg.score, seg.windows or 1)
        if duration > 0 and timeline:AddMarker(start_frame, color, name, note, duration, MARKER_CUSTOM) then
            occupied[start_frame] = true
            count = count + 1
        end
    end
    return count
end

function M.find_streamer()
    local _, project, timeline = get_context()
    local cfg = load_config()
    local state = load_state_optional()
    local fps = get_fps(timeline)
    local profile_refs = active_profile_reference_count()

    if state and (state.timeline_id ~= timeline_id(timeline) or
        math.abs((tonumber(state.fps) or 0) - fps) > 0.01) then
        state = nil
    end
    if not state and profile_refs == 0 then
        fail("Set a temporary reference on this timeline or add a voice sample to the active profile")
    end

    local backend_state = state or {reference_seconds=-1, reference_duration_seconds=1}
    local layout = timeline_layout(timeline, {"audio"})
    mkdir_p(APP_DIR .. "/tmp")
    local run_dir = APP_DIR .. "/tmp/run_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000,9999))
    mkdir_p(run_dir)
    local ok, err = pcall(function()
        local source = prepare_timeline_audio_source(project, timeline, fps, run_dir, cfg)
        local analysis_id = run_dir:match("[^/\\]+$")
        local out_json = run_dir .. "/result.json"
        local out_tsv = run_dir .. "/result.tsv"
        run_backend(source, backend_state, cfg, out_json, out_tsv, analysis_id)
        if layout ~= timeline_layout(timeline, {"audio"}) then fail("Timeline audio changed during Find") end
        local segments = parse_tsv(out_tsv)

        delete_markers(timeline, "pauses")
        os.remove(LATEST_PAUSES_PATH)
        os.remove(LATEST_PAUSES_JSON_PATH)
        os.remove(PAUSE_STATE_PATH)
        os.remove(ANALYSIS_STATE_PATH)
        local count = add_result_markers(timeline, fps, segments, cfg)
        copy_file(out_json, LATEST_RESULT_PATH)
        if source.kind == "manifest" then
            copy_file(source.path, LATEST_MANIFEST_PATH)
        else
            os.remove(LATEST_MANIFEST_PATH)
        end
        local span = nil
        pcall(function() span = tonumber(timeline:GetEndFrame()) - tonumber(timeline:GetStartFrame()) end)
        write_all(ANALYSIS_STATE_PATH, table.concat({
            "timeline_id=" .. timeline_id(timeline),
            "fps=" .. tostring(fps),
            "timeline_span_frames=" .. tostring(span or -1),
            "analysis_id=" .. analysis_id,
            "layout=" .. layout,
            "vad_pad_ms=" .. tostring(math.floor(cfg.vad_pad_ms)),
            "vad_min_silence_ms=" .. tostring(math.floor(cfg.vad_min_silence_ms)),
            "source_kind=" .. tostring(source.kind or "audio"),
            "source_mode=" .. tostring(source.mode or "unknown"),
            "input_offset=" .. tostring(source.input_offset or 0),
            "input_duration=" .. tostring(source.input_duration or 0),
        }, "\n") .. "\n")
        notify(string.format("Streamer regions marked: %d of %d (%s)", count, #segments, tostring(source.mode or source.kind)))
    end)
    remove_tree(run_dir)
    if not ok then error(err) end
end


function M.clear_markers()
    local _, _, timeline = get_context()
    local count = delete_markers(timeline, "matches")
    notify("Removed " .. tostring(count) .. " ClipTimbre markers")
end

function M.next_streamer()
    local _, _, timeline = get_context()
    local fps = get_fps(timeline)
    local current = current_relative_frame(timeline, fps)
    local markers = timeline:GetMarkers() or {}
    local ours = {}
    for frame, data in pairs(markers) do
        local name = marker_field(data, "name")
        local custom = marker_field(data, "customData")
        if custom == MARKER_CUSTOM or name:sub(1, #MARKER_PREFIX + 9) == MARKER_PREFIX .. " STREAMER" then
            table.insert(ours, math.floor(tonumber(frame) + 0.5))
        end
    end
    if #ours == 0 then fail("No ClipTimbre markers on current timeline") end
    table.sort(ours)
    local target = ours[1]
    for _, frame in ipairs(ours) do
        if frame > current then target = frame; break end
    end
    local tc = relative_frame_to_timecode(timeline, target, fps)
    if not timeline:SetCurrentTimecode(tc) then fail("Could not move playhead to " .. tc) end
    notify("Next streamer region: " .. tc)
end

function M.previous_streamer()
    local _, _, timeline = get_context()
    local fps = get_fps(timeline)
    local current = current_relative_frame(timeline, fps)
    local markers = timeline:GetMarkers() or {}
    local ours = {}
    for frame, data in pairs(markers) do
        local name = marker_field(data, "name")
        local custom = marker_field(data, "customData")
        if custom == MARKER_CUSTOM or name:sub(1, #MARKER_PREFIX + 9) == MARKER_PREFIX .. " STREAMER" then
            table.insert(ours, math.floor(tonumber(frame) + 0.5))
        end
    end
    if #ours == 0 then fail("No ClipTimbre markers on current timeline") end
    table.sort(ours)
    local target = ours[#ours]
    for i = #ours, 1, -1 do
        if ours[i] < current then target = ours[i]; break end
    end
    local tc = relative_frame_to_timecode(timeline, target, fps)
    if not timeline:SetCurrentTimecode(tc) then fail("Could not move playhead to " .. tc) end
    notify("Previous streamer region: " .. tc)
end


local function run_pause_backend(source, cfg, out_tsv, out_json, analysis_id, plan_id)
    if not file_exists(VENV_PYTHON) then fail("Python environment not found. Re-run the ClipTimbre installer") end
    if not file_exists(PAUSE_BACKEND_PATH) then fail("Pause backend not found. Re-run the ClipTimbre installer") end
    if not file_exists(LATEST_RESULT_PATH) then fail("No streamer analysis found. Run 'Find ClipTimbre' first.") end

    local args = { VENV_PYTHON, PAUSE_BACKEND_PATH }
    if source then
        table.insert(args, source.kind == "manifest" and "--manifest" or "--audio")
        table.insert(args, source.path)
        table.insert(args, "--input-offset")
        table.insert(args, tostring(source.input_offset or 0))
        if source.input_duration then
            table.insert(args, "--input-duration")
            table.insert(args, tostring(source.input_duration))
        end
        if source.mode == "render" then table.insert(args, "--rendered") end
    else
        table.insert(args, "--cached-render")
    end
    if analysis_id then
        table.insert(args, "--analysis-id")
        table.insert(args, analysis_id)
    end
    local rest = {
        "--result", LATEST_RESULT_PATH,
        "--plan-id", plan_id,
        "--min-pause", tostring(cfg.pause_trim_min_seconds),
        "--target-pause", tostring(cfg.pause_trim_target_seconds),
        "--max-auto-pause", tostring(cfg.pause_trim_max_auto_seconds),
        "--review-max-pause", tostring(cfg.pause_trim_review_max_seconds),
        "--edge-protect", tostring(cfg.pause_trim_edge_protect_seconds),
        "--min-delete", tostring(cfg.pause_trim_min_delete_seconds),
        "--vad-pad-ms", tostring(math.floor(cfg.vad_pad_ms)),
        "--vad-min-silence-ms", tostring(math.floor(cfg.vad_min_silence_ms)),
        "--output", out_tsv,
        "--output-json", out_json,
    }
    for _, a in ipairs(rest) do table.insert(args, a) end
    notify("Finding pauses inside streamer regions…")
    log("Running pause backend source_mode=" .. (source and tostring(source.mode or source.kind) or "cached_render"))
    if not run_logged(args) then
        fail("Pause analyzer failed. See " .. LOG_PATH)
    end
end


local function parse_pause_tsv(path, plan_id)
    local f = io.open(path, "r")
    if not f then fail("No pause TSV: " .. path) end
    local out = {}
    local first = f:read("*l") or ""
    if plan_id and first:gsub("\r$", "") ~= "# plan " .. plan_id then
        f:close()
        fail("Pause plan changed. Run Mark Streamer Pauses again")
    end
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" and line ~= "" then
            local fields = {}
            for field in (line .. "\t"):gmatch("(.-)\t") do table.insert(fields, field) end
            if #fields >= 9 then
                table.insert(out, {
                    start = tonumber(fields[1]),
                    finish = tonumber(fields[2]),
                    duration = tonumber(fields[3]),
                    target = tonumber(fields[4]),
                    delete_start = tonumber(fields[5]),
                    delete_end = tonumber(fields[6]),
                    delete_duration = tonumber(fields[7]),
                    action = tostring(fields[8]),
                    streamer_segment = tonumber(fields[9]),
                    reason = tostring(fields[10] or ""),
                })
            end
        end
    end
    f:close()
    return out
end

local function write_pause_state(timeline, fps, pauses, layout, plan_id)
    local span = nil
    pcall(function() span = tonumber(timeline:GetEndFrame()) - tonumber(timeline:GetStartFrame()) end)
    local auto_count, review_count, total_delete = 0, 0, 0
    for _, p in ipairs(pauses) do
        if p.action == "auto" then
            auto_count = auto_count + 1
            total_delete = total_delete + (tonumber(p.delete_duration) or 0)
        else
            review_count = review_count + 1
        end
    end
    write_all(PAUSE_STATE_PATH, table.concat({
        "timeline_id=" .. timeline_id(timeline),
        "fps=" .. tostring(fps),
        "timeline_span_frames=" .. tostring(span or -1),
        "layout=" .. layout,
        "plan_id=" .. plan_id,
        "auto_count=" .. tostring(auto_count),
        "review_count=" .. tostring(review_count),
        "total_delete_seconds=" .. tostring(total_delete),
    }, "\n") .. "\n")
    return auto_count, review_count, total_delete
end

local function read_kv_file(path)
    local txt = read_all(path)
    if not txt then return nil end
    local out = {}
    for line in txt:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then out[k] = v end
    end
    return out
end

local pause_review_reason = {
    long = "Long pause",
    near_boundary = "Near a voice-region boundary",
    unconfirmed_voice = "Voice could not be confirmed on both sides",
}

local function add_pause_markers(timeline, fps, pauses, plan_id)
    delete_markers(timeline, "pauses")
    local count = 0
    for i, p in ipairs(pauses) do
        local start_frame = math.max(0, math.floor((p.start or 0) * fps + 0.5))
        local end_frame = math.max(start_frame + 1, math.floor((p.finish or 0) * fps + 0.5))
        local duration_frames = end_frame - start_frame
        local is_auto = p.action == "auto"
        local color = is_auto and "Purple" or "Red"
        local custom = is_auto and PAUSE_CUSTOM or PAUSE_REVIEW_CUSTOM
        local name = nil
        if is_auto then
            name = string.format("%s PAUSE %.2fs -> %.2fs", MARKER_PREFIX, p.duration or 0, p.target or 0)
        else
            name = string.format("%s PAUSE %.2fs CHECK", MARKER_PREFIX, p.duration or 0)
        end
        local note = string.format(
            "Speech pause #%d\nmode: %s\noriginal: %.3fs\ntarget: %.3fs\nproposed cut: %.3fs\nreview: %s\nplan: %s",
            i, tostring(p.action), p.duration or 0, p.target or 0, p.delete_duration or 0,
            pause_review_reason[p.reason] or "—", plan_id
        )
        if timeline:AddMarker(start_frame, color, name, note, duration_frames, custom) then count = count + 1 end
    end
    return count
end

function M.mark_streamer_pauses()
    local _, project, timeline = get_context()
    local cfg = load_config()
    local fps = get_fps(timeline)
    if not file_exists(LATEST_RESULT_PATH) then
        fail("No latest streamer result. Run 'Find ClipTimbre' first.")
    end
    local analysis_state = read_kv_file(ANALYSIS_STATE_PATH)
    if not analysis_state then fail("Analysis state missing. Run 'Find ClipTimbre' again.") end
    if tostring(analysis_state.timeline_id) ~= timeline_id(timeline) then fail("Latest Find belongs to another timeline.") end
    local analyzed_span = tonumber(analysis_state.timeline_span_frames)
    local current_fps = tonumber(analysis_state.fps) or fps
    if math.abs(current_fps - fps) > 0.01 or
        (analyzed_span and analyzed_span >= 0 and math.abs(timeline_span(timeline) - analyzed_span) > 1) or
        (analysis_state.layout and analysis_state.layout ~= timeline_layout(timeline, {"audio"})) then
        fail("Timeline audio changed after Find. Run Find voice again")
    end

    local layout = timeline_layout(timeline, {"audio", "video", "subtitle"})
    mkdir_p(APP_DIR .. "/tmp")
    local run_dir = APP_DIR .. "/tmp/pause_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000,9999))
    mkdir_p(run_dir)
    local ok, err = pcall(function()
        local plan_id = run_dir:match("[^/\\]+$")
        local can_reuse_render = analysis_state.analysis_id and analysis_state.source_mode == "render" and
            tonumber(analysis_state.vad_pad_ms) == math.floor(cfg.vad_pad_ms) and
            tonumber(analysis_state.vad_min_silence_ms) == math.floor(cfg.vad_min_silence_ms)
        local source = nil
        if not can_reuse_render then source = prepare_timeline_audio_source(project, timeline, fps, run_dir, cfg) end
        local out_tsv = run_dir .. "/pauses.tsv"
        local out_json = run_dir .. "/pauses.json"
        run_pause_backend(source, cfg, out_tsv, out_json, analysis_state.analysis_id, plan_id)
        if layout ~= timeline_layout(timeline, {"audio", "video", "subtitle"}) then
            fail("Timeline changed during pause analysis")
        end
        local pauses = parse_pause_tsv(out_tsv, plan_id)
        copy_file(out_tsv, LATEST_PAUSES_PATH)
        copy_file(out_json, LATEST_PAUSES_JSON_PATH)
        local marked = add_pause_markers(timeline, fps, pauses, plan_id)
        local auto_count, review_count, total_delete = write_pause_state(timeline, fps, pauses, layout, plan_id)
        notify(string.format(
            "Pauses marked: %d auto, %d review. Tighten can remove %.1fs.",
            auto_count, review_count, total_delete
        ))
        log(string.format("Pause markers added: %d total", marked))
    end)
    remove_tree(run_dir)
    if not ok then error(err) end
end


function M.clear_pause_markers()
    local _, _, timeline = get_context()
    local count = delete_markers(timeline, "pauses")
    notify("Removed " .. tostring(count) .. " ClipTimbre pause markers")
end

local function write_video_pause_manifest(timeline, fps, track, path)
    if optional_call(function() return timeline:GetIsTrackEnabled("video", track) end) == false then
        fail("Enable the selected video track before scanning")
    end
    local offset = timeline:GetStartFrame()
    local clips, skipped = {}, 0
    for _, item in ipairs(timeline:GetItemListInTrack("video", track) or {}) do
        if optional_call(function() return item:GetClipEnabled() end) ~= false then
            local media = optional_call(function() return item:GetMediaPoolItem() end)
            local file = media and optional_call(function() return media:GetClipProperty("File Path") end)
            if type(file) == "table" then file = file["File Path"] end
            local raw_fps = media and optional_call(function() return media:GetClipProperty("FPS") end)
            if type(raw_fps) == "table" then raw_fps = raw_fps.FPS end
            local source_fps = normalized_fps(raw_fps)
            local first = safe_number_call(function() return item:GetSourceStartFrame() end)
            local last = safe_number_call(function() return item:GetSourceEndFrame() end)
            local left = safe_number_call(function() return item:GetLeftOffset(true) end) or
                safe_number_call(function() return item:GetLeftOffset() end)
            local duration = item:GetDuration() / fps
            local speed = optional_call(function() return item:GetProperty("Speed") end)
            if type(speed) == "table" then speed = speed.Speed or speed.speed end
            speed = tonumber(speed)
            local retimed = speed and math.abs(speed - 100) > 0.01 and math.abs(speed - 1) > 0.001
            local aligned = source_fps and first and last and left and
                first >= 0 and math.abs((last - first) / source_fps - duration) <= 2 / math.min(source_fps, fps) and
                math.abs(first / source_fps - left / fps) <= 2 / math.min(source_fps, fps)
            if not retimed and aligned and type(file) == "string" and file_exists(file) and duration > 1.8 then
                clips[#clips + 1] = string.format(
                    '{"path":"%s","timeline_start":%.9f,"source_offset":%.9f,"duration":%.9f}',
                    json_escape(file), (item:GetStart() - offset) / fps, first / source_fps, duration
                )
            else
                skipped = skipped + 1
            end
        end
    end
    if #clips == 0 then fail("No supported video clips to scan on V" .. track) end
    write_all(path, '{"clips":[' .. table.concat(clips, ",") .. "]}\n")
    return #clips, skipped
end

local function write_video_pause_markers(timeline, fps, output)
    delete_markers(timeline, "video_holds")
    local occupied = {}
    for frame in pairs(timeline:GetMarkers() or {}) do occupied[tonumber(frame)] = true end
    local count, collisions = 0, 0
    local limit = timeline:GetEndFrame() - timeline:GetStartFrame()
    for line in output:gmatch("[^\r\n]+") do
        local start, finish = line:match("^([%d%.]+)\t([%d%.]+)$")
        if start then
            local a = math.floor(tonumber(start) * fps + 0.5)
            local b = math.floor(tonumber(finish) * fps + 0.5)
            if a >= 0 and b > a and b < limit then
                if occupied[a] or occupied[b] then
                    collisions = collisions + 1
                elseif timeline:AddMarker(a, "Mint", "[CT] Possible video pause", "Review the still image and surrounding playback.", b - a, VIDEO_HOLD_CUSTOM) then
                    if timeline:AddMarker(b, "Mint", "[CT] Possible video resume", "Motion returned in the scanned area.", 1, VIDEO_HOLD_CUSTOM) then
                        occupied[a], occupied[b] = true, true
                        count = count + 1
                    else
                        timeline:DeleteMarkerAtFrame(a)
                    end
                end
            end
        end
    end
    return count, collisions
end

function M.mark_video_pauses(track, crop)
    local _, _, timeline = get_context()
    local fps = get_fps(timeline)
    track = tonumber(track) or 1
    if track % 1 ~= 0 or track < 1 or track > timeline:GetTrackCount("video") then
        fail("Select an existing video track")
    end
    crop = tostring(crop or "0,0,100,100"):gsub("%s+", "")
    local x, y, width, height = crop:match("^(%d+),(%d+),(%d+),(%d+)$")
    if not height or tonumber(width) < 10 or tonumber(height) < 10 or
        tonumber(x) + tonumber(width) > 100 or tonumber(y) + tonumber(height) > 100 then
        fail("Use x,y,width,height percentages for a crop inside the frame")
    end
    if not file_exists(VIDEO_PAUSE_BACKEND_PATH) or not file_exists(VENV_PYTHON) then
        fail("Video scan backend missing. Re-run the ClipTimbre installer")
    end
    local layout = timeline_layout(timeline, {"video"})
    mkdir_p(APP_DIR .. "/tmp")
    local run_dir = APP_DIR .. "/tmp/video_hold_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    mkdir_p(run_dir)
    local ok, err = pcall(function()
        local manifest = run_dir .. "/video.json"
        local out = run_dir .. "/holds.tsv"
        local mapped, skipped = write_video_pause_manifest(timeline, fps, track, manifest)
        local args = {VENV_PYTHON, VIDEO_PAUSE_BACKEND_PATH, "--manifest", manifest, "--crop", crop, "--output", out}
        if not run_logged(args) then fail("Video scan failed. See " .. LOG_PATH) end
        if layout ~= timeline_layout(timeline, {"video"}) then fail("The video timeline changed during the scan") end
        local output = read_all(out) or ""
        local scanned = tonumber(output:match("^# scanned\t(%d+)"))
        if not scanned then fail("Video scan returned no report") end
        local count, collisions = write_video_pause_markers(timeline, fps, output)
        notify(string.format("Video holds: %d pairs marked. %d clips skipped, %d marker collisions.",
            count, skipped + mapped - scanned, collisions))
    end)
    remove_tree(run_dir)
    if not ok then error(err) end
end

function M.clear_video_pauses()
    local _, _, timeline = get_context()
    local count = delete_markers(timeline, "video_holds")
    notify("Removed " .. tostring(count) .. " video hold markers")
end

local function pause_marker_frames(timeline)
    local frames = {}
    local markers = timeline:GetMarkers() or {}
    for frame, data in pairs(markers) do
        local name = marker_field(data, "name")
        local custom = marker_field(data, "customData")
        if custom == PAUSE_CUSTOM or custom == PAUSE_REVIEW_CUSTOM or name:find(MARKER_PREFIX .. " PAUSE", 1, true) == 1 or name:find(MARKER_PREFIX .. " LONG PAUSE", 1, true) == 1 then
            table.insert(frames, math.floor(tonumber(frame) + 0.5))
        end
    end
    table.sort(frames)
    return frames
end

function M.next_pause()
    local _, _, timeline = get_context()
    local fps = get_fps(timeline)
    local current = current_relative_frame(timeline, fps)
    local frames = pause_marker_frames(timeline)
    if #frames == 0 then fail("No ClipTimbre pause markers on current timeline") end
    local target = frames[1]
    for _, frame in ipairs(frames) do if frame > current then target = frame; break end end
    local tc = relative_frame_to_timecode(timeline, target, fps)
    if not timeline:SetCurrentTimecode(tc) then fail("Could not move playhead to " .. tc) end
    notify("Next streamer pause: " .. tc)
end

function M.previous_pause()
    local _, _, timeline = get_context()
    local fps = get_fps(timeline)
    local current = current_relative_frame(timeline, fps)
    local frames = pause_marker_frames(timeline)
    if #frames == 0 then fail("No ClipTimbre pause markers on current timeline") end
    local target = frames[#frames]
    for i = #frames, 1, -1 do if frames[i] < current - 1 then target = frames[i]; break end end
    local tc = relative_frame_to_timecode(timeline, target, fps)
    if not timeline:SetCurrentTimecode(tc) then fail("Could not move playhead to " .. tc) end
    notify("Previous streamer pause: " .. tc)
end

local function run_ad_safety_backend(source, cfg, out_tsv, out_json)
    if not file_exists(VENV_PYTHON) then fail("Python environment not found. Re-run the ClipTimbre installer") end
    if not file_exists(AD_SAFETY_BACKEND_PATH) then fail("YouTube ad-safety backend missing. Re-run the ClipTimbre installer") end
    if not file_exists(AD_SAFETY_TERMS_PATH) then fail("YouTube ad-safety terms missing. Re-run the ClipTimbre installer") end

    local args = { VENV_PYTHON, AD_SAFETY_BACKEND_PATH }
    if source.kind == "manifest" then table.insert(args, "--manifest") else table.insert(args, "--audio") end
    table.insert(args, source.path)
    table.insert(args, "--input-offset")
    table.insert(args, tostring(source.input_offset or 0))
    if source.input_duration and tonumber(source.input_duration) and tonumber(source.input_duration) > 0 then
        table.insert(args, "--input-duration")
        table.insert(args, tostring(source.input_duration))
    end
    local rest = {
        "--model", tostring(cfg.ad_safety_model or "small"),
        "--language", tostring(cfg.ad_safety_language or "auto"),
        "--engine", tostring(cfg.ad_safety_engine or "auto"),
        "--device", tostring(cfg.ad_safety_device or "auto"),
        "--chunk-seconds", tostring(cfg.ad_safety_chunk_seconds or 600.0),
        "--stall-timeout-seconds", tostring(cfg.ad_safety_stall_timeout_seconds or 900.0),
        "--model-load-timeout-seconds", tostring(cfg.ad_safety_model_load_timeout_seconds or 1800.0),
        "--terms", AD_SAFETY_TERMS_PATH,
        "--output", out_tsv,
        "--output-json", out_json,
    }
    for _, a in ipairs(rest) do table.insert(args, a) end
    notify("Transcribing and scanning YouTube ad-safety risks…")
    log("Running YouTube ad-safety backend source_mode=" .. tostring(source.mode or source.kind))
    if not run_logged(args) then
        fail("YouTube ad-safety scan failed. See " .. LOG_PATH)
    end
end

local function parse_ad_safety_tsv(path)
    local f = io.open(path, "r")
    if not f then fail("No YouTube ad-safety TSV: " .. path) end
    local out = {}
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" and line ~= "" then
            local fields = {}
            for field in (line .. "\t"):gmatch("(.-)\t") do table.insert(fields, field) end
            if #fields >= 8 then
                table.insert(out, {
                    start = tonumber(fields[1]) or 0,
                    finish = tonumber(fields[2]) or tonumber(fields[1]) or 0,
                    severity = tostring(fields[3]),
                    category = tostring(fields[4]),
                    label = tostring(fields[5]),
                    phrase = tostring(fields[6]),
                    context = tostring(fields[7]),
                    confidence = tonumber(fields[8]) or 0,
                    auto_censor = not tostring(fields[9] or ""):match("^%s*0%s*$"),
                })
            end
        end
    end
    f:close()
    return out
end

local function current_project_timeline()
    local manager = get_resolve():GetProjectManager()
    local project = manager and manager:GetCurrentProject()
    return project, project and project:GetCurrentTimeline()
end

local function ui_context_key(project, timeline)
    if not project then return "" end
    local project_key = unique_id(project) or tostring(project:GetName())
    if not timeline then return project_key end
    return table.concat({
        project_key, tostring(project:GetName()), timeline_id(timeline), tostring(timeline:GetName()),
        tostring(timeline:GetStartFrame()), tostring(timeline:GetEndFrame()), tostring(get_fps(timeline)),
    }, "\0")
end

function M.get_ui_context_key()
    return ui_context_key(current_project_timeline())
end

local function write_youtube_state(project, timeline, fps, events)
    local span = nil
    pcall(function() span = tonumber(timeline:GetEndFrame()) - tonumber(timeline:GetStartFrame()) end)
    local high_count, review_count = 0, 0
    for _, e in ipairs(events or {}) do
        if tostring(e.severity) == "high" then high_count = high_count + 1 else review_count = review_count + 1 end
    end
    write_all(YOUTUBE_STATE_PATH, table.concat({
        "project_id=" .. (unique_id(project) or ""),
        "timeline_id=" .. (unique_id(timeline) or ""),
        "fps=" .. tostring(fps),
        "timeline_span_frames=" .. tostring(span or -1),
        "event_count=" .. tostring(#(events or {})),
        "high_count=" .. tostring(high_count),
        "review_count=" .. tostring(review_count),
        "scanned_at=" .. tostring(os.time()),
    }, "\n") .. "\n")
end

local function youtube_state_problem(project, timeline, fps)
    local state = read_kv_file(YOUTUBE_STATE_PATH)
    if not state then return "YouTube scan state is missing" end
    local id = unique_id(timeline)
    if not id or state.timeline_id ~= id then
        return "latest YouTube scan belongs to another timeline"
    end
    if state.project_id and state.project_id ~= "" and state.project_id ~= unique_id(project) then
        return "latest YouTube scan belongs to another project"
    end
    if math.abs((tonumber(state.fps) or fps) - fps) > 0.01 then
        return "timeline FPS changed after YouTube scan"
    end
    local span = nil
    pcall(function() span = tonumber(timeline:GetEndFrame()) - tonumber(timeline:GetStartFrame()) end)
    local old_span = tonumber(state.timeline_span_frames)
    if span and old_span and old_span >= 0 and math.abs(span - old_span) > 1 then
        return "timeline duration changed after YouTube scan"
    end
    if not file_exists(LATEST_AD_SAFETY_JSON_PATH) or not file_exists(LATEST_AD_SAFETY_PATH) then
        return "latest YouTube report is missing"
    end
    return nil, state
end

local function validate_youtube_state(project, timeline, fps)
    local problem, state = youtube_state_problem(project, timeline, fps)
    if problem then fail(problem .. ". Run Scan Ad-Safety Risks again.") end
    return state
end

local function free_youtube_marker_frame(marker, occupied, limit)
    local frame = marker.start_frame + 1
    while frame < marker.end_frame and occupied[frame] do frame = frame + 1 end
    if frame < marker.end_frame then return frame end

    -- If the entire interval is occupied, move the marker to the nearest free frame.
    local left, right = marker.start_frame - 1, marker.end_frame
    while left >= 0 and occupied[left] do left = left - 1 end
    while right < limit and occupied[right] do right = right + 1 end
    if left >= 0 and (right >= limit or marker.start_frame - left <= right - marker.start_frame) then
        return left
    end
    if right < limit then return right end
end

local function add_ad_safety_markers(timeline, fps, events, cfg)
    local limit = math.floor(timeline_span(timeline))
    if limit <= 0 then return 0, 0, 0 end
    local pad = math.max(0, tonumber(cfg.ad_safety_marker_pad_seconds) or 0.15)
    local markers, by_note = {}, {}
    for i, e in ipairs(events) do
        local start_frame = math.min(limit - 1, math.floor(math.max(0, e.start - pad) * fps + 0.5))
        local end_frame = math.min(limit, math.max(start_frame + 1, math.floor((e.finish + pad) * fps + 0.5)))
        local is_high = e.severity == "high"
        local is_personal = e.category == "directed_insult"
        local color = is_personal and YT_PERSONAL_COLOR or (is_high and YT_HIGH_COLOR or YT_REVIEW_COLOR)
        local custom = is_high and YT_HIGH_CUSTOM or YT_REVIEW_CUSTOM
        local prefix = is_personal and (is_high and "[YT] PERSONAL HIGH" or "[YT] PERSONAL REVIEW")
            or (is_high and "[YT] HIGH" or "[YT] REVIEW")
        local category = tostring(e.category or "risk")
        local name = string.format("%s %s", prefix, category)
        local note = string.format(
            "YouTube audio flag #%d\nseverity: %s\ncategory: %s\nlabel: %s\nmatch: %s\nconfidence: %.3f\ncontext: %s\n%s",
            i, tostring(e.severity), category, tostring(e.label or ""), tostring(e.phrase or ""),
            tonumber(e.confidence) or 0, tostring(e.context or ""),
            (e.auto_censor == false or category == "frequent_profanity") and "Manual review only" or "Eligible for Auto Censor"
        )
        local marker = {
            start_frame = start_frame, end_frame = end_frame, high = is_high,
            color = color, name = name, note = note, custom = custom,
        }
        markers[i] = marker
        by_note[note] = marker
    end

    local occupied = {}
    for frame, data in pairs(timeline:GetMarkers() or {}) do
        local custom = marker_field(data, "customData")
        local name, note = marker_field(data, "name"), marker_field(data, "note")
        local owned = custom == YT_HIGH_CUSTOM or custom == YT_REVIEW_CUSTOM
            or (custom == "" and name:sub(1, 4) == "[YT]" and note:match("^YouTube audio flag #%d+\n"))
        local keep = true
        if owned then
            local marker = by_note[note]
            if marker and not marker.placed and marker.name == name and marker.custom == custom
                and marker.color == marker_field(data, "color") then
                marker.placed = true
            else
                keep = not timeline:DeleteMarkerAtFrame(tonumber(frame))
            end
        end
        if keep then occupied[tonumber(frame)] = true end
    end

    local function place(marker, frame)
        local duration = frame >= marker.start_frame and frame < marker.end_frame and marker.end_frame - frame or 1
        if timeline:AddMarker(frame, marker.color, marker.name, marker.note, duration, marker.custom) then
            occupied[frame] = true
            marker.placed = true
        end
    end

    -- Give findings at distinct frames their original positions before displacing collisions.
    for _, marker in ipairs(markers) do
        if not marker.placed and not occupied[marker.start_frame] then place(marker, marker.start_frame) end
    end
    local high_count, review_count = 0, 0
    for _, marker in ipairs(markers) do
        if not marker.placed and occupied[marker.start_frame] then
            local frame = free_youtube_marker_frame(marker, occupied, limit)
            if frame then place(marker, frame) end
        end
        if marker.placed then
            if marker.high then high_count = high_count + 1 else review_count = review_count + 1 end
        end
    end
    local added = high_count + review_count
    return added, high_count, review_count
end

function M.rebuild_youtube_markers()
    local _, project, timeline = get_context()
    local fps = get_fps(timeline)
    validate_youtube_state(project, timeline, fps)
    local events = parse_ad_safety_tsv(LATEST_AD_SAFETY_PATH)
    local placed = add_ad_safety_markers(timeline, fps, events, load_config())
    notify(string.format("YouTube markers: %d/%d placed from the saved scan.", placed, #events))
    return placed, #events
end

function M.scan_youtube_safety()
    local _, project, timeline = get_context()
    local cfg = load_config()
    local fps = get_fps(timeline)
    mkdir_p(APP_DIR .. "/tmp")
    local run_dir = APP_DIR .. "/tmp/youtube_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000,9999))
    mkdir_p(run_dir)
    local ok, err = pcall(function()
        local source = prepare_timeline_audio_source(project, timeline, fps, run_dir, cfg)
        local out_tsv = run_dir .. "/ad_safety.tsv"
        local out_json = run_dir .. "/ad_safety.json"
        run_ad_safety_backend(source, cfg, out_tsv, out_json)
        local events = parse_ad_safety_tsv(out_tsv)
        local added, high_count, review_count = add_ad_safety_markers(timeline, fps, events, cfg)
        copy_file(out_tsv, LATEST_AD_SAFETY_PATH)
        copy_file(out_json, LATEST_AD_SAFETY_JSON_PATH)
        write_youtube_state(project, timeline, fps, events)
        notify(string.format("YouTube scan: %d markers (%d high, %d review). Audio-only check; green icon is not guaranteed.", added, high_count, review_count))
    end)
    remove_tree(run_dir)
    if not ok then error(err) end
end

local function censor_category_list(opts)
    opts = opts or {}
    local list, seen = {}, {}
    local function add(name)
        if not seen[name] then seen[name] = true; table.insert(list, name) end
    end
    if opts.profanity ~= false then add("strong_profanity"); add("moderate_profanity") end
    if opts.personal ~= false then add("directed_insult") end
    if opts.hate ~= false then add("hate_or_slur") end
    if opts.sexual_drugs == true then
        add("sexual_content"); add("sexual_violence_or_child_abuse"); add("drugs")
    end
    if opts.violence == true then
        add("graphic_violence"); add("violence"); add("self_harm"); add("weapons")
    end
    if opts.other_sensitive == true then
        add("dishonest_behavior"); add("terrorism")
    end
    return list, seen
end

local function censor_severity_list(opts)
    opts = opts or {}
    local out = {}
    if opts.include_high ~= false then table.insert(out, "high") end
    if opts.include_review ~= false then table.insert(out, "review") end
    return out
end

local function join_csv(values)
    return table.concat(values or {}, ",")
end

local function censor_event_selected(event, category_set, severity_set)
    return event.auto_censor ~= false and event.category ~= "frequent_profanity" and
        category_set[event.category] and severity_set[event.severity]
end

local function selected_censor_event_count(events, category_set, severity_set)
    local count = 0
    for _, e in ipairs(events or {}) do
        if censor_event_selected(e, category_set, severity_set) then
            count = count + 1
        end
    end
    return count
end

local function selected_censor_intervals(events, category_set, severity_set, cfg)
    local before = math.max(0, tonumber(cfg.youtube_censor_pad_before_seconds) or 0.08)
    local after = math.max(0, tonumber(cfg.youtube_censor_pad_after_seconds) or 0.12)
    local raw = {}
    for _, e in ipairs(events or {}) do
        if censor_event_selected(e, category_set, severity_set) then
            local s = math.max(0, (tonumber(e.start) or 0) - before)
            local f = math.max(s, (tonumber(e.finish) or tonumber(e.start) or 0) + after)
            table.insert(raw, {start=s, finish=f})
        end
    end
    table.sort(raw, function(a,b) return a.start < b.start end)
    local merged = {}
    for _, r in ipairs(raw) do
        local last = merged[#merged]
        if last and r.start <= last.finish + 0.001 then
            if r.finish > last.finish then last.finish = r.finish end
        else
            table.insert(merged, {start=r.start, finish=r.finish})
        end
    end
    return merged
end

local function linux_confirm(title, message)
    if not command_ok(os.execute("command -v zenity >/dev/null 2>&1")) then
        fail("Install zenity to show confirmation dialogs on Linux")
    end
    return command_ok(os.execute("zenity --question --title=" .. shell_quote(title) ..
        " --text=" .. shell_quote(message) .. " 2>/dev/null"))
end

local function ask_censor_confirmation(count, mode, categories)
    local readable_mode = mode == "mute" and "SMOOTH MUTE" or (mode == "timeline_mute" and "TIMELINE MUTE" or "BEEP")
    local action = mode == "timeline_mute"
        and "rebuild only the source audio clips around the flagged ranges, leaving visible muted gaps on the timeline"
        or "replace its audio with a processed mix"
    local extra = mode == "timeline_mute"
        and "\n\nTimeline Mute keeps the source tracks and adds short fade clips where needed. Per-clip audio effects or gain on rebuilt clips may not carry over."
        or ""
    local message = string.format(
        "Create a censored timeline copy and %s using %s? %d flagged spoken interval(s) match the selected categories. Original timeline will stay unchanged.\n\nCategories: %s%s",
        action, readable_mode, count, categories, extra
    )
    if IS_LINUX then return linux_confirm("ClipTimbre", message) end
    if IS_WINDOWS then
        local ps = "Add-Type -AssemblyName PresentationFramework\n" ..
            "$r=[System.Windows.MessageBox]::Show(" .. ps_quote(message) .. "," .. ps_quote("ClipTimbre - Auto Censor") .. ",[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning)\n" ..
            "if ($r -eq [System.Windows.MessageBoxResult]::Yes) { Write-Output 'YES' }"
        return run_powershell_capture(ps) == "YES"
    end
    local script = 'display dialog ' .. string.format('%q', message) .. ' with title "ClipTimbre — Auto Censor" buttons {"Cancel", "Create Censored Copy"} default button "Create Censored Copy" with icon caution\nreturn button returned of result'
    local p = io.popen("osascript -e " .. shell_quote(script) .. " 2>/dev/null")
    local answer = p and p:read("*l") or nil
    if p then p:close() end
    return answer == "Create Censored Copy"
end

local function run_censor_backend(source, cfg, opts, categories_csv, severities_csv, output_path, summary_path)
    if not file_exists(VENV_PYTHON) then fail("Python environment not found. Re-run the ClipTimbre installer") end
    if not file_exists(CENSOR_BACKEND_PATH) then fail("Auto Censor backend missing. Re-run the ClipTimbre installer") end
    if type(source) ~= "table" or not source.path then fail("Auto Censor audio source is invalid") end
    local source_flag = source.kind == "manifest" and "--manifest" or "--audio"
    local args = {
        VENV_PYTHON, CENSOR_BACKEND_PATH,
        source_flag, source.path,
        "--report", LATEST_AD_SAFETY_JSON_PATH,
        "--output", output_path,
        "--summary", summary_path,
        "--mode", tostring(opts.mode == "mute" and "mute" or "beep"),
        "--categories", categories_csv,
        "--severities", severities_csv,
        "--pad-before", tostring(cfg.youtube_censor_pad_before_seconds or 0.08),
        "--pad-after", tostring(cfg.youtube_censor_pad_after_seconds or 0.12),
        "--beep-hz", tostring(cfg.youtube_censor_beep_hz or 1000.0),
        "--beep-db", tostring(cfg.youtube_censor_beep_db or -12.0),
        "--fade-ms", tostring(cfg.youtube_censor_fade_ms or 70.0),
        "--beep-duck-db", tostring(cfg.youtube_censor_beep_duck_db or -36.0),
    }
    notify("Building censored timeline audio…")
    if not run_logged(args) then
        fail("Auto Censor audio processing failed. See " .. LOG_PATH)
    end
end

local function add_timeline_mute_markers(timeline, fps, intervals)
    delete_markers(timeline, "youtube")
    local added = 0
    for i, r in ipairs(intervals or {}) do
        local start_frame = math.max(0, math.floor((tonumber(r.start) or 0) * fps + 0.5))
        local end_frame = math.max(start_frame + 1, math.floor((tonumber(r.finish) or tonumber(r.start) or 0) * fps + 0.5))
        local note = string.format(
            "ClipTimbre Timeline Mute #%d\n%.3fs - %.3fs\nAudio source clips were rebuilt around this range; no full-length censored WAV is used.",
            i, tonumber(r.start) or 0, tonumber(r.finish) or 0
        )
        if timeline:AddMarker(start_frame, YT_MUTED_COLOR, "[YT] MUTED", note, end_frame - start_frame, YT_MUTED_CUSTOM) then
            added = added + 1
        end
    end
    return added
end

local function get_item_fades(item)
    local fade_in, fade_out = 0, 0
    local supported = false
    local ok, value = pcall(function() return item:GetFades() end)
    if ok and type(value) == "table" then
        fade_in = tonumber(value.FadeIn or value.fadeIn or value[1]) or 0
        fade_out = tonumber(value.FadeOut or value.fadeOut or value[2]) or 0
        supported = true
    end
    return fade_in, fade_out, supported
end

local function get_clip_color(item)
    local color = nil
    pcall(function() color = item:GetClipColor() end)
    if color and tostring(color) ~= "" then return tostring(color) end
    return nil
end

-- AppendToTimeline clipInfo uses SOURCE media frame numbers for startFrame/endFrame,
-- while recordFrame and TimelineItem:GetDuration() use TIMELINE frame numbers.
-- Audio GetSourceStartFrame() is in the source media's frame rate; GetLeftOffset()
-- is in timeline frames. Mixing those domains can turn 10 seconds into ~24 seconds
-- when a 25-fps source is placed on a 60-fps timeline.
local function media_source_fps(media)
    local value = nil
    pcall(function() value = media:GetClipProperty("FPS") end)
    if type(value) == "table" then value = value.FPS or value["Frame Rate"] end
    if not value or tostring(value) == "" then
        pcall(function() value = media:GetClipProperty("Frame Rate") end)
    end
    if type(value) == "table" then value = value.FPS or value["Frame Rate"] end
    local parsed = tostring(value or ""):gsub(",", "."):match("(%d+%.?%d*)")
    local fps = tonumber(parsed)
    if fps and fps >= 1 and fps <= 240 then return fps end
    return nil
end

local function nearest_int(n)
    return math.floor(n + 0.5)
end

local function collect_timeline_mute_plan(timeline, fps, intervals, cfg)
    local timeline_start = safe_number_call(function() return timeline:GetStartFrame() end) or 0
    local track_count = safe_number_call(function() return timeline:GetTrackCount("audio") end) or 0
    if track_count < 1 then fail("Timeline Mute: current timeline has no audio tracks") end

    local mute_frames = {}
    for _, r in ipairs(intervals or {}) do
        local s = timeline_start + math.max(0, nearest_int((tonumber(r.start) or 0) * fps))
        local e = timeline_start + math.max(1, nearest_int((tonumber(r.finish) or tonumber(r.start) or 0) * fps))
        if e <= s then e = s + 1 end
        table.insert(mute_frames, {start=s, finish=e})
    end
    table.sort(mute_frames, function(a,b) return a.start < b.start end)

    local requested_fade = math.max(0, nearest_int(((tonumber(cfg.youtube_censor_fade_ms) or 70.0) / 1000.0) * fps))
    local plan, originals, tracks = {}, {}, {}
    local touched_count = 0
    local untouched_count = 0
    local rounded_away_count = 0
    local fps_seen = {}

    for track = 1, track_count do
        local state = {index=track, locked=false, enabled=true}
        pcall(function() state.locked = timeline:GetIsTrackLocked("audio", track) == true end)
        pcall(function() state.enabled = timeline:GetIsTrackEnabled("audio", track) ~= false end)
        pcall(function() state.name = timeline:GetTrackName("audio", track) end)
        tracks[track] = state

        local ok_items, items = pcall(function() return timeline:GetItemListInTrack("audio", track) end)
        if not ok_items or type(items) ~= "table" then
            fail("Timeline Mute: could not enumerate audio track A" .. tostring(track))
        end

        for _, item in ipairs(items) do
            local item_start = safe_number_call(function() return item:GetStart() end)
            local item_end = safe_number_call(function() return item:GetEnd() end)
            if not item_start or not item_end or item_end <= item_start then
                fail("Timeline Mute found an audio item with invalid timing on A" .. tostring(track))
            end

            -- Leave every unaffected source clip exactly as it was. This also
            -- preserves its per-clip effects/gain, transitions and link state.
            local touched = false
            for _, mute in ipairs(mute_frames) do
                if mute.finish > item_start and mute.start < item_end then
                    touched = true
                    break
                end
            end
            if not touched or not state.enabled then
                untouched_count = untouched_count + 1
            else
                local item_duration = safe_number_call(function() return item:GetDuration() end)
                if not item_duration or math.abs(item_duration - (item_end - item_start)) > 1.5 then
                    fail("Timeline Mute found inconsistent timeline duration on A" .. tostring(track))
                end
                local media = nil
                pcall(function() media = item:GetMediaPoolItem() end)
                if not media then
                    fail("Timeline Mute cannot safely rebuild A" .. tostring(track) .. " because a muted range overlaps a transition/source-less item. Use Smooth Mute.")
                end
                local speed = nil
                pcall(function() speed = item:GetProperty("Speed") end)
                if type(speed) == "table" then speed = speed.Speed or speed.speed end
                local speed_num = tonumber(speed)
                if speed_num and math.abs(speed_num - 100.0) > 0.01 and math.abs(speed_num - 1.0) > 0.001 then
                    fail("Timeline Mute does not rebuild retimed audio clips. Use Smooth Mute.")
                end

                local file_path = optional_call(function() return media:GetClipProperty("File Path") end)
                if type(file_path) == "table" then file_path = file_path["File Path"] end
                local mapping = optional_call(function() return item:GetSourceAudioChannelMapping() end)
                if type(mapping) ~= "string" or not mapping:match("^%s*{") then mapping = nil end
                local source_fps = media_source_fps(media)
                if not source_fps then
                    fail("Timeline Mute cannot determine media FPS for a muted clip on A" .. tostring(track) .. ". Use Smooth Mute.")
                end
                local source_start = safe_number_call(function() return item:GetSourceStartFrame() end)
                if not source_start then
                    -- LeftOffset is in timeline frames, unlike SourceStartFrame.
                    local left = safe_number_call(function() return item:GetLeftOffset() end)
                    if left then source_start = nearest_int(left * source_fps / fps) end
                end
                if not source_start then
                    fail("Timeline Mute cannot determine source in-point for a muted clip on A" .. tostring(track) .. ". Use Smooth Mute.")
                end

                local clip_enabled = true
                pcall(function() clip_enabled = item:GetClipEnabled() ~= false end)
                local name = nil
                pcall(function() name = item:GetName() end)
                local color = get_clip_color(item)
                local original_fade_in, original_fade_out = get_item_fades(item)
                table.insert(originals, item)
                touched_count = touched_count + 1
                fps_seen[string.format("%.3f", source_fps)] = true
                local cursor = item_start

                local function add_piece(piece_start, piece_end, fade_in_internal, fade_out_internal)
                    local length = piece_end - piece_start
                    if length < 1 then return end
                    -- Convert absolute timeline offsets to SOURCE frames. The
                    -- endFrame passed to AppendToTimeline is EXCLUSIVE, not -1.
                    local delta_start = (piece_start - item_start) * source_fps / fps
                    local delta_end = (piece_end - item_start) * source_fps / fps
                    -- Conservative bounds: before a mute, end early rather
                    -- than leak any prohibited audio; after it, start late.
                    local source_piece_start_offset = fade_in_internal and math.ceil(delta_start - 1e-7) or nearest_int(delta_start)
                    local source_piece_end_offset = fade_out_internal and math.floor(delta_end + 1e-7) or nearest_int(delta_end)
                    local source_piece_start = source_start + source_piece_start_offset
                    local source_piece_end = source_start + source_piece_end_offset
                    if source_piece_end <= source_piece_start then
                        -- A sub-source-frame keep sliver cannot be represented;
                        -- leaving it silent is safer than shifting muted audio.
                        rounded_away_count = rounded_away_count + 1
                        return
                    end
                    local max_fade = math.max(0, math.floor((length - 1) / 2))
                    local fade_in = fade_in_internal and math.min(requested_fade, max_fade) or math.min(math.max(0, original_fade_in), max_fade)
                    local fade_out = fade_out_internal and math.min(requested_fade, max_fade) or math.min(math.max(0, original_fade_out), max_fade)
                    table.insert(plan, {
                        media = media,
                        track = track,
                        record_frame = piece_start,
                        source_start = source_piece_start,
                        source_end = source_piece_end,
                        source_fps = source_fps,
                        file_path = file_path,
                        mapping = mapping,
                        expected_duration = length,
                        enabled = clip_enabled,
                        name = name,
                        color = color,
                        fade_in = fade_in,
                        fade_out = fade_out,
                        internal_fade = fade_in_internal or fade_out_internal,
                        mute_after = fade_out_internal == true,
                    })
                end

                for _, mute in ipairs(mute_frames) do
                    if mute.finish > item_start and mute.start < item_end then
                        local cut_start = math.max(item_start, mute.start)
                        local cut_end = math.min(item_end, mute.finish)
                        if cut_start > cursor then
                            add_piece(cursor, cut_start, cursor > item_start, true)
                        end
                        if cut_end > cursor then cursor = cut_end end
                        if cursor >= item_end then break end
                    end
                end
                if cursor < item_end then
                    add_piece(cursor, item_end, cursor > item_start, false)
                end
            end
        end
    end

    if touched_count == 0 then
        fail("Timeline Mute found no enabled audio source clips overlapping the selected mute ranges")
    end
    log(string.format(
        "Timeline Mute preflight: affected_clips=%d untouched_clips=%d source_rates=%s tiny_slivers_skipped=%d",
        touched_count, untouched_count,
        (function() local values = {} for rate in pairs(fps_seen) do table.insert(values, rate) end table.sort(values) return table.concat(values, ",") end)(),
        rounded_away_count
    ))
    return plan, originals, tracks, requested_fade
end
local function unlink_audio_items(timeline, items)
    for _, item in ipairs(items or {}) do
        local linked = nil
        pcall(function() linked = item:GetLinkedItems() end)
        if type(linked) == "table" then
            local group = {item}
            for _, other in pairs(linked) do
                if other then table.insert(group, other) end
            end
            if #group > 1 then pcall(function() timeline:SetClipsLinked(group, false) end) end
        end
    end
end

local function prepare_timeline_mute_fades(media_pool, plan, fps, run_dir, fade_dir)
    local tasks, groups = {}, {}
    local function fragment(original, source_start, source_end, record_frame, duration)
        local result = {}
        for key, value in pairs(original) do result[key] = value end
        result.source_start, result.source_end = source_start, source_end
        result.record_frame, result.expected_duration = record_frame, duration
        return result
    end

    local function edge(original, source_start, record_frame, frames, fade_in, fade_out)
        local id = #tasks + 1
        local name = string.format("edge_%05d.wav", id)
        tasks[id] = string.format(
            '{"id":%d,"path":"%s","mapping":%s,"offset":%.9f,"duration":%.9f,"fade_in":%.9f,"fade_out":%.9f}',
            id, json_escape(original.file_path), original.mapping or "null", source_start / original.source_fps,
            frames / fps, fade_in / fps, fade_out / fps
        )
        local result = fragment(original, 0, frames, record_frame, frames)
        result.fade_file = name
        result.fade_in = fade_in
        result.fade_out = fade_out
        return result
    end

    for _, piece in ipairs(plan) do
        local group = {original=piece, fragments={}}
        groups[#groups + 1] = group
        if piece.enabled and (piece.fade_in > 0 or piece.fade_out > 0) then
            group.requested = true
            if type(piece.file_path) == "string" and file_exists(piece.file_path) then
                local scale = fps / piece.source_fps
                local count = piece.source_end - piece.source_start
                local finish = math.min(piece.expected_duration, nearest_int(count * scale))
                local in_source = piece.fade_in > 0 and math.max(1, nearest_int(piece.fade_in / scale)) or 0
                local out_source = piece.fade_out > 0 and math.max(1, nearest_int(piece.fade_out / scale)) or 0
                local after_in = nearest_int(in_source * scale)
                local before_out = math.min(finish, nearest_int((count - out_source) * scale))
                local parts = group.fragments
                if finish > 0 and (in_source + out_source >= count or before_out <= after_in) then
                    parts[1] = edge(piece, piece.source_start, piece.record_frame, finish,
                        math.min(piece.fade_in, finish / 2), math.min(piece.fade_out, finish / 2))
                elseif finish > 0 then
                    if after_in > 0 then
                        parts[#parts + 1] = edge(piece, piece.source_start, piece.record_frame, after_in, after_in, 0)
                    end
                    local center = fragment(piece, piece.source_start + in_source, piece.source_end - out_source,
                        piece.record_frame + after_in, before_out - after_in)
                    center.mute_after = piece.mute_after and out_source == 0
                    parts[#parts + 1] = center
                    if finish > before_out then
                        parts[#parts + 1] = edge(piece, piece.source_end - out_source, piece.record_frame + before_out,
                            finish - before_out, 0, finish - before_out)
                    end
                end
            end
        end
    end

    if #tasks > 0 then
        local path = run_dir .. "/timeline_fades.json"
        write_all(path, "[" .. table.concat(tasks, ",\n") .. "]")
        local args = {VENV_PYTHON, TIMELINE_FADES_BACKEND_PATH, path, fade_dir}
        if not run_logged(args) then
            fail("Could not render Timeline Mute fades. See " .. LOG_PATH)
        end
    end

    local paths, successful, failures = {}, {}, 0
    for _, group in ipairs(groups) do
        if group.requested then
            local ready, has_edge = #group.fragments > 0, false
            for _, item in ipairs(group.fragments) do
                if item.fade_file then
                    has_edge = true
                    if not file_exists(fade_dir .. "/" .. item.fade_file) then ready = false end
                end
            end
            if ready and has_edge then
                successful[group] = true
                for _, item in ipairs(group.fragments) do
                    if item.fade_file then paths[#paths + 1] = fade_dir .. "/" .. item.fade_file end
                end
            else
                failures = failures + 1
                log("Timeline Mute: edge source unavailable for " .. tostring(group.original.name))
            end
        end
    end

    local imported_by_name = {}
    if #paths > 0 then
        local items = media_pool:ImportMedia(paths) or {}
        for _, item in ipairs(items) do
            local path = optional_call(function() return item:GetClipProperty("File Path") end)
            local name = type(path) == "string" and path:match("[^/\\]+$") or item:GetName()
            imported_by_name[name] = item
        end
    end
    local expanded, edge_count = {}, 0
    for _, group in ipairs(groups) do
        if successful[group] then
            for _, item in ipairs(group.fragments) do
                if item.fade_file then
                    item.media = imported_by_name[item.fade_file]
                    if not item.media then fail("Resolve could not import Timeline Mute edge " .. item.fade_file) end
                    local source_fps = media_source_fps(item.media) or fps
                    item.source_fps = source_fps
                    item.source_end = item.expected_duration * source_fps / fps
                    item.name = (tostring(item.name or "Audio") .. " [fade " .. (item.fade_in > 0 and "in" or "out") .. "]")
                    edge_count = edge_count + 1
                end
                expanded[#expanded + 1] = item
            end
        else
            expanded[#expanded + 1] = group.original
        end
    end
    return expanded, edge_count, failures
end

local function apply_timeline_mute(project, timeline, fps, intervals, cfg, run_dir, fade_dir)
    local media_pool = project:GetMediaPool()
    if not media_pool then fail("Timeline Mute: Resolve Media Pool is unavailable") end
    local plan, originals, tracks, requested_fade = collect_timeline_mute_plan(timeline, fps, intervals, cfg)
    -- A short clip may be fully covered by the mute interval. In that case
    -- deleting just that affected audio clip is the correct result.
    if #plan == 0 then log("Timeline Mute: all affected clip audio is muted; no kept fragments need re-insertion") end

    log(string.format(
        "Timeline Mute plan: source_items=%d kept_fragments=%d mute_ranges=%d fade_frames=%d",
        #originals, #plan, #(intervals or {}), requested_fade
    ))

    local fade_edges, fade_failures
    plan, fade_edges, fade_failures = prepare_timeline_mute_fades(media_pool, plan, fps, run_dir, fade_dir)

    for _, st in pairs(tracks) do
        pcall(function() timeline:SetTrackLock("audio", st.index, false) end)
    end
    unlink_audio_items(timeline, originals)

    local deleted = false
    local ok_delete, delete_result = pcall(function() return timeline:DeleteClips(originals, false) end)
    if ok_delete and delete_result == true then deleted = true end
    if not deleted then
        fail("Timeline Mute could not remove the original audio clips from the safety copy. Original timeline was not changed.")
    end

    local appended_count = 0
    local BATCH = 96
    local index = 1
    while index <= #plan do
        local infos, metas = {}, {}
        local last = math.min(#plan, index + BATCH - 1)
        for i = index, last do
            local m = plan[i]
            table.insert(infos, {
                mediaPoolItem = m.media,
                startFrame = m.source_start,
                endFrame = m.source_end,
                mediaType = 2,
                trackIndex = m.track,
                recordFrame = m.record_frame,
            })
            table.insert(metas, m)
        end

        local inserted = nil
        local ok_append = pcall(function() inserted = media_pool:AppendToTimeline(infos) end)
        if not ok_append or type(inserted) ~= "table" or #inserted ~= #infos then
            fail("Timeline Mute could not place rebuilt source fragments. The censored copy is incomplete; original timeline was not changed.")
        end

        for j, item in ipairs(inserted) do
            local m = metas[j]
            appended_count = appended_count + 1
            local actual_start = safe_number_call(function() return item:GetStart() end)
            local actual_duration = safe_number_call(function() return item:GetDuration() end)
            if actual_start and math.abs(actual_start - m.record_frame) > 1.5 then
                fail(string.format("Timeline Mute placement mismatch on A%d: expected frame %.3f, got %.3f", m.track, m.record_frame, actual_start))
            end
            -- Mixed-frame-rate media can quantize a boundary by one SOURCE
            -- frame (e.g. 2.4 timeline frames at 25 -> 60 fps). Anything larger
            -- remains a hard failure: never silently produce a shifted edit.
            local duration_tolerance = math.max(1.5, math.ceil(fps / m.source_fps) + 0.5)
            if actual_duration and math.abs(actual_duration - m.expected_duration) > duration_tolerance then
                fail(string.format(
                    "Timeline Mute duration mismatch on A%d: expected %.3f timeline frames, got %.3f (media FPS %.3f, timeline FPS %.3f)",
                    m.track, m.expected_duration, actual_duration, m.source_fps, fps
                ))
            end
            -- A fragment before a censored word must never overlap that mute
            -- interval. Source frame rounding above chooses the safe side.
            if m.mute_after and actual_start and actual_duration and (actual_start + actual_duration) > m.record_frame + m.expected_duration + 0.5 then
                fail(string.format("Timeline Mute audio overlaps a muted range on A%d; aborting unsafe copy", m.track))
            end

            if m.name and tostring(m.name) ~= "" then pcall(function() item:SetName(tostring(m.name)) end) end
            if m.color then pcall(function() item:SetClipColor(m.color) end) end
            if m.enabled == false then pcall(function() item:SetClipEnabled(false) end) end

        end
        index = last + 1
    end

    for _, st in pairs(tracks) do
        pcall(function() timeline:SetTrackEnable("audio", st.index, st.enabled ~= false) end)
        pcall(function() timeline:SetTrackLock("audio", st.index, st.locked == true) end)
    end

    local marker_count = add_timeline_mute_markers(timeline, fps, intervals)
    log(string.format("Timeline Mute: inserted %d processed audio edges; unavailable fragments=%d", fade_edges, fade_failures))
    return {
        fragments = appended_count,
        markers = marker_count,
        fade_edges = fade_edges,
        fade_failures = fade_failures,
    }
end

local function append_censored_audio(project, timeline, path, cfg)
    local media_pool = project:GetMediaPool()
    if not media_pool then fail("Resolve Media Pool is unavailable") end

    local old_tracks = tonumber(timeline:GetTrackCount("audio")) or 0
    local added = false
    local inserted_front = false

    -- Prefer A1 so the final upload copy feels like a normal flattened mix,
    -- not an extra utility stem sitting underneath all source tracks.
    if old_tracks > 0 then
        pcall(function()
            added = timeline:AddTrack("audio", {audioType="stereo", index=1})
            inserted_front = added == true
        end)
    end
    if not added then pcall(function() added = timeline:AddTrack("audio", {audioType="stereo"}) end) end
    if not added then pcall(function() added = timeline:AddTrack("audio", "stereo") end) end
    if not added then fail("Could not add a stereo audio track for the censored mix") end

    local target_track = inserted_front and 1 or (tonumber(timeline:GetTrackCount("audio")) or (old_tracks + 1))
    pcall(function() timeline:SetTrackName("audio", target_track, tostring(cfg.youtube_censor_track_name or "YT Censored Mix")) end)

    local imported = nil
    pcall(function() imported = media_pool:ImportMedia({path}) end)
    if type(imported) ~= "table" or not imported[1] then
        fail("Could not import the censored WAV into Resolve Media Pool")
    end
    local start_frame = tonumber(timeline:GetStartFrame()) or 0
    local inserted = nil
    pcall(function()
        inserted = media_pool:AppendToTimeline({{
            mediaPoolItem = imported[1],
            mediaType = 2,
            trackIndex = target_track,
            recordFrame = start_frame,
        }})
    end)
    if type(inserted) ~= "table" or not inserted[1] then
        pcall(function() timeline:DeleteTrack("audio", target_track) end)
        fail("Resolve could not place the censored audio at the timeline start")
    end

    local placed_start = safe_number_call(function() return inserted[1]:GetStart() end)
    local placed_end = safe_number_call(function() return inserted[1]:GetEnd() end)
    local timeline_end = safe_number_call(function() return timeline:GetEndFrame() end)
    if placed_start and math.abs(placed_start - start_frame) > 1.5 then
        fail("Censored audio was inserted at the wrong timeline position")
    end
    if placed_end and timeline_end and placed_end < timeline_end - 2 then
        fail("Censored audio does not cover the full timeline")
    end

    if cfg.youtube_censor_flatten_audio ~= false then
        -- This timeline is already a safety copy. Remove the original audio
        -- tracks from the copy so the user ends with one clean A1 mix instead
        -- of a disabled pile of source tracks plus an extra stem.
        local first_original = inserted_front and 2 or 1
        local last_original = inserted_front and (old_tracks + 1) or old_tracks
        local delete_failed = false
        for track = last_original, first_original, -1 do
            pcall(function() timeline:SetTrackLock("audio", track, false) end)
            local ok_delete = false
            pcall(function() ok_delete = timeline:DeleteTrack("audio", track) end)
            if not ok_delete then
                delete_failed = true
                pcall(function() timeline:SetTrackEnable("audio", track, false) end)
                log("Auto Censor warning: could not delete original audio track A" .. tostring(track) .. "; disabled it instead")
            end
        end

        local final_target = 1
        pcall(function()
            local ti = inserted[1]:GetTrackTypeAndIndex()
            if type(ti) == "table" then
                local idx = tonumber(ti[2] or ti.trackIndex or ti.index)
                if idx and idx >= 1 then final_target = idx end
            end
        end)
        pcall(function() timeline:SetTrackEnable("audio", final_target, true) end)
        pcall(function() timeline:SetTrackName("audio", final_target, tostring(cfg.youtube_censor_track_name or "YT Censored Mix")) end)
        if delete_failed then
            notify("Censored mix created. Some original audio tracks could not be deleted and were disabled instead.")
        end
        return final_target, not delete_failed
    end

    -- Advanced compatibility fallback: retain source tracks but keep them
    -- disabled. This can be enabled manually in config.json.
    if inserted_front then
        for track = 2, old_tracks + 1 do
            local ok = timeline:SetTrackEnable("audio", track, false)
            if ok == false then fail("Could not disable original audio track A" .. tostring(track)) end
        end
    else
        for track = 1, old_tracks do
            local ok = timeline:SetTrackEnable("audio", track, false)
            if ok == false then fail("Could not disable original audio track A" .. tostring(track)) end
        end
    end
    timeline:SetTrackEnable("audio", target_track, true)
    return target_track, false
end

function M.auto_censor_youtube(opts)
    opts = opts or {}
    local _, project, timeline = get_context()
    local cfg = load_config()
    local fps = get_fps(timeline)
    local scan_problem = youtube_state_problem(project, timeline, fps)
    if scan_problem then
        notify("Auto Censor needs a fresh scan (" .. scan_problem .. "); scanning now…")
        M.scan_youtube_safety()
        validate_youtube_state(project, timeline, fps)
    end

    local categories, category_set = censor_category_list(opts)
    local severities = censor_severity_list(opts)
    if #categories == 0 then fail("Select at least one Auto Censor category") end
    if #severities == 0 then fail("Select HIGH and/or REVIEW severity for Auto Censor") end
    local severity_set = {}
    for _, v in ipairs(severities) do severity_set[v] = true end

    local events = parse_ad_safety_tsv(LATEST_AD_SAFETY_PATH)
    local count = selected_censor_event_count(events, category_set, severity_set)
    if count == 0 then fail("No eligible risks match the current Auto Censor selection") end
    local mode = tostring(opts.mode or "beep")
    if mode ~= "mute" and mode ~= "timeline_mute" then mode = "beep" end
    local intervals = selected_censor_intervals(events, category_set, severity_set, cfg)
    if #intervals == 0 then fail("No mute intervals remain after filtering the current YouTube scan") end
    if not ask_censor_confirmation(count, mode, join_csv(categories)) then
        notify("Auto Censor cancelled")
        return
    end

    mkdir_p(APP_DIR .. "/tmp")
    mkdir_p(CENSORED_DIR)
    local stamp = os.date("%Y%m%d_%H%M%S")
    local copy_name = tostring(timeline:GetName()) .. " [YT censored " .. stamp .. "]"
    local original_timeline = timeline
    local censored_timeline = nil
    local ok_dup, dup = pcall(function() return original_timeline:DuplicateTimeline(copy_name) end)
    if ok_dup then censored_timeline = dup end
    if not censored_timeline then fail("Could not duplicate the timeline for Auto Censor; original was not changed") end
    if not project:SetCurrentTimeline(censored_timeline) then
        fail("Could not switch to the censored timeline copy; original was not changed")
    end

    local run_dir = APP_DIR .. "/tmp/censor_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000,9999))
    mkdir_p(run_dir)
    local stem_path = CENSORED_DIR .. "/youtube_censored_" .. stamp .. ".wav"
    local summary_path = CENSORED_DIR .. "/youtube_censored_" .. stamp .. ".json"
    local fade_dir = CENSORED_DIR .. "/timeline_mute_" .. run_dir:match("[^/\\]+$")
    local success, err = pcall(function()
        if mode == "timeline_mute" then
            local result = apply_timeline_mute(project, censored_timeline, fps, intervals, cfg, run_dir, fade_dir)
            log(string.format(
                "Timeline Mute complete: timeline=%s ranges=%d fragments=%d markers=%d fade_failures=%d",
                copy_name, #intervals, result.fragments or 0, result.markers or 0, result.fade_failures or 0
            ))
            local fade_note = string.format(" %d short audio fade clip(s) added.", result.fade_edges)
            if result.fade_failures > 0 then
                fade_note = fade_note .. string.format(" %d fragment(s) with unsupported audio mapping use hard edges.", result.fade_failures)
            end
            notify(string.format(
                "Timeline Mute complete: %d flagged interval(s) merged to %d visible muted range(s). New timeline: %s.%s",
                count, #intervals, copy_name, fade_note
            ))
        else
            -- Beep / Smooth Mute keep the processed-mix path. Prefer the same
            -- file-backed timeline map used by Voice and YouTube Scan so no
            -- unreliable Deliver render is needed for ordinary cut timelines.
            local manifest_path = run_dir .. "/timeline_audio_manifest.json"
            local manifest = write_timeline_audio_manifest(censored_timeline, fps, manifest_path)
            local censor_source = nil
            if manifest.complete and manifest.clip_count > 0 then
                censor_source = {kind="manifest", path=manifest.path}
                log(string.format(
                    "Auto Censor using cut-timeline manifest directly: clips=%d duration=%.3fs",
                    manifest.clip_count, tonumber(manifest.duration) or 0
                ))
            else
                log(string.format(
                    "Auto Censor timeline map incomplete (clips=%d unsupported=%d); falling back to Resolve temporary render",
                    tonumber(manifest.clip_count) or 0, tonumber(manifest.unsupported) or 0
                ))
                local rendered = render_timeline_audio(project, censored_timeline, run_dir)
                censor_source = {kind="audio", path=rendered}
            end
            run_censor_backend(censor_source, cfg, opts, join_csv(categories), join_csv(severities), stem_path, summary_path)
            local target_track, flattened = append_censored_audio(project, censored_timeline, stem_path, cfg)
            log(string.format("Auto Censor complete: timeline=%s target_audio_track=%d flattened=%s stem=%s", copy_name, target_track, tostring(flattened), stem_path))
            notify(string.format("Auto Censor complete: %d interval(s), mode=%s. New timeline: %s", count, mode, copy_name))
        end
    end)
    remove_tree(run_dir)
    if not success then
        pcall(function() project:SetCurrentTimeline(original_timeline) end)
        -- An incomplete safety copy is dangerous: editors may mistake it for
        -- a successful censored edit. Best-effort cleanup after switching away.
        local cleaned = false
        pcall(function() cleaned = project:GetMediaPool():DeleteTimelines({censored_timeline}) == true end)
        if cleaned and mode == "timeline_mute" then remove_tree(fade_dir) end
        log("Auto Censor failed on copy " .. copy_name .. "; incomplete copy removed=" .. tostring(cleaned) .. ": " .. tostring(err))
        error(err)
    end
end

function M.clear_youtube_markers()
    local _, _, timeline = get_context()
    local count = delete_markers(timeline, "youtube")
    notify("Removed " .. tostring(count) .. " YouTube ad-safety markers")
end

local function youtube_marker_frames(timeline)
    local frames = {}
    local markers = timeline:GetMarkers() or {}
    for frame, data in pairs(markers) do
        local name = marker_field(data, "name")
        local custom = marker_field(data, "customData")
        if custom == YT_REVIEW_CUSTOM or custom == YT_HIGH_CUSTOM or name:sub(1, 4) == "[YT]" then
            table.insert(frames, math.floor(tonumber(frame) + 0.5))
        end
    end
    table.sort(frames)
    return frames
end

function M.next_youtube_risk()
    local _, _, timeline = get_context()
    local fps = get_fps(timeline)
    local current = current_relative_frame(timeline, fps)
    local frames = youtube_marker_frames(timeline)
    if #frames == 0 then fail("No YouTube ad-safety markers on current timeline") end
    local target = frames[1]
    for _, frame in ipairs(frames) do if frame > current then target = frame; break end end
    local tc = relative_frame_to_timecode(timeline, target, fps)
    if not timeline:SetCurrentTimecode(tc) then fail("Could not move playhead to " .. tc) end
    notify("Next YouTube risk: " .. tc)
end

function M.previous_youtube_risk()
    local _, _, timeline = get_context()
    local fps = get_fps(timeline)
    local current = current_relative_frame(timeline, fps)
    local frames = youtube_marker_frames(timeline)
    if #frames == 0 then fail("No YouTube ad-safety markers on current timeline") end
    local target = frames[#frames]
    for i = #frames, 1, -1 do if frames[i] < current - 1 then target = frames[i]; break end end
    local tc = relative_frame_to_timecode(timeline, target, fps)
    if not timeline:SetCurrentTimecode(tc) then fail("Could not move playhead to " .. tc) end
    notify("Previous YouTube risk: " .. tc)
end

local function linux_resolve_has_focus()
    if not os.getenv("DISPLAY") or os.getenv("XDG_SESSION_TYPE") == "wayland" then return false end
    local output = io.popen("xdotool getactivewindow getwindowpid 2>/dev/null")
    local pid = output and output:read("*l")
    if output then output:close() end
    if not pid or not pid:match("^%d+$") then return false end
    local link = io.popen("readlink /proc/" .. pid .. "/exe 2>/dev/null")
    local executable = link and link:read("*l")
    if link then link:close() end
    return executable and executable:match("/resolve$") ~= nil
end

local function accessibility_enabled()
    if IS_LINUX then return linux_resolve_has_focus() end
    if IS_WINDOWS then return true end
    local script = 'tell application "System Events" to return name of menu bar item 1 of menu bar 1 of (first application process whose bundle identifier is "com.blackmagic-design.DaVinciResolve")'
    local p = io.popen("osascript -e " .. shell_quote(script) .. " 2>/dev/null")
    local value = p and p:read("*l") or nil
    if p then p:close() end
    return value ~= nil and value ~= ""
end

local function click_resolve_menu(menu_name, item_name)
    if IS_WINDOWS or IS_LINUX then return false end
    local script =
        'tell application "DaVinci Resolve" to activate\n' ..
        'tell application "System Events"\n' ..
        '  set resolveProcess to first application process whose bundle identifier is "com.blackmagic-design.DaVinciResolve"\n' ..
        '  tell resolveProcess\n' ..
        '    click menu item ' .. string.format("%q", item_name) .. ' of menu ' .. string.format("%q", menu_name) .. ' of menu bar item ' .. string.format("%q", menu_name) .. ' of menu bar 1\n' ..
        '  end tell\n' ..
        'end tell'
    local r1, r2, r3 = os.execute("osascript -e " .. shell_quote(script) .. " >/dev/null 2>&1")
    return command_ok(r1, r2, r3)
end

local function send_resolve_keystroke(key_text, modifier)
    if IS_WINDOWS then
        local keys
        if key_text == "__DELETE__" then
            keys = modifier == "shift" and "+{BACKSPACE}" or "{BACKSPACE}"
        else
            keys = tostring(key_text)
            if modifier == "option" then keys = "%" .. keys end
            if modifier == "shift" then keys = "+" .. keys end
        end
        local ps = "$ws=New-Object -ComObject WScript.Shell\n" ..
            "$null=$ws.AppActivate('DaVinci Resolve')\n" ..
            "Start-Sleep -Milliseconds 120\n" ..
            "$ws.SendKeys(" .. ps_quote(keys) .. ")\n" ..
            "Write-Output 'OK'"
        return run_powershell_capture(ps) == "OK"
    end

    if IS_LINUX then
        if not linux_resolve_has_focus() then return false end
        local key = key_text == "__DELETE__" and "BackSpace" or key_text
        if modifier == "option" then key = "alt+" .. key end
        if modifier == "shift" then key = "shift+" .. key end
        return command_ok(os.execute("xdotool key --clearmodifiers " .. shell_quote(key) .. " >/dev/null 2>&1"))
    end

    local action = nil
    if key_text == "__DELETE__" then
        action = modifier == "shift" and 'key code 51 using {shift down}' or 'key code 51'
    else
        local suffix = ""
        if modifier == "option" then suffix = " using {option down}" end
        if modifier == "shift" then suffix = " using {shift down}" end
        action = 'keystroke ' .. string.format("%q", key_text) .. suffix
    end
    local script =
        'tell application "DaVinci Resolve" to activate\n' ..
        'tell application "System Events"\n' ..
        '  set resolveProcess to first application process whose bundle identifier is "com.blackmagic-design.DaVinciResolve"\n' ..
        '  tell resolveProcess\n' ..
        '    ' .. action .. '\n' ..
        '  end tell\n' ..
        'end tell'
    local r1, r2, r3 = os.execute("osascript -e " .. shell_quote(script) .. " >/dev/null 2>&1")
    return command_ok(r1, r2, r3)
end

local function mark_in_action()
    if click_resolve_menu("Mark", "Mark In") then return true end
    return send_resolve_keystroke("i", nil)
end

local function mark_out_action()
    if click_resolve_menu("Mark", "Mark Out") then return true end
    return send_resolve_keystroke("o", nil)
end

local function ripple_delete_action()
    if click_resolve_menu("Edit", "Ripple Delete") then return true end
    return send_resolve_keystroke("__DELETE__", "shift")
end

local function clear_in_out_action()
    if click_resolve_menu("Mark", "Clear In and Out") then return true end
    return send_resolve_keystroke("x", "option")
end

local function ask_tighten_confirmation(auto_count, total_delete)
    local message = string.format(
        "Ripple-delete %d pauses inside streamer speech? About %.1f seconds will be removed. A safety timeline backup will be created first.",
        auto_count, total_delete
    )
    if IS_LINUX then return linux_confirm("ClipTimbre", message) end
    if IS_WINDOWS then
        local ps = "Add-Type -AssemblyName PresentationFramework\n" ..
            "$r=[System.Windows.MessageBox]::Show(" .. ps_quote(message) .. "," .. ps_quote("ClipTimbre") .. ",[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning)\n" ..
            "if ($r -eq [System.Windows.MessageBoxResult]::Yes) { Write-Output 'YES' }"
        return run_powershell_capture(ps) == "YES"
    end
    local script = 'display dialog ' .. string.format('%q', message) .. ' with title "ClipTimbre" buttons {"Cancel", "Tighten"} default button "Tighten" with icon caution\nreturn button returned of result'
    local p = io.popen("osascript -e " .. shell_quote(script) .. " 2>/dev/null")
    local answer = p and p:read("*l") or nil
    if p then p:close() end
    return answer == "Tighten"
end

local function duplicate_timeline_backup(project, timeline)
    local backup_name = tostring(timeline:GetName()) .. " [SV backup " .. os.date("%H%M%S") .. "]"
    local ok, result = pcall(function() return timeline:DuplicateTimeline(backup_name) end)
    if not ok or not result then
        log("Timeline backup creation failed via DuplicateTimeline")
        return false, backup_name
    end
    pcall(function() project:SetCurrentTimeline(timeline) end)
    log("Safety timeline backup created: " .. backup_name)
    return true, backup_name
end

local function validate_pause_state(timeline, fps)
    local state = read_kv_file(PAUSE_STATE_PATH)
    if not state then fail("Pause analysis state missing. Run 'Mark Streamer Pauses' again.") end
    if tostring(state.timeline_id) ~= timeline_id(timeline) then
        fail("Pause markers belong to another timeline. Run Mark Streamer Pauses again.")
    end
    if math.abs((tonumber(state.fps) or fps) - fps) > 0.01 then
        fail("Timeline FPS changed after pause analysis.")
    end
    if not state.plan_id or not state.layout or state.layout ~= timeline_layout(timeline, {"audio", "video", "subtitle"}) then
        fail("Timeline or pause plan changed. Run Mark Streamer Pauses again before Tighten.")
    end
    return state
end

local function native_ripple_items(timeline, cut)
    local absolute_start = timeline:GetStartFrame()
    local first = absolute_start + cut.start_frame
    local last = absolute_start + cut.end_frame
    local targets = {}
    for _, kind in ipairs({"video", "audio", "subtitle"}) do
        for track = 1, timeline:GetTrackCount(kind) or 0 do
            local items = timeline:GetItemListInTrack(kind, track)
            if type(items) ~= "table" then return nil end
            for _, item in ipairs(items) do
                local start_frame = safe_number_call(function() return item:GetStart(true) end)
                local end_frame = safe_number_call(function() return item:GetEnd(true) end)
                if not start_frame or not end_frame then return nil end
                if end_frame > first and start_frame < last then
                    -- The native API removes whole clips. Any crossing item
                    -- requires the Edit page's range-based Ripple Delete.
                    if math.abs(start_frame - first) > 1e-5 or math.abs(end_frame - last) > 1e-5 then return nil end
                    targets[#targets + 1] = item
                end
            end
        end
    end
    if #targets > 0 then return targets end
end

function M.tighten_streamer_pauses()
    local r, project, timeline = get_context()
    local cfg = load_config()
    local fps = get_fps(timeline)
    local pause_state = validate_pause_state(timeline, fps)
    if not file_exists(LATEST_PAUSES_PATH) then fail("No pause list. Run 'Mark Streamer Pauses' first.") end
    local pauses = parse_pause_tsv(LATEST_PAUSES_PATH, pause_state.plan_id)
    local cuts = {}
    local total_delete = 0
    local markers = timeline:GetMarkers() or {}
    local span = timeline_span(timeline)
    for _, p in ipairs(pauses) do
        local marker_frame = math.floor(p.start * fps + 0.5)
        local marker = markers[marker_frame] or markers[tostring(marker_frame)]
        if p.action == "auto" and marker_field(marker, "customData") == PAUSE_CUSTOM and
            marker_field(marker, "note"):match("\nplan: ([^\r\n]+)$") == pause_state.plan_id and
            (p.delete_duration or 0) >= cfg.pause_trim_min_delete_seconds then
            local sf = math.ceil(p.delete_start * fps)
            local ef_exclusive = math.floor(p.delete_end * fps)
            if sf < 0 or ef_exclusive > span or ef_exclusive <= sf then fail("Pause range is outside the timeline") end
            if (ef_exclusive - sf) / fps >= cfg.pause_trim_min_delete_seconds then
                table.insert(cuts, {start_frame=sf, end_frame=ef_exclusive})
                total_delete = total_delete + (ef_exclusive - sf) / fps
            end
        end
    end
    if #cuts == 0 then fail("No automatic pause cuts are available") end
    table.sort(cuts, function(a,b) return a.start_frame > b.start_frame end)
    for i = 2, #cuts do
        if cuts[i].end_frame > cuts[i-1].start_frame then fail("Pause ranges overlap. Run Mark Streamer Pauses again") end
    end

    if not ask_tighten_confirmation(#cuts, total_delete) then
        notify("Tighten cancelled")
        return
    end
    if validate_pause_state(timeline, fps).plan_id ~= pause_state.plan_id then
        fail("Pause plan changed while confirming Tighten")
    end

    if not r:OpenPage("edit") then fail("Could not open the Resolve Edit page") end
    for _, kind in ipairs({"audio", "video", "subtitle"}) do
        for track = 1, timeline:GetTrackCount(kind) or 0 do
            if optional_call(function() return timeline:GetIsTrackLocked(kind, track) end) then
                fail("Unlock the timeline tracks before tightening pauses")
            end
        end
    end
    local has_range_cuts = false
    for _, cut in ipairs(cuts) do
        cut.native_items = native_ripple_items(timeline, cut)
        if not cut.native_items then has_range_cuts = true end
    end
    if has_range_cuts then
        local selected = optional_call(function() return timeline:GetSelectedClips() end)
        if type(selected) == "table" and next(selected) then
            fail("Deselect clips on the Edit page before tightening pauses inside clips")
        end
        if not accessibility_enabled() then
            if IS_LINUX then
                fail("Cuts inside clips need xdotool, an X11 session and the Resolve Edit page in focus")
            end
            fail("Cuts inside clips need Accessibility for Resolve to invoke range-based Ripple Delete. Enable it in System Settings → Privacy & Security → Accessibility.")
        end
    end
    local backup_ok, backup_name = duplicate_timeline_backup(project, timeline)
    if cfg.pause_trim_require_backup and not backup_ok then
        fail("Could not create safety timeline backup; no edits were performed. Duplicate the timeline manually or set pause_trim_require_backup=false.")
    end

    local current = project:GetCurrentTimeline()
    if not current or timeline_id(current) ~= timeline_id(timeline) then
        fail("Resolve did not return to the original timeline after making the backup")
    end
    wait_seconds(0.20)
    local delay = math.max(0.03, tonumber(cfg.pause_trim_ui_delay_seconds) or 0.08)
    local completed = 0
    local original_marks = optional_call(function() return timeline:GetMarkInOut() end)
    local used_range = false
    local ok, err = pcall(function()
        for _, cut in ipairs(cuts) do
            local before = timeline_span(timeline)
            if cut.native_items then
                if not timeline:DeleteClips(cut.native_items, true) then error("Resolve rejected native Ripple Delete") end
                log("Tighten: native Resolve Ripple Delete")
            else
                used_range = true
                local last_frame = cut.end_frame - 1
                if optional_call(function() return timeline:SetMarkInOut(cut.start_frame, last_frame) end) then
                    local marks = timeline:GetMarkInOut() or {}
                    for _, kind in ipairs({"video", "audio"}) do
                        local range = marks[kind] or {}
                        if tonumber(range["in"]) ~= cut.start_frame or tonumber(range["out"]) ~= last_frame then
                            error("Resolve did not confirm the requested In/Out range")
                        end
                    end
                else
                    local in_tc = relative_frame_to_timecode(timeline, cut.start_frame, fps)
                    local out_tc = relative_frame_to_timecode(timeline, last_frame, fps)
                    if not timeline:SetCurrentTimecode(in_tc) then error("Could not set pause In timecode: " .. in_tc) end
                    wait_seconds(delay)
                    if not mark_in_action() then error("Could not set Mark In") end
                    wait_seconds(delay)
                    if not timeline:SetCurrentTimecode(out_tc) then error("Could not set pause Out timecode: " .. out_tc) end
                    wait_seconds(delay)
                    if not mark_out_action() then error("Could not set Mark Out") end
                    wait_seconds(delay)
                end
                if not ripple_delete_action() then error("Could not invoke Ripple Delete") end
            end
            local expected = before - (cut.end_frame - cut.start_frame)
            for _ = 1, 10 do
                if timeline_span(timeline) ~= before then break end
                wait_seconds(delay)
            end
            if timeline_span(timeline) ~= expected then
                error("Unexpected timeline duration after Ripple Delete. Check the Edit timeline focus, shortcuts and Auto Track Select")
            end
            completed = completed + 1
            if completed % 10 == 0 or completed == #cuts then
                log(string.format("Tighten pauses: %d/%d", completed, #cuts))
            end
        end
    end)
    if used_range and not optional_call(function() return timeline:ClearMarkInOut() end) then clear_in_out_action() end

    if not ok and pause_state.layout == timeline_layout(timeline, {"audio", "video", "subtitle"}) then
        if type(original_marks) == "table" then
            for _, kind in ipairs({"video", "audio"}) do
                local range = original_marks[kind]
                if range then optional_call(function() timeline:SetMarkInOut(range["in"], range["out"], kind) end) end
            end
        end
        log(err)
        fail("Tighten stopped before any verified edit. See " .. LOG_PATH)
    end

    delete_markers(timeline, "matches")
    delete_markers(timeline, "pauses")
    delete_markers(timeline, "reference")
    delete_markers(timeline, "youtube")
    delete_markers(timeline, "video_holds")
    os.remove(STATE_PATH)
    os.remove(PAUSE_STATE_PATH)
    os.remove(ANALYSIS_STATE_PATH)
    os.remove(LATEST_PAUSES_PATH)
    os.remove(LATEST_PAUSES_JSON_PATH)
    os.remove(YOUTUBE_STATE_PATH)
    os.remove(LATEST_AD_SAFETY_PATH)
    os.remove(LATEST_AD_SAFETY_JSON_PATH)
    if not ok then
        log(err)
        fail("Tighten stopped after " .. tostring(completed) .. " verified edits. Safety backup: " .. tostring(backup_name) .. ". See log.")
    end
    notify(string.format(
        "Tightened %d pauses; removed about %.1fs. Backup: %s. Analysis markers were cleared because timeline timing changed.",
        completed, total_delete, tostring(backup_name)
    ))
end

function M.clear_cache()
    remove_tree(APP_DIR .. "/cache")
    mkdir_p(APP_DIR .. "/cache")
    notify("ClipTimbre embedding cache cleared")
end


local function run_profile_command(...)
    if not file_exists(VENV_PYTHON) or not file_exists(PROFILE_BACKEND_PATH) then
        fail("Profile backend missing. Re-run the ClipTimbre installer")
    end
    return run_capture({VENV_PYTHON, PROFILE_BACKEND_PATH, "--data-dir", APP_DIR, ...}, true)
end

local function prompt_text(title, message, default_value)
    if IS_LINUX then
        if not command_ok(os.execute("command -v zenity >/dev/null 2>&1")) then
            fail("Install zenity to edit profile names on Linux")
        end
        local command = "zenity --entry --title=" .. shell_quote(title) .. " --text=" .. shell_quote(message) ..
            " --entry-text=" .. shell_quote(default_value or "") .. " 2>/dev/null"
        local result = io.popen(command)
        local text = result and result:read("*l")
        if result then result:close() end
        if text and text:match("%S") then return text end
        return nil
    end
    if IS_WINDOWS then
        local ps = "Add-Type -AssemblyName Microsoft.VisualBasic\n" ..
            "$v=[Microsoft.VisualBasic.Interaction]::InputBox(" .. ps_quote(message) .. "," .. ps_quote(title) .. "," .. ps_quote(default_value or "") .. ")\n" ..
            "Write-Output $v"
        local out = run_powershell_capture(ps)
        if not out or out == "" then return nil end
        return out
    end
    local script = 'display dialog ' .. string.format('%q', message) ..
        ' with title ' .. string.format('%q', title) ..
        ' default answer ' .. string.format('%q', default_value or '') ..
        ' buttons {"Cancel", "OK"} default button "OK"\nreturn text returned of result'
    local p = io.popen("osascript -e " .. shell_quote(script) .. " 2>/dev/null")
    local out = p and p:read("*a") or nil
    if p then p:close() end
    if not out then return nil end
    out = out:gsub("%s+$", "")
    if out == "" then return nil end
    return out
end

function M.list_profiles()
    local out = run_profile_command("list")
    if not out then fail("Could not read the voice profiles") end
    local names = {}
    for name in out:gmatch("[^\r\n]+") do
        names[#names + 1] = name
    end
    return names, active_profile_name()
end

local function checked_profile_name(name)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" or name:find("[^\128-\255%w .()_%-]") then
        fail("Enter a profile name using letters, numbers, spaces or simple punctuation.")
    end
    return name
end

function M.select_profile(name)
    local out
    if name then
        out = run_profile_command("select", "--existing", "--", checked_profile_name(name))
    else
        name = prompt_text("ClipTimbre", "Profile name:", active_profile_name())
        if not name then return end
        out = run_profile_command("select", "--", checked_profile_name(name))
    end
    if not out or out == "" then fail("Could not select profile. See log.") end
    return out
end

function M.create_profile(name)
    local out = run_profile_command("select", "--create", "--", checked_profile_name(name))
    if not out or out == "" then fail("Enter a unique profile name using letters, numbers, spaces or simple punctuation.") end
    return out
end

function M.profile_status()
    local name = active_profile_name()
    local out = run_profile_command("status", "--profile=" .. name)
    if not out then fail("Could not read profile status") end
    notify("Profile " .. name .. ": " .. out)
end

function M.add_profile_reference()
    local _, project, timeline = get_context()
    local cfg = load_config()
    local fps = get_fps(timeline)
    local rel_frame = current_relative_frame(timeline, fps)
    local duration = tonumber(cfg.reference_duration_seconds) or 10.0
    local name = active_profile_name()

    mkdir_p(APP_DIR .. "/tmp")
    local run_dir = APP_DIR .. "/tmp/profile_ref_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000,9999))
    mkdir_p(run_dir)
    local ok, err = pcall(function()
        local source = prepare_timeline_audio_source(project, timeline, fps, run_dir, cfg)
        local args = {"add-reference", "--profile=" .. name}
        local offset = rel_frame / fps
        if source.kind == "manifest" then
            table.insert(args, "--manifest")
            table.insert(args, source.path)
        else
            table.insert(args, "--audio")
            table.insert(args, source.path)
            offset = (source.input_offset or 0) + offset
        end
        table.insert(args, "--offset")
        table.insert(args, tostring(offset))
        table.insert(args, "--duration")
        table.insert(args, tostring(duration))
        local out = run_profile_command(unpack(args))
        if not out then fail("Could not save profile reference. See log.") end
        timeline:AddMarker(rel_frame, "Blue", MARKER_PREFIX .. " PROFILE REF", "Saved to profile: " .. name, math.max(1, math.floor(duration * fps + 0.5)), "streamer_voice_profile_ref_v1")
        notify(string.format("Added %.1fs voice sample to profile '%s'", duration, name))
    end)
    remove_tree(run_dir)
    if not ok then error(err) end
end


function M.clear_profile_references()
    local name = active_profile_name()
    local out = run_profile_command("clear-references", "--profile=" .. name)
    if not out then fail("Could not clear profile references") end
    notify("Cleared " .. tostring(out) .. " reference sample(s) from profile " .. name)
end

local function current_streamer_marker(timeline, fps)
    local current = current_relative_frame(timeline, fps)
    local markers = timeline:GetMarkers() or {}
    local best = nil
    for frame, data in pairs(markers) do
        local name = marker_field(data, "name")
        local custom = marker_field(data, "customData")
        if custom == MARKER_CUSTOM or name:sub(1, #MARKER_PREFIX + 9) == MARKER_PREFIX .. " STREAMER" then
            local startf = math.floor(tonumber(frame) + 0.5)
            local duration = tonumber(marker_field(data, "duration")) or tonumber(data.duration) or 1
            local endf = startf + math.max(1, math.floor(duration + 0.5))
            if current >= startf and current < endf then
                local note = marker_field(data, "note")
                local score = tonumber(note:match("cosine similarity:%s*([%d%.%-]+)")) or
                    tonumber(name:match("([%d%.%-]+)%s*$"))
                if score then best = {score=score, frame=startf, name=name}; break end
            end
        end
    end
    return best
end

local function submit_feedback(label)
    local _, _, timeline = get_context()
    local fps = get_fps(timeline)
    local marker = current_streamer_marker(timeline, fps)
    if not marker then fail("Put the playhead inside a [SV] STREAMER marker first") end
    local profile = active_profile_name()
    local out = run_profile_command(
        "feedback", "--profile=" .. profile,
        "--score", tostring(marker.score),
        "--label", label
    )
    if not out then fail("Could not save profile feedback") end
    notify(string.format("%s: score %.3f. New threshold: %s", label == "correct" and "Confirmed streamer" or "Marked wrong", marker.score, out))
end

function M.feedback_correct() submit_feedback("correct") end
function M.feedback_wrong() submit_feedback("wrong") end

function M.diagnostics()
    local r, project, timeline = get_context()
    local fps = get_fps(timeline)
    local cfg = load_config()
    mkdir_p(APP_DIR)
    local version = "unknown"
    pcall(function() version = r:GetVersionString() end)
    local lines = {
        "bridge=lua",
        "resolve_version=" .. tostring(version),
        "project=" .. tostring(project:GetName()),
        "timeline=" .. tostring(timeline:GetName()),
        "timeline_id=" .. timeline_id(timeline),
        "fps=" .. tostring(fps),
        "start_timecode=" .. tostring(timeline:GetStartTimecode()),
        "current_timecode=" .. tostring(timeline:GetCurrentTimecode()),
        "current_relative_frame=" .. tostring(current_relative_frame(timeline, fps)),
        "venv_python_exists=" .. tostring(file_exists(VENV_PYTHON)),
        "backend_exists=" .. tostring(file_exists(BACKEND_PATH)),
        "pause_backend_exists=" .. tostring(file_exists(PAUSE_BACKEND_PATH)),
        "profile_backend_exists=" .. tostring(file_exists(PROFILE_BACKEND_PATH)),
        "ad_safety_backend_exists=" .. tostring(file_exists(AD_SAFETY_BACKEND_PATH)),
        "censor_backend_exists=" .. tostring(file_exists(CENSOR_BACKEND_PATH)),
        "ad_safety_terms_exists=" .. tostring(file_exists(AD_SAFETY_TERMS_PATH)),
        "youtube_state_exists=" .. tostring(file_exists(YOUTUBE_STATE_PATH)),
        "active_profile=" .. tostring(active_profile_name()),
        "active_profile_references=" .. tostring(active_profile_reference_count()),
        "latest_result_exists=" .. tostring(file_exists(LATEST_RESULT_PATH)),
        "accessibility_enabled=" .. tostring(accessibility_enabled()),
        "platform=" .. (IS_WINDOWS and "windows" or (IS_LINUX and "linux" or "macos")),
        "configured_ad_safety_engine=" .. tostring(cfg.ad_safety_engine),
        "configured_ad_safety_device=" .. tostring(cfg.ad_safety_device),
    }
    if file_exists(VENV_PYTHON) and file_exists(AD_SAFETY_BACKEND_PATH) then
        local probe = run_capture({
            VENV_PYTHON, AD_SAFETY_BACKEND_PATH, "--probe-runtime",
            "--engine", tostring(cfg.ad_safety_engine or "auto"),
            "--device", tostring(cfg.ad_safety_device or "auto"),
        }, true)
        if probe and tostring(probe) ~= "" then
            table.insert(lines, "whisper_runtime_probe=" .. tostring(probe):gsub("[\r\n]+", " "))
        else
            table.insert(lines, "whisper_runtime_probe=failed")
        end
    end
    local path = APP_DIR .. "/diagnostics.txt"
    write_all(path, table.concat(lines, "\n") .. "\n")
    notify("Diagnostics saved: " .. path)
end


-- ---------------------------------------------------------------------------
-- 0.12 UI bridge helpers
-- ---------------------------------------------------------------------------

local function json_escape(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\r", "\\r")
    s = s:gsub("\n", "\\n")
    s = s:gsub("\t", "\\t")
    return s
end

local function write_config_table(cfg)
    mkdir_p(APP_DIR)
    local keys = {}
    for k, _ in pairs(defaults) do table.insert(keys, k) end
    table.sort(keys)
    local lines = {"{"}
    for i, k in ipairs(keys) do
        local v = cfg[k]
        local rendered
        if type(v) == "boolean" then
            rendered = v and "true" or "false"
        elseif type(v) == "number" then
            rendered = tostring(v)
        else
            rendered = '"' .. json_escape(v) .. '"'
        end
        table.insert(lines, string.format('  "%s": %s%s', k, rendered, i < #keys and "," or ""))
    end
    table.insert(lines, "}")
    write_all(CONFIG_PATH, table.concat(lines, "\n") .. "\n")
end

function M.get_config()
    return load_config()
end

function M.save_config(patch)
    patch = patch or {}
    local cfg = load_config()
    for k, _ in pairs(defaults) do
        if patch[k] ~= nil then
            local expected = type(defaults[k])
            local value = patch[k]
            if expected == "number" then
                local n = tonumber(value)
                if not n then fail("Invalid numeric setting: " .. tostring(k)) end
                cfg[k] = n
            elseif expected == "boolean" then
                cfg[k] = value == true or tonumber(value) == 1 or tostring(value) == "true"
            else
                cfg[k] = tostring(value)
            end
        end
    end
    write_config_table(cfg)
    notify("ClipTimbre settings saved")
    return cfg
end

local function human_duration(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local total = math.floor(seconds + 0.5)
    local h = math.floor(total / 3600)
    local m = math.floor((total % 3600) / 60)
    local s = total % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

function M.get_ui_snapshot()
    local project, timeline = current_project_timeline()
    local fps = timeline and get_fps(timeline) or 0
    local duration_seconds = timeline and math.max(0, timeline_span(timeline)) / fps or 0
    local yt_problem, yt_state = "Open a timeline to scan its audio", nil
    if timeline then yt_problem, yt_state = youtube_state_problem(project, timeline, fps) end
    local report = yt_state and read_all(LATEST_AD_SAFETY_JSON_PATH) or ""
    local rows = yt_state and parse_ad_safety_tsv(LATEST_AD_SAFETY_PATH) or {}
    yt_state = yt_state or {}
    local engine = parse_string(report, "transcription_engine", "not scanned")
    local device = parse_string(report, "transcription_device", "")
    local model = parse_string(report, "runtime_model", "")
    local high = tonumber(yt_state.high_count) or 0
    local review = tonumber(yt_state.review_count) or 0
    local event_count = tonumber(yt_state.event_count) or (high + review)
    local scanned_at = tonumber(yt_state.scanned_at)
    return {
        has_timeline = not not timeline,
        project = project and tostring(project:GetName() or "") or "",
        timeline = timeline and tostring(timeline:GetName() or "") or "",
        timeline_id = timeline and timeline_id(timeline) or "",
        context_key = ui_context_key(project, timeline),
        fps = fps,
        duration_seconds = duration_seconds,
        duration_text = human_duration(duration_seconds),
        profile = active_profile_name(),
        reference_count = active_profile_reference_count(),
        youtube_valid = yt_problem == nil,
        youtube_problem = yt_problem or "",
        youtube_high = high,
        youtube_review = review,
        youtube_events = event_count,
        youtube_rows = rows,
        youtube_scanned_at = scanned_at,
        youtube_scanned_text = scanned_at and os.date("%Y-%m-%d %H:%M", scanned_at) or "Never",
        runtime_engine = engine,
        runtime_device = device,
        runtime_model = model,
        log_path = LOG_PATH,
        app_dir = APP_DIR,
    }
end

function M.get_youtube_events()
    local project, timeline = current_project_timeline()
    if not timeline or youtube_state_problem(project, timeline, get_fps(timeline)) then return {} end
    return parse_ad_safety_tsv(LATEST_AD_SAFETY_PATH)
end

function M.jump_to_youtube_seconds(seconds)
    local _, project, timeline = get_context()
    local fps = get_fps(timeline)
    validate_youtube_state(project, timeline, fps)
    local rel_frame = math.max(0, math.floor((tonumber(seconds) or 0) * fps + 0.5))
    local tc = relative_frame_to_timecode(timeline, rel_frame, fps)
    if not timeline:SetCurrentTimecode(tc) then fail("Could not move playhead to " .. tc) end
    notify("YouTube risk: " .. tc)
    return tc
end

function M.get_log_tail(max_lines)
    max_lines = math.max(20, math.floor(tonumber(max_lines) or 160))
    local txt = read_all(LOG_PATH) or ""
    local lines = {}
    for line in txt:gmatch("[^\r\n]+") do table.insert(lines, line) end
    local first = math.max(1, #lines - max_lines + 1)
    local out = {}
    for i = first, #lines do table.insert(out, lines[i]) end
    return table.concat(out, "\n")
end

function M.open_app_folder()
    mkdir_p(APP_DIR)
    if IS_WINDOWS then
        windows.open(APP_DIR)
    elseif IS_LINUX then
        os.execute("xdg-open " .. shell_quote(APP_DIR) .. " >/dev/null 2>&1 &")
    else
        os.execute("open " .. shell_quote(APP_DIR) .. " >/dev/null 2>&1 &")
    end
end

function M.open_log()
    if not file_exists(LOG_PATH) then write_all(LOG_PATH, "") end
    if IS_WINDOWS then
        windows.open(windows.system_exe("notepad.exe"), LOG_PATH)
    elseif IS_LINUX then
        os.execute("xdg-open " .. shell_quote(LOG_PATH) .. " >/dev/null 2>&1 &")
    else
        os.execute("open " .. shell_quote(LOG_PATH) .. " >/dev/null 2>&1 &")
    end
end

function M.open_ad_safety_terms()
    if not file_exists(AD_SAFETY_TERMS_PATH) then fail("Ad-safety terms file is missing") end
    if IS_WINDOWS then
        windows.open(windows.system_exe("notepad.exe"), AD_SAFETY_TERMS_PATH)
    elseif IS_LINUX then
        os.execute("xdg-open " .. shell_quote(AD_SAFETY_TERMS_PATH) .. " >/dev/null 2>&1 &")
    else
        os.execute("open -t " .. shell_quote(AD_SAFETY_TERMS_PATH) .. " >/dev/null 2>&1 &")
    end
end

local function open_url(url)
    if IS_WINDOWS then
        windows.open(url)
    else
        local opener = IS_LINUX and "xdg-open" or "open"
        os.execute(opener .. " " .. shell_quote(url) .. " >/dev/null 2>&1 &")
    end
end

function M.open_github()
    open_url(GITHUB_URL)
end

function M.open_telegram()
    open_url(TELEGRAM_URL)
end

local version_pattern = "^(%d+)%.(%d+)%.(%d+)$"

function M.open_release(version)
    if version and version:match(version_pattern) then
        open_url(GITHUB_URL .. "/releases/tag/v" .. version)
    end
end

function M.get_update_info(installed_version)
    local cache = read_kv_file(UPDATE_CACHE_PATH)
    if not cache or not cache.latest or not cache.latest:match(version_pattern) then return nil end
    local checked_at = tonumber(cache.checked_at)
    if not checked_at or checked_at < 1 or checked_at > os.time() then return nil end
    local relation
    if installed_version then
        local installed_parts = {installed_version:match(version_pattern)}
        local latest_parts = {cache.latest:match(version_pattern)}
        relation = 0
        for i = 1, 3 do
            local installed, latest = tonumber(installed_parts[i]), tonumber(latest_parts[i])
            if installed ~= latest then
                relation = installed < latest and -1 or 1
                break
            end
        end
    end
    return { latest = cache.latest, checked_at = checked_at, relation = relation }
end

local function build_ad_safety_args(source, cfg, out_tsv, out_json, status_path)
    local args = { VENV_PYTHON, AD_SAFETY_BACKEND_PATH }
    if source.kind == "manifest" then table.insert(args, "--manifest") else table.insert(args, "--audio") end
    table.insert(args, source.path)
    table.insert(args, "--input-offset")
    table.insert(args, tostring(source.input_offset or 0))
    if source.input_duration and tonumber(source.input_duration) and tonumber(source.input_duration) > 0 then
        table.insert(args, "--input-duration")
        table.insert(args, tostring(source.input_duration))
    end
    local rest = {
        "--model", tostring(cfg.ad_safety_model or "small"),
        "--language", tostring(cfg.ad_safety_language or "auto"),
        "--engine", tostring(cfg.ad_safety_engine or "auto"),
        "--device", tostring(cfg.ad_safety_device or "auto"),
        "--chunk-seconds", tostring(cfg.ad_safety_chunk_seconds or 600.0),
        "--stall-timeout-seconds", tostring(cfg.ad_safety_stall_timeout_seconds or 900.0),
        "--model-load-timeout-seconds", tostring(cfg.ad_safety_model_load_timeout_seconds or 1800.0),
        "--terms", AD_SAFETY_TERMS_PATH,
        "--output", out_tsv,
        "--output-json", out_json,
        "--status-file", status_path,
    }
    for _, a in ipairs(rest) do table.insert(args, a) end
    return args
end

local function launch_background_args(args, job)
    if windows then
        local err
        job.process, err = windows.start(windows_args(args), LOG_PATH, LOG_PATH, true)
        return job.process ~= nil, err
    end
    local runner_path = job.run_dir .. "/run.sh"
    local script = table.concat({
        "#!/bin/sh",
        shell_command(args) .. " >>" .. shell_quote(LOG_PATH) .. " 2>&1",
        "code=$?",
        "printf '%s' \"$code\" > " .. shell_quote(job.exit_path),
        "exit \"$code\"",
        "",
    }, "\n")
    write_all(runner_path, script)
    return command_ok(os.execute("/bin/sh " .. shell_quote(runner_path) .. " >/dev/null 2>&1 &"))
end

local function background_exit_code(job)
    if job.process then return windows.exit_code(job.process, false) end
    local status = read_all(job.exit_path)
    return status and tonumber(status) or nil
end

local function finish_background_job(job)
    if job.process then
        windows.close(job.process)
        job.process = nil
    end
    remove_tree(job.run_dir)
end

function M.start_update_check()
    if not file_exists(VENV_PYTHON) or not file_exists(UPDATE_BACKEND_PATH) then
        return nil, "Update checker missing. Re-run the ClipTimbre installer."
    end
    local run_dir = APP_DIR .. "/tmp/update_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    mkdir_p(run_dir)
    local job = { run_dir = run_dir, exit_path = run_dir .. "/exit_code.txt", started_at = os.time() }
    local started, err = launch_background_args({VENV_PYTHON, UPDATE_BACKEND_PATH, "--cache", UPDATE_CACHE_PATH}, job)
    if not started then
        finish_background_job(job)
        return nil, err or "Could not start the update checker."
    end
    return job
end

function M.poll_update_check(job)
    local code = background_exit_code(job)
    if code == nil and os.time() - job.started_at < 30 then return nil end
    finish_background_job(job)
    return code == 0
end

local function parse_progress_status(path)
    local txt = read_all(path)
    if not txt then return { stage = "starting", progress_seconds = 0, duration_seconds = 0 } end
    return {
        stage = parse_string(txt, "stage", "starting"),
        progress_seconds = parse_number(txt, "progress_seconds", 0),
        duration_seconds = parse_number(txt, "duration_seconds", 0),
        engine = parse_string(txt, "engine", ""),
        device = parse_string(txt, "device", ""),
        compute_type = parse_string(txt, "compute_type", ""),
        pid = parse_number(txt, "pid", nil),
        high_count = parse_number(txt, "high_count", 0),
        review_count = parse_number(txt, "review_count", 0),
    }
end

function M.start_youtube_safety_scan()
    if not file_exists(VENV_PYTHON) then fail("Python environment not found. Re-run the ClipTimbre installer") end
    if not file_exists(AD_SAFETY_BACKEND_PATH) then fail("YouTube ad-safety backend missing. Re-run the ClipTimbre installer") end
    local _, project, timeline = get_context()
    local cfg = load_config()
    local fps = get_fps(timeline)
    mkdir_p(APP_DIR .. "/tmp")
    local run_dir = APP_DIR .. "/tmp/youtube_ui_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000,9999))
    mkdir_p(run_dir)
    local source = prepare_timeline_audio_source(project, timeline, fps, run_dir, cfg)
    local job = {
        project = project,
        timeline = timeline,
        timeline_id = timeline_id(timeline),
        context_key = ui_context_key(project, timeline),
        fps = fps,
        run_dir = run_dir,
        out_tsv = run_dir .. "/ad_safety.tsv",
        out_json = run_dir .. "/ad_safety.json",
        progress_path = run_dir .. "/progress.json",
        exit_path = run_dir .. "/exit_code.txt",
        started_at = os.time(),
        source_mode = tostring(source.mode or source.kind),
        finished = false,
        cancel_requested = false,
    }
    local args = build_ad_safety_args(source, cfg, job.out_tsv, job.out_json, job.progress_path)
    log("Starting background YouTube ad-safety scan source_mode=" .. job.source_mode)
    local started, err = launch_background_args(args, job)
    if not started then
        finish_background_job(job)
        fail(err or "Could not start the YouTube scan.")
    end
    return job
end

local function stop_scan_worker(job, pid)
    pid = tonumber(pid)
    if not pid or pid <= 1 then return false end
    if IS_WINDOWS then
        windows.run({windows.system_exe("taskkill.exe"), "/PID", tostring(math.floor(pid)), "/T", "/F"})
    else
        os.execute("pkill -TERM -P " .. tostring(math.floor(pid)) .. " >/dev/null 2>&1 || true")
        os.execute("kill -TERM " .. tostring(math.floor(pid)) .. " >/dev/null 2>&1 || true")
    end
    job.cancel_signal_sent = true
    log("YouTube scan cancel requested for worker pid=" .. tostring(pid))
    return true
end

function M.cancel_youtube_safety_scan(job)
    if not job or job.finished then return false end
    job.cancel_requested = true
    local status = parse_progress_status(job.progress_path)
    if stop_scan_worker(job, status.pid) then return true end
    log("YouTube scan cancel requested before worker PID became available; poller will retry")
    return false
end

function M.poll_youtube_safety_scan(job)
    if not job then return { done = true, failed = true, error = "No scan job" } end
    if job.finished then return job.final_status or { done = true } end
    local status_exists = file_exists(job.progress_path)
    local status = parse_progress_status(job.progress_path)
    local elapsed = math.max(0, os.time() - (job.started_at or os.time()))
    local code = background_exit_code(job)
    if not status_exists and elapsed > 45 and code == nil then
        job.finished = true
        local result = { done = true, failed = true, stage = "starting", error = "Ad-safety worker did not start within 45 seconds" }
        job.final_status = result
        finish_background_job(job)
        return result
    end
    if job.cancel_requested and not job.cancel_signal_sent and status.pid then
        stop_scan_worker(job, status.pid)
    end
    local duration = tonumber(status.duration_seconds) or 0
    local progress = tonumber(status.progress_seconds) or 0
    local percent = duration > 0 and math.max(0, math.min(100, 100 * progress / duration)) or 0
    local base = {
        done = false,
        stage = status.stage,
        progress_seconds = progress,
        duration_seconds = duration,
        progress_percent = percent,
        engine = status.engine,
        device = status.device,
        pid = status.pid,
        source_mode = job.source_mode,
        elapsed_seconds = elapsed,
        cancel_requested = job.cancel_requested == true,
    }
    if code == nil then return base end
    if code ~= 0 or job.cancel_requested then
        job.finished = true
        local cancelled = job.cancel_requested == true
        local result = {
            done = true,
            failed = not cancelled,
            cancelled = cancelled,
            exit_code = code,
            stage = status.stage,
            error = cancelled and "Scan cancelled" or ("Ad-safety worker failed with exit code " .. tostring(code)),
        }
        job.final_status = result
        finish_background_job(job)
        return result
    end

    local ok, err = pcall(function()
        if ui_context_key(job.project, job.timeline) ~= job.context_key then
            fail("Timeline changed during scan. Run the scan again.")
        end
        local events = parse_ad_safety_tsv(job.out_tsv)
        local cfg = load_config()
        local added, high_count, review_count = add_ad_safety_markers(job.timeline, job.fps, events, cfg)
        copy_file(job.out_tsv, LATEST_AD_SAFETY_PATH)
        copy_file(job.out_json, LATEST_AD_SAFETY_JSON_PATH)
        write_youtube_state(job.project, job.timeline, job.fps, events)
        job.result = { added = added, high_count = high_count, review_count = review_count, event_count = #events }
        notify(string.format("YouTube scan: %d markers (%d high, %d review).", added, high_count, review_count))
    end)
    job.finished = true
    local result
    if ok then
        result = {
            done = true,
            failed = false,
            stage = "complete",
            added = job.result.added,
            high_count = job.result.high_count,
            review_count = job.result.review_count,
            event_count = job.result.event_count,
            engine = status.engine,
            device = status.device,
        }
    else
        result = { done = true, failed = true, stage = "finalizing", error = tostring(err) }
    end
    job.final_status = result
    finish_background_job(job)
    return result
end

return M
