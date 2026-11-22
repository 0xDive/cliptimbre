-- ClipTimbre 0.16.0 launcher for DaVinci Resolve.
-- GNU AGPL version 3 only. See LICENSE and LICENSE-RESOLVE-EXCEPTION.md.

local PATH_SEP = package.config:sub(1, 1)
local IS_WINDOWS = PATH_SEP == "\\"
local home = IS_WINDOWS and (os.getenv("USERPROFILE") or os.getenv("HOME") or "") or (os.getenv("HOME") or os.getenv("USERPROFILE") or "")
local data_dir = os.getenv("STREAMER_VOICE_DATA_DIR") or home .. "/.streamer_voice"
local common_path = data_dir .. "/resolve/streamer_voice_common.lua"

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

if not file_exists(common_path) then
    error("ClipTimbre backend is not installed: " .. common_path)
end

local sv = assert(loadfile(common_path))(data_dir)
local app = rawget(_G, "resolve")
if not app and bmd and bmd.scriptapp then app = bmd.scriptapp("Resolve") end
if not app then error("DaVinci Resolve scripting object is unavailable") end

local fu = rawget(_G, "fusion") or rawget(_G, "fu")
if not fu then pcall(function() fu = app:Fusion() end) end
if not fu and bmd and bmd.scriptapp then pcall(function() fu = bmd.scriptapp("Fusion") end) end
if not fu or not fu.UIManager then error("Fusion UIManager is unavailable") end

local ui = fu.UIManager
local disp = bmd.UIDispatcher(ui)

local ROOT_STYLE = [[
QWidget { background-color:#17191c; color:#e9edf2; font-size:12px; }
QLabel { background-color:transparent; }
QPushButton { background-color:#25292f; border:1px solid #363b43; border-radius:5px; padding:7px 12px; color:#e9edf2; }
QPushButton:hover { background-color:#30353d; border-color:#4c535e; }
QPushButton:pressed { background-color:#1f2227; }
QPushButton:disabled { color:#6f7782; background-color:#202328; }
QLineEdit, QComboBox, QTextEdit { background-color:#202328; border:1px solid #363b43; border-radius:4px; padding:5px 7px; color:#e9edf2; selection-background-color:#3977b8; }
QTreeWidget { background-color:#1c1f23; alternate-background-color:#20242a; border:1px solid #363b43; color:#e9edf2; outline:0; }
QHeaderView::section { background-color:#25292f; color:#b8c0ca; border:0; border-right:1px solid #363b43; padding:6px; }
QCheckBox { spacing:6px; }
]]

local STYLE_TITLE = "font-size:21px; font-weight:600; color:#f1f4f7;"
local STYLE_PAGE_TITLE = "font-size:18px; font-weight:600; color:#f1f4f7;"
local STYLE_SECTION = "font-size:14px; font-weight:600; color:#e9edf2; padding-top:2px;"
local STYLE_MUTED = "font-size:12px; color:#9ca6b2;"
local STYLE_MICRO = "font-size:11px; color:#8f99a5;"
local STYLE_VALUE = "font-size:14px; font-weight:600; color:#e9edf2; background-color:#202328; border:1px solid #363b43; border-radius:6px; padding:8px 10px;"
local STYLE_ACCENT_BUTTON = "QPushButton { background-color:#147fc4; border:1px solid #2497da; border-radius:5px; padding:8px 13px; font-weight:600; color:white; } QPushButton:hover { background-color:#198ed7; } QPushButton:disabled { background-color:#22272d; border-color:#363b43; color:#788390; }"
local STYLE_DANGER_BUTTON = "QPushButton { background-color:#42272a; border:1px solid #734047; border-radius:5px; padding:7px 11px; color:#f0c3c7; } QPushButton:hover { background-color:#533036; } QPushButton:disabled { background-color:#22272d; border-color:#363b43; color:#788390; }"
local STYLE_NAV = "QPushButton { padding:7px 11px; border:0; border-bottom:2px solid transparent; border-radius:0; background-color:transparent; color:#aeb7c2; } QPushButton:hover { background-color:#202328; color:#ffffff; }"
local STYLE_NAV_ACTIVE = "QPushButton { padding:7px 11px; border:0; border-bottom:2px solid #4aa6e8; border-radius:0; background-color:#202328; color:#ffffff; font-weight:600; }"
local STYLE_SUCCESS = "font-size:13px; font-weight:600; color:#65c466;"
local STYLE_WARN = "font-size:13px; font-weight:600; color:#e6b94c;"
local STYLE_ERROR = "font-size:13px; font-weight:600; color:#e06464;"

local function separator(id)
    return ui:Label {
        ID = id,
        Text = "",
        MinimumSize = { 1, 1 },
        MaximumSize = { 16777215, 1 },
        StyleSheet = "background-color:#2b2f35;",
        Weight = 0,
    }
end

local win = disp:AddWindow({
    ID = "ClipTimbreWindow",
    WindowTitle = "ClipTimbre",
    Geometry = {120, 72, 842, 780},
    Spacing = 0,
    StyleSheet = ROOT_STYLE,
}, ui:VGroup {
    ID = "DialogContent",
    -- The Resolve window provides its own inset. Group margins can offset
    -- child controls without reducing their allocation in Fusion UIManager.
    Spacing = 6,

    ui:VGroup {
        ID = "Header",
        Weight = 0,

        Spacing = 2,
        ui:Label { ID = "HeaderTitle", Text = "ClipTimbre", StyleSheet = STYLE_TITLE, Weight = 0 },
        ui:Label { ID = "HeaderRuntime", Text = "v0.16.0", StyleSheet = STYLE_MUTED, Weight = 0 },
        ui:Label { ID = "HeaderContext", Text = "", StyleSheet = STYLE_MICRO, WordWrap = true, Weight = 0 },
    },

    ui:HGroup {
        ID = "Navigation",
        Weight = 0,

        Spacing = 4,
        ui:Button { ID = "NavDashboard", Text = "Dashboard", StyleSheet = STYLE_NAV_ACTIVE, Weight = 0 },
        ui:Button { ID = "NavVoice", Text = "Voice", StyleSheet = STYLE_NAV, Weight = 0 },
        ui:Button { ID = "NavPauses", Text = "Pauses", StyleSheet = STYLE_NAV, Weight = 0 },
        ui:Button { ID = "NavYouTube", Text = "YouTube", StyleSheet = STYLE_NAV, Weight = 0 },
        ui:Button { ID = "NavSettings", Text = "Settings", StyleSheet = STYLE_NAV, Weight = 0 },
        ui:Button { ID = "NavDiagnostics", Text = "Diagnostics", StyleSheet = STYLE_NAV, Weight = 0 },
        ui:HGap(0, 1),
    },

    separator("TopSeparator"),

    ui:Stack {
        ID = "PageStack",
        CurrentIndex = 0,
        Weight = 1,

        -- DASHBOARD ------------------------------------------------------
        ui:VGroup {
            ID = "DashboardPage",

            Spacing = 10,
            ui:Label { Text = "Overview", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },

            ui:HGroup {
                Weight = 0,
                Spacing = 10,
                ui:VGroup {
                    Weight = 2,
                    Spacing = 4,
                    ui:Label { Text = "TIMELINE", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:Label { ID = "CardTimeline", Text = "—", StyleSheet = STYLE_VALUE, Weight = 0 },
                    ui:Label { ID = "CardDuration", Text = "—", StyleSheet = STYLE_MUTED, Weight = 0 },
                },
                ui:VGroup {
                    Weight = 1,
                    Spacing = 4,
                    ui:Label { Text = "VOICE PROFILE", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:Label { ID = "CardProfile", Text = "—", StyleSheet = STYLE_VALUE, Weight = 0 },
                    ui:Label { ID = "CardReferences", Text = "—", StyleSheet = STYLE_MUTED, Weight = 0 },
                },
            },

            ui:VGroup {
                Weight = 0,
                Spacing = 4,
                ui:Label { Text = "YOUTUBE SAFETY", StyleSheet = STYLE_MICRO, Weight = 0 },
                ui:Label { ID = "CardYouTube", Text = "Not scanned", StyleSheet = STYLE_VALUE, Weight = 0 },
                ui:Label { ID = "CardYouTubeMeta", Text = "—", StyleSheet = STYLE_MUTED, Weight = 0 },
            },

            ui:HGroup {
                Weight = 0,
                Spacing = 7,
                ui:Button { ID = "DashScanYouTube", Text = "Scan YouTube Safety", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
                ui:Button { ID = "DashFindVoice", Text = "Find voice", Weight = 0 },
                ui:Button { ID = "DashSetReference", Text = "Set Voice Reference", Weight = 0 },
                ui:HGap(0, 1),
            },

            separator("DashSeparator"),
            ui:HGroup {
                Weight = 0,
                Spacing = 10,
                ui:VGroup {
                    Weight = 1,
                    Spacing = 3,
                    ui:Label { Text = "YouTube scan", StyleSheet = STYLE_SECTION, Weight = 0 },
                    ui:Label { ID = "DashScanStage", Text = "Idle", StyleSheet = STYLE_MUTED, Weight = 0 },
                    ui:Label { ID = "DashProgressText", Text = "", StyleSheet = STYLE_MUTED, Weight = 0 },
                },
                ui:Label { ID = "DashProgressBar", Text = "0%", StyleSheet = "font-size:18px; font-weight:600; color:#4aa6e8;", Weight = 0 },
            },
            ui:VGap(0, 1),
        },

        -- VOICE ----------------------------------------------------------
        ui:VGroup {
            ID = "VoicePage",

            Spacing = 10,
            ui:Label { Text = "Voice", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },
            ui:Label { Text = "Find your voice across an already-cut timeline and maintain a reusable voice profile.", StyleSheet = STYLE_MUTED, Weight = 0 },

            ui:Label { Text = "Reference", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:Label { Text = "Place the playhead on clean speech, save a reference, then scan.", StyleSheet = STYLE_MUTED, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "SetReference", Text = "Set temporary reference", Weight = 0 },
                ui:Button { ID = "FindStreamer", Text = "Find streamer voice", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
                ui:HGap(0, 1),
            },

            ui:Label { Text = "Results", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "PrevStreamer", Text = "Previous", Weight = 0 },
                ui:Button { ID = "NextStreamer", Text = "Next", Weight = 0 },
                ui:Button { ID = "ClearStreamer", Text = "Clear markers", Weight = 0 },
                ui:HGap(0, 1),
            },

            separator("VoiceSeparator"),
            ui:Label { Text = "Voice profile", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:ComboBox {
                    ID = "ProfileChoice", Events = { Activated = true },
                    ToolTip = "Choose a saved voice profile", Weight = 1,
                },
                ui:Button { ID = "ProfileStatus", Text = "Profile status", Weight = 0 },
            },
            ui:Label { ID = "VoiceProfileSummary", Text = "—", StyleSheet = STYLE_MUTED, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:LineEdit { ID = "NewProfileName", PlaceholderText = "New profile name", Weight = 1 },
                ui:Button { ID = "CreateProfile", Text = "Create profile", Enabled = false, Weight = 0 },
            },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "AddSample", Text = "Add voice sample", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
                ui:HGap(0, 1),
            },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "Correct", Text = "Correct match", Weight = 0 },
                ui:Button { ID = "Wrong", Text = "Wrong match", Weight = 0 },
                ui:Button { ID = "ClearSamples", Text = "Clear samples", StyleSheet = STYLE_DANGER_BUTTON, Weight = 0 },
                ui:HGap(0, 1),
            },
            ui:VGap(0, 1),
        },

        -- PAUSES ---------------------------------------------------------
        ui:VGroup {
            ID = "PausesPage",

            Spacing = 10,
            ui:Label { Text = "Pauses", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },
            ui:Label { Text = "Find pauses inside your detected speech and navigate them quickly.", StyleSheet = STYLE_MUTED, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "MarkPauses", Text = "Mark pauses", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
                ui:Button { ID = "TightenPauses", Text = "Tighten short pauses", Weight = 0 },
                ui:HGap(0, 1),
            },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "PrevPause", Text = "Previous pause", Weight = 0 },
                ui:Button { ID = "NextPause", Text = "Next pause", Weight = 0 },
                ui:Button { ID = "ClearPauses", Text = "Clear markers", Weight = 0 },
                ui:HGap(0, 1),
            },
            separator("PauseSeparator"),
            ui:Label { Text = "Long pauses remain marked for manual review. Tightening uses a safety-copy workflow where supported.", StyleSheet = STYLE_MUTED, Weight = 0 },
            ui:VGap(0, 1),
        },

        -- YOUTUBE --------------------------------------------------------
        -- Intentionally single-column. No side panel, no Tree max-height,
        -- no controls layered beside a flexible widget.
        ui:VGroup {
            ID = "YouTubePage",

            Spacing = 7,
            ui:Label { Text = "YouTube Safety", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },
            ui:HGroup {
                Weight = 0,
                Spacing = 8,
                ui:Button { ID = "ScanYouTube", Text = "Scan timeline", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
                ui:Label { ID = "YTCountHigh", Text = "HIGH 0", StyleSheet = "font-size:13px; font-weight:600; color:#f58cba;", Weight = 0 },
                ui:Label { ID = "YTCountReview", Text = "REVIEW 0", StyleSheet = "font-size:13px; font-weight:600; color:#54d4de;", Weight = 0 },
                ui:Label { ID = "YTCountPersonal", Text = "PERSONAL 0", StyleSheet = "font-size:13px; font-weight:600; color:#f0a24d;", Weight = 0 },
                ui:HGap(0, 1),
            },

            ui:HGroup {
                Weight = 0,
                Spacing = 8,
                ui:Label { ID = "YTScanRuntime", Text = "Runtime: —", StyleSheet = STYLE_MUTED, Weight = 0 },
                ui:Label { ID = "YTProgressBar", Text = "0%", StyleSheet = "font-weight:600; color:#4aa6e8;", Weight = 0 },
                ui:Label { ID = "YTProgressText", Text = "Idle", StyleSheet = STYLE_MUTED, WordWrap = true, Weight = 1 },
            },

            -- Dedicated YouTube marker palette; no overlap with voice/pauses.
            ui:HGroup { Weight = 0, Spacing = 12,
                ui:Label { Text = "● REVIEW", StyleSheet = "color:#54d4de; font-size:11px;", Weight = 0 },
                ui:Label { Text = "● HIGH", StyleSheet = "color:#f58cba; font-size:11px;", Weight = 0 },
                ui:Label { Text = "● PERSONAL", StyleSheet = "color:#f0a24d; font-size:11px;", Weight = 0 },
                ui:Label { Text = "● MUTED", StyleSheet = "color:#dc80ea; font-size:11px;", Weight = 0 },
                ui:HGap(0, 1),
            },

            ui:HGroup {
                Weight = 0,
                Spacing = 6,
                ui:LineEdit { ID = "YTSearch", PlaceholderText = "Filter risks…", Weight = 1 },
                ui:ComboBox { ID = "YTSeverityFilter", Weight = 0 },
                ui:Button { ID = "YTRefreshResults", Text = "Refresh", Weight = 0 },
            },

            ui:Tree {
                ID = "YTRisks",
                SortingEnabled = false,
                AlternatingRowColors = true,
                Events = { ItemClicked = true, ItemDoubleClicked = true },
                Weight = 1,
            },

            ui:TextEdit {
                ID = "YTSelectionDetails",
                ReadOnly = true,
                MinimumSize = { 0, 54 },
                MaximumSize = { 16777215, 54 },
                StyleSheet = STYLE_MUTED,
                Weight = 0,
            },

            ui:HGroup {
                Weight = 0,
                Spacing = 6,
                ui:Button { ID = "PrevYouTube", Text = "Previous", Weight = 0 },
                ui:Button { ID = "NextYouTube", Text = "Next", Weight = 0 },
                ui:Button { ID = "ClearYouTube", Text = "Clear markers", Weight = 0 },
                ui:HGap(0, 1),
            },

            separator("YTSeparator"),
            ui:HGroup {
                Weight = 0,
                Spacing = 8,
                ui:Label { Text = "Auto Censor", StyleSheet = STYLE_SECTION, Weight = 0 },
                ui:Label { Text = "Mode", StyleSheet = STYLE_MICRO, Weight = 0 },
                ui:ComboBox { ID = "CensorMode", ToolTip = "Timeline Mute keeps source clips/tracks and leaves visible gaps; Smooth Mute/Beep create a processed mix.", Weight = 0 },
                ui:CheckBox { ID = "CensorHigh", Text = "HIGH", Checked = true, Weight = 0 },
                ui:CheckBox { ID = "CensorReview", Text = "REVIEW", Checked = true, Weight = 0 },
                ui:HGap(0, 1),
                ui:Button { ID = "AutoCensor", Text = "Create censored copy", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
            },
            ui:HGroup {
                Weight = 0,
                Spacing = 10,
                ui:Label { Text = "Categories", StyleSheet = STYLE_MICRO, Weight = 0 },
                ui:CheckBox { ID = "CensorPersonal", Text = "Personal insults", Checked = true,
                    ToolTip = "Person-directed insults such as 'ты еблан' (HIGH) or ambiguous insults requiring review.", Weight = 0 },
                ui:CheckBox { ID = "CensorProfanity", Text = "Profanity", Checked = true,
                    ToolTip = "All remaining profanities, including interjections (e.g. 'блять').", Weight = 0 },
                ui:CheckBox { ID = "CensorHate", Text = "Slurs / Hate", Checked = true, Weight = 0 },
                ui:HGap(0, 1),
            },
            ui:HGroup {
                Weight = 0,
                Spacing = 10,
                ui:Label { Text = "More", StyleSheet = STYLE_MICRO, Weight = 0 },
                ui:CheckBox { ID = "CensorSexualDrugs", Text = "Sexual / Drugs", Checked = false, Weight = 0 },
                ui:CheckBox { ID = "CensorViolence", Text = "Violence / Self-harm", Checked = false, Weight = 0 },
                ui:CheckBox { ID = "CensorOther", Text = "Fraud / Terrorism", Checked = false, Weight = 0 },
                ui:HGap(0, 1),
            },
        },

        -- SETTINGS -------------------------------------------------------
        ui:VGroup {
            ID = "SettingsPage",

            Spacing = 9,
            ui:Label { Text = "Settings", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },
            ui:Label { Text = "", StyleSheet = STYLE_MUTED, Weight = 0 },

            ui:Label { Text = "YouTube transcription", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 10,
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Model", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:ComboBox { ID = "SettingModel", ToolTip = "Whisper model. Small is the recommended speed/accuracy balance.", Weight = 0 },
                },
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Language", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:ComboBox { ID = "SettingLanguage", ToolTip = "Force a language or let Whisper detect it automatically.", Weight = 0 },
                },
            },
            ui:HGroup {
                Weight = 0, Spacing = 10,
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Engine", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:ComboBox { ID = "SettingEngine", ToolTip = "Auto selects MLX/Metal on Apple Silicon and CUDA on supported Windows systems.", Weight = 0 },
                },
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Chunk length (sec)", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:LineEdit { ID = "SettingChunk", ToolTip = "Audio processed per Whisper chunk. 600 seconds is a safe default.", Weight = 0 },
                },
            },
            ui:Label { ID = "SettingEngineRuntime", Text = "Current runtime: —", StyleSheet = STYLE_MICRO, Weight = 0 },

            separator("SettingsSeparator1"),
            ui:Label { Text = "Voice + Auto Censor", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 10,
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Voice threshold", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:LineEdit { ID = "SettingThreshold", ToolTip = "Higher values are stricter when deciding whether speech belongs to your voice profile.", Weight = 0 },
                },
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Pad before (sec)", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:LineEdit { ID = "SettingPadBefore", ToolTip = "Extra censor time before a matched word so consonants do not leak through.", Weight = 0 },
                },
            },
            ui:HGroup {
                Weight = 0, Spacing = 10,
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Pad after (sec)", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:LineEdit { ID = "SettingPadAfter", ToolTip = "Extra censor time after a matched word so word endings do not leak through.", Weight = 0 },
                },
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Beep frequency (Hz)", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:LineEdit { ID = "SettingBeepHz", ToolTip = "Frequency of the censor tone in Beep mode.", Weight = 0 },
                },
            },
            ui:HGroup {
                Weight = 0, Spacing = 10,
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Beep level (dB)", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:LineEdit { ID = "SettingBeepDb", ToolTip = "Level of the censor tone. -12 dB is a comfortable default.", Weight = 0 },
                },
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Censor fade (ms)", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:LineEdit { ID = "SettingCensorFade", ToolTip = "Smooth fade down/up around mute or beep. 60–100 ms avoids hard cuts.", Weight = 0 },
                },
            },
            ui:HGroup {
                Weight = 0, Spacing = 10,
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { Text = "Source under beep (dB)", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:LineEdit { ID = "SettingBeepDuck", ToolTip = "How far the original audio is ducked under the beep. -36 dB masks speech while keeping ambience.", Weight = 0 },
                },
                ui:VGroup { Weight = 1, Spacing = 3,
                    ui:Label { ID = "SettingsMixNote", Text = "Beep and Smooth Mute use one mix.", StyleSheet = STYLE_MICRO, Weight = 0 },
                    ui:Label { ID = "SettingsTracksNote", Text = "Timeline Mute keeps separate tracks.", StyleSheet = STYLE_MICRO, Weight = 0 },
                },
            },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "SaveSettings", Text = "Save settings", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
                ui:Button { ID = "EditTerms", Text = "Edit risk rules", Weight = 0 },
                ui:HGap(0, 1),
            },
            ui:Label { ID = "SettingsStatus", Text = "", StyleSheet = STYLE_MUTED, Weight = 0 },
            ui:VGap(0, 1),
        },

        -- DIAGNOSTICS ----------------------------------------------------
        ui:VGroup {
            ID = "DiagnosticsPage",

            Spacing = 8,
            ui:Label { Text = "Diagnostics", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },
            ui:Label { ID = "DiagnosticsSummary", Text = "", StyleSheet = STYLE_MUTED, WordWrap = true, Weight = 0 },
            ui:HGroup {
                Weight = 0,
                Spacing = 6,
                ui:Button { ID = "Diagnostics", Text = "Run diagnostics", Weight = 0 },
                ui:Button { ID = "RefreshLog", Text = "Refresh log", Weight = 0 },
                ui:Button { ID = "OpenLog", Text = "Open log", Weight = 0 },
                ui:Button { ID = "OpenData", Text = "Open data folder", Weight = 0 },
                ui:Button { ID = "ClearCache", Text = "Clear cache", Weight = 0 },
                ui:HGap(0, 1),
            },
            ui:TextEdit {
                ID = "LogView",
                ReadOnly = true,
                Weight = 1,
                StyleSheet = "background-color:#15171a; color:#c9d1d9; font-family:monospace; font-size:11px; border:1px solid #363b43;",
            },
        },
    },

    separator("FooterSeparator"),
    ui:HGroup {
        ID = "FooterBar",
        Weight = 0,

        Spacing = 8,
        ui:Label { ID = "FooterDot", Text = "●", StyleSheet = STYLE_SUCCESS, Weight = 0 },
        ui:Label { ID = "FooterStatus", Text = "Ready", StyleSheet = STYLE_MUTED, WordWrap = true, Weight = 1 },
        ui:Button { ID = "Refresh", Text = "Refresh", Weight = 0 },
        ui:Button { ID = "Close", Text = "Close", Weight = 0 },
    },
})
local itm = win:GetItems()
local scan_timer = ui:Timer { ID = "ScanTimer", Interval = 1000, SingleShot = true }
local context_timer = ui:Timer { ID = "ContextTimer", Interval = 1200, SingleShot = false }
local active_scan = nil
local busy = false
local selected_page = 0
local risk_item_events = {}
local cached_events = {}
local risk_empty_message = "Open a timeline to scan its audio."
local profile_choices = {}
local selected_profile = ""
local timeline_controls = {
    "DashScanYouTube", "DashFindVoice", "DashSetReference", "SetReference", "FindStreamer",
    "PrevStreamer", "NextStreamer", "ClearStreamer", "AddSample", "Correct", "Wrong",
    "MarkPauses", "TightenPauses", "PrevPause", "NextPause", "ClearPauses", "ScanYouTube",
    "PrevYouTube", "NextYouTube", "ClearYouTube", "AutoCensor", "Diagnostics",
}
local timeline_available = false
local last_context_key = nil

local PAGE_IDS = {
    { button = "NavDashboard", page = "DashboardPage", index = 0 },
    { button = "NavVoice", page = "VoicePage", index = 1 },
    { button = "NavPauses", page = "PausesPage", index = 2 },
    { button = "NavYouTube", page = "YouTubePage", index = 3 },
    { button = "NavSettings", page = "SettingsPage", index = 4 },
    { button = "NavDiagnostics", page = "DiagnosticsPage", index = 5 },
}

local function set_page(index)
    selected_page = index
    itm.PageStack.CurrentIndex = index
    for _, entry in ipairs(PAGE_IDS) do
        local active = entry.index == index
        -- Some Resolve builds leave inactive stack pages visible.
        itm[entry.page].Visible = active
        itm[entry.button].StyleSheet = active and STYLE_NAV_ACTIVE or STYLE_NAV
    end
    pcall(function() itm.PageStack:Update() end)

    if index == 5 then
        pcall(function() itm.LogView.PlainText = sv.get_log_tail(220) end)
    end
end

local function is_checked(item)
    local v = item and item.Checked
    return v == true or tonumber(v) == 1
end

local function format_clock(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format("%02d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

local CATEGORY_NAMES = {
    strong_profanity = "Strong profanity",
    moderate_profanity = "Profanity",
    directed_insult = "Personal insult",
    hate_or_slur = "Slur / hate",
    sexual_content = "Sexual content",
    sexual_violence_or_child_abuse = "Sexual violence / child abuse",
    drugs = "Drugs",
    graphic_violence = "Graphic violence",
    violence = "Violence",
    self_harm = "Self-harm",
    weapons = "Weapons",
    dishonest_behavior = "Fraud / hacking",
    terrorism = "Terrorism",
    frequent_profanity = "Frequent profanity",
}

local function pretty_category(name)
    return CATEGORY_NAMES[tostring(name or "")] or tostring(name or "risk"):gsub("_", " ")
end

local function compact_context(value, max_chars)
    local text = tostring(value or ""):gsub("[\r\n]+", " "):gsub("%s+", " ")
    max_chars = max_chars or 190
    local chars = 0
    for offset in text:gmatch("()[%z\1-\127\194-\244]") do
        chars = chars + 1
        if chars > max_chars then return text:sub(1, offset - 1) .. "…" end
    end
    return text
end

local function progress_bar(percent, width)
    width = width or 24
    percent = math.max(0, math.min(100, tonumber(percent) or 0))
    local filled = math.floor(width * percent / 100 + 0.5)
    return string.rep("━", filled) .. string.rep("─", math.max(0, width - filled)) .. string.format("  %3.0f%%", percent)
end

local STAGE_NAMES = {
    starting = "Preparing audio",
    runtime_selection = "Selecting runtime",
    loading_model = "Loading Whisper model",
    transcribing = "Transcribing audio",
    runtime_fallback = "Switching runtime",
    matching_rules = "Checking risk rules",
    complete = "Complete",
    finalizing = "Adding timeline markers",
}

local function stage_name(stage)
    return STAGE_NAMES[tostring(stage or "")] or tostring(stage or "Working")
end

local function refresh_risk_tree()
    local query = tostring(itm.YTSearch.Text or ""):lower()
    local severity_filter = tostring(itm.YTSeverityFilter.CurrentText or "All")
    itm.YTRisks:Clear()
    risk_item_events = {}
    local shown = 0
    for _, e in ipairs(cached_events or {}) do
        local sev = tostring(e.severity or "review")
        local blob = (tostring(e.phrase or "") .. " " .. tostring(e.context or "") .. " " .. tostring(e.category or "")):lower()
        local sev_ok = severity_filter == "All" or severity_filter:lower() == sev
        local q_ok = query == "" or blob:find(query, 1, true) ~= nil
        if sev_ok and q_ok then
            local row = itm.YTRisks:NewItem()
            row.Text[0] = format_clock(e.start)
            row.Text[1] = sev:upper()
            row.Text[2] = pretty_category(e.category)
            row.Text[3] = tostring(e.phrase or "")
            row.ToolTip[3] = row.Text[3]
            row.WhatsThis[0] = tostring(shown + 1)
            itm.YTRisks:AddTopLevelItem(row)
            shown = shown + 1
            risk_item_events[shown] = e
        end
    end
    itm.YTSelectionDetails.PlainText = shown > 0 and "Select a risk to read its context. Double-click to jump to the timeline."
        or (#cached_events > 0 and "No risks match the current filter." or risk_empty_message)
end

local function show_active_profile(name)
    selected_profile = name
    local index = -1
    for i, candidate in ipairs(profile_choices) do
        if candidate == name then index = i - 1; break end
    end
    itm.ProfileChoice.CurrentIndex = index
    itm.ProfileChoice.ToolTip = index >= 0 and name or "Choose a saved voice profile"
end

local function refresh_profiles()
    local names, active = sv.list_profiles()
    profile_choices = names
    itm.ProfileChoice:Clear()
    for _, name in ipairs(names) do itm.ProfileChoice:AddItem(name) end
    itm.ProfileChoice.Enabled = #names > 0
    show_active_profile(active)
end

local function load_settings()
    local cfg = sv.get_config()
    local model_index = { tiny = 0, base = 1, small = 2, medium = 3 }
    local language_index = { auto = 0, ru = 1, en = 2 }
    local engine_index = { auto = 0, mlx = 1, ["torch-whisper"] = 2, ["faster-whisper"] = 3 }
    itm.SettingModel.CurrentIndex = model_index[tostring(cfg.ad_safety_model or "small")] or 2
    itm.SettingLanguage.CurrentIndex = language_index[tostring(cfg.ad_safety_language or "auto")] or 0
    itm.SettingEngine.CurrentIndex = engine_index[tostring(cfg.ad_safety_engine or "auto")] or 0
    itm.SettingChunk.Text = tostring(cfg.ad_safety_chunk_seconds or 600)
    itm.SettingThreshold.Text = tostring(cfg.threshold or 0.35)
    itm.SettingPadBefore.Text = tostring(cfg.youtube_censor_pad_before_seconds or 0.08)
    itm.SettingPadAfter.Text = tostring(cfg.youtube_censor_pad_after_seconds or 0.12)
    itm.SettingBeepHz.Text = tostring(cfg.youtube_censor_beep_hz or 1000)
    itm.SettingBeepDb.Text = tostring(cfg.youtube_censor_beep_db or -12.0)
    itm.SettingCensorFade.Text = tostring(cfg.youtube_censor_fade_ms or 70.0)
    itm.SettingBeepDuck.Text = tostring(cfg.youtube_censor_beep_duck_db or -36.0)
end

local function update_snapshot(message)
    local ok, snap = pcall(sv.get_ui_snapshot)
    if not ok then
        last_context_key = nil
        timeline_available = false
        for _, id in ipairs(timeline_controls) do itm[id].Enabled = false end
        cached_events = {}
        risk_empty_message = "Could not read the current timeline."
        refresh_risk_tree()
        itm.YTCountHigh.Text = "HIGH 0"
        itm.YTCountReview.Text = "REVIEW 0"
        itm.YTCountPersonal.Text = "PERSONAL 0"
        itm.CardYouTube.Text = "Timeline unavailable"
        itm.CardYouTubeMeta.Text = ""
        itm.HeaderRuntime.Text = "v0.16.0"
        itm.YTScanRuntime.Text = "Runtime: unavailable"
        itm.SettingEngineRuntime.Text = "Current runtime: unavailable"
        itm.FooterDot.StyleSheet = STYLE_ERROR
        itm.FooterStatus.Text = "Context error: " .. tostring(snap)
        return
    end
    local changed = snap.context_key ~= last_context_key
    timeline_available = snap.has_timeline
    last_context_key = snap.context_key
    for _, id in ipairs(timeline_controls) do
        itm[id].Enabled = timeline_available
    end
    itm.ScanYouTube.Enabled = timeline_available or active_scan ~= nil
    itm.DashScanYouTube.Enabled = itm.ScanYouTube.Enabled
    itm.AutoCensor.Enabled = timeline_available and not active_scan
    if changed then
        itm.YTProgressBar.Text = "0%"
        itm.DashProgressBar.Text = "0%"
        itm.YTProgressText.Text = "Idle"
        itm.DashProgressText.Text = ""
        itm.DashScanStage.Text = "Idle"
    end
    itm.HeaderContext.Text = timeline_available and
        compact_context(snap.project .. "  /  " .. snap.timeline, 72) or "Open a timeline in Resolve to start editing"
    local rt = tostring(snap.runtime_engine or "not scanned")
    if tostring(snap.runtime_device or "") ~= "" then rt = rt .. " / " .. tostring(snap.runtime_device) end
    itm.HeaderRuntime.Text = "Runtime: " .. rt .. "  •  v0.16.0"
    itm.CardTimeline.Text = timeline_available and compact_context(snap.timeline, 36) or "No timeline open"
    itm.CardTimeline.ToolTip = snap.timeline
    itm.CardDuration.Text = timeline_available and string.format("%s  •  %.3g fps", snap.duration_text, snap.fps) or ""
    itm.CardProfile.Text = compact_context(snap.profile, 24)
    itm.CardProfile.ToolTip = snap.profile
    itm.CardReferences.Text = tostring(snap.reference_count) .. " voice sample(s)"
    itm.VoiceProfileSummary.Text = string.format("%d voice sample(s)", snap.reference_count)
    if snap.profile ~= selected_profile then show_active_profile(snap.profile) end

    cached_events = snap.youtube_rows
    risk_empty_message = not timeline_available and "Open a timeline to scan its audio."
        or (snap.youtube_valid and "No risks found in this scan." or "Scan this timeline to see its results.")
    refresh_risk_tree()

    if not timeline_available then
        itm.CardYouTube.Text = "No timeline open"
        itm.CardYouTube.StyleSheet = STYLE_MUTED
        itm.CardYouTubeMeta.Text = ""
    elseif snap.youtube_valid then
        itm.CardYouTube.Text = string.format("%d HIGH / %d REVIEW", snap.youtube_high, snap.youtube_review)
        itm.CardYouTube.StyleSheet = snap.youtube_high > 0 and STYLE_ERROR or (snap.youtube_review > 0 and STYLE_WARN or STYLE_SUCCESS)
        itm.CardYouTubeMeta.Text = "Last scan: " .. tostring(snap.youtube_scanned_text)
    else
        itm.CardYouTube.Text = "Not scanned"
        itm.CardYouTube.StyleSheet = STYLE_WARN
        itm.CardYouTubeMeta.Text = tostring(snap.youtube_problem ~= "" and snap.youtube_problem or "Run YouTube Safety scan")
    end
    itm.YTCountHigh.Text = "HIGH " .. tostring(snap.youtube_high)
    itm.YTCountReview.Text = "REVIEW " .. tostring(snap.youtube_review)
    local personal_count = 0
    if snap.youtube_valid then
        for _, event in ipairs(cached_events or {}) do
            if tostring(event.category or "") == "directed_insult" then personal_count = personal_count + 1 end
        end
    end
    itm.YTCountPersonal.Text = "PERSONAL " .. tostring(personal_count)
    itm.YTScanRuntime.Text = "Runtime: " .. rt
    itm.SettingEngineRuntime.Text = "Current runtime: " .. rt
    itm.DiagnosticsSummary.Text = compact_context(string.format("%s · %s (%d samples) · %d high / %d review · %s",
        snap.timeline, snap.profile, snap.reference_count, snap.youtube_high, snap.youtube_review, rt), 120)
    if message then itm.FooterStatus.Text = timeline_available and message or "No timeline open" end
    itm.FooterDot.StyleSheet = timeline_available and STYLE_SUCCESS or STYLE_MUTED
end

local function run_action(label, fn, after)
    if busy or active_scan then return end
    busy = true
    itm.FooterDot.StyleSheet = STYLE_WARN
    itm.FooterStatus.Text = label .. "…"
    local ok, err = pcall(fn)
    busy = false
    if ok then
        update_snapshot(label .. " — done")
        if after then pcall(after) end
    else
        itm.FooterDot.StyleSheet = STYLE_ERROR
        itm.FooterStatus.Text = compact_context(label .. " — " .. tostring(err):gsub("^.-:%d+: ", ""), 100)
        print("ClipTimbre UI error: " .. tostring(err))
    end
end

local function run_timeline_ui_action(label, fn)
    if busy or active_scan then return end
    busy = true
    itm.FooterDot.StyleSheet = STYLE_WARN
    itm.FooterStatus.Text = label .. "…"
    win:Hide()
    if bmd and bmd.wait then bmd.wait(0.2) end
    local ok, err = pcall(fn)
    if bmd and bmd.wait then bmd.wait(0.1) end
    win:Show()
    set_page(selected_page)
    busy = false
    if ok then update_snapshot(label .. " — done")
    else
        itm.FooterDot.StyleSheet = STYLE_ERROR
        itm.FooterStatus.Text = compact_context(label .. " — " .. tostring(err):gsub("^.-:%d+: ", ""), 100)
        print("ClipTimbre UI error: " .. tostring(err))
    end
end

local function youtube_censor_options()
    local mode_text = tostring(itm.CensorMode.CurrentText or "Beep")
    local mode = "beep"
    if mode_text == "Smooth Mute" then mode = "mute" end
    if mode_text == "Timeline Mute" then mode = "timeline_mute" end
    return {
        mode = mode,
        include_high = is_checked(itm.CensorHigh),
        include_review = is_checked(itm.CensorReview),
        profanity = is_checked(itm.CensorProfanity),
        personal = is_checked(itm.CensorPersonal),
        hate = is_checked(itm.CensorHate),
        sexual_drugs = is_checked(itm.CensorSexualDrugs),
        violence = is_checked(itm.CensorViolence),
        other_sensitive = is_checked(itm.CensorOther),
    }
end

local function set_scan_controls(running)
    itm.ScanYouTube.Text = running and "Cancel scan" or "Scan timeline"
    itm.DashScanYouTube.Text = running and "Cancel scan" or "Scan YouTube Safety"
    itm.ScanYouTube.StyleSheet = running and STYLE_DANGER_BUTTON or STYLE_ACCENT_BUTTON
    itm.DashScanYouTube.StyleSheet = running and STYLE_DANGER_BUTTON or STYLE_ACCENT_BUTTON
    itm.AutoCensor.Enabled = timeline_available and not running
end

local function update_scan_ui(status)
    if active_scan.context_key ~= last_context_key then
        local detail = "Scan running on another timeline."
        itm.YTProgressText.Text = detail
        itm.DashProgressText.Text = detail
        itm.DashScanStage.Text = "Scanning another timeline"
        itm.FooterStatus.Text = detail
        itm.FooterDot.StyleSheet = STYLE_WARN
        return
    end
    local p = tonumber(status.progress_percent) or 0
    local stage = stage_name(status.stage)
    local elapsed = tonumber(status.elapsed_seconds) or 0
    local runtime = ""
    if tostring(status.engine or "") ~= "" then
        runtime = tostring(status.engine)
        if tostring(status.device or "") ~= "" then runtime = runtime .. " / " .. tostring(status.device) end
    end
    local detail
    if status.duration_seconds and tonumber(status.duration_seconds) and tonumber(status.duration_seconds) > 0 then
        detail = string.format("%s — %s / %s", stage, format_clock(status.progress_seconds), format_clock(status.duration_seconds))
    else
        detail = stage .. " — elapsed " .. format_clock(elapsed)
    end
    if runtime ~= "" then detail = detail .. " — " .. runtime end
    if status.cancel_requested then detail = "Stopping scan…" end
    itm.YTProgressBar.Text = string.format("%.0f%%", p)
    itm.DashProgressBar.Text = string.format("%.0f%%", p)
    itm.YTProgressText.Text = detail
    itm.DashProgressText.Text = detail
    itm.DashScanStage.Text = stage
    itm.FooterStatus.Text = detail
    itm.FooterDot.StyleSheet = STYLE_WARN
end

local function finish_scan_ui(status)
    local finished_key = active_scan.context_key
    active_scan = nil
    set_scan_controls(false)
    update_snapshot("Ready")
    if finished_key ~= last_context_key then
        itm.YTProgressText.Text = "Idle"
        itm.DashProgressText.Text = ""
        itm.DashScanStage.Text = "Idle"
        return
    end
    if status.cancelled then
        itm.YTProgressText.Text = "Scan cancelled."
        itm.DashProgressText.Text = "Scan cancelled."
        itm.DashScanStage.Text = "Cancelled"
        itm.FooterStatus.Text = "YouTube scan cancelled"
        itm.FooterDot.StyleSheet = STYLE_WARN
        return
    end
    if status.failed then
        itm.YTProgressText.Text = "Scan failed: " .. tostring(status.error or "unknown error")
        itm.DashProgressText.Text = itm.YTProgressText.Text
        itm.DashScanStage.Text = "Failed"
        itm.FooterStatus.Text = itm.YTProgressText.Text
        itm.FooterDot.StyleSheet = STYLE_ERROR
        pcall(function() itm.LogView.PlainText = sv.get_log_tail(220) end)
        return
    end
    itm.YTProgressBar.Text = "100%"
    itm.DashProgressBar.Text = "100%"
    itm.YTProgressText.Text = string.format("Complete — %d HIGH, %d REVIEW", tonumber(status.high_count) or 0, tonumber(status.review_count) or 0)
    itm.DashProgressText.Text = itm.YTProgressText.Text
    itm.DashScanStage.Text = "Complete"
    itm.FooterStatus.Text = "YouTube scan complete"
end

local function start_youtube_scan()
    if active_scan or busy then return end
    itm.FooterStatus.Text = "Preparing YouTube scan…"
    itm.FooterDot.StyleSheet = STYLE_WARN
    local ok, job_or_err = pcall(sv.start_youtube_safety_scan)
    if not ok then
        itm.FooterDot.StyleSheet = STYLE_ERROR
        itm.FooterStatus.Text = "Could not start scan: " .. tostring(job_or_err)
        return
    end
    active_scan = job_or_err
    set_scan_controls(true)
    update_scan_ui({ stage = "starting", progress_percent = 0, elapsed_seconds = 0 })
    scan_timer:Start()
end

local function cancel_youtube_scan()
    if not active_scan then return end
    pcall(function() sv.cancel_youtube_safety_scan(active_scan) end)
    itm.FooterStatus.Text = "Stopping YouTube scan…"
    itm.YTProgressText.Text = "Stopping scan…"
    itm.DashProgressText.Text = "Stopping scan…"
end

-- Populate controls -----------------------------------------------------------
itm.CensorMode:AddItem("Beep")
itm.CensorMode:AddItem("Smooth Mute")
itm.CensorMode:AddItem("Timeline Mute")
itm.CensorMode.CurrentIndex = 2

itm.YTSeverityFilter:AddItem("All")
itm.YTSeverityFilter:AddItem("High")
itm.YTSeverityFilter:AddItem("Review")
itm.YTSeverityFilter.CurrentIndex = 0

for _, v in ipairs({"tiny", "base", "small", "medium"}) do itm.SettingModel:AddItem(v) end
for _, v in ipairs({"auto", "ru", "en"}) do itm.SettingLanguage:AddItem(v) end
for _, v in ipairs({"auto", "mlx", "torch-whisper", "faster-whisper"}) do itm.SettingEngine:AddItem(v) end

local hdr = itm.YTRisks:NewItem()
hdr.Text[0] = "Time"
hdr.Text[1] = "Risk"
hdr.Text[2] = "Category"
hdr.Text[3] = "Match"
itm.YTRisks:SetHeaderItem(hdr)
itm.YTRisks.ColumnCount = 4
itm.YTRisks.ColumnWidth[0] = 68
itm.YTRisks.ColumnWidth[1] = 62
itm.YTRisks.ColumnWidth[2] = 140
itm.YTRisks.ColumnWidth[3] = 220

-- Navigation ----------------------------------------------------------------
function win.On.NavDashboard.Clicked(ev) set_page(0) end
function win.On.NavVoice.Clicked(ev)
    set_page(1)
    local ok, err = pcall(refresh_profiles)
    if not ok then itm.FooterStatus.Text = tostring(err):gsub("^.-:%d+: ", "") end
end
function win.On.NavPauses.Clicked(ev) set_page(2) end
function win.On.NavYouTube.Clicked(ev) set_page(3); update_snapshot() end
function win.On.NavSettings.Clicked(ev) set_page(4); load_settings() end
function win.On.NavDiagnostics.Clicked(ev) set_page(5) end

-- Window / status ------------------------------------------------------------
function win.On.ClipTimbreWindow.Close(ev)
    if active_scan then pcall(function() sv.cancel_youtube_safety_scan(active_scan) end) end
    disp:ExitLoop()
end
function win.On.Close.Clicked(ev)
    if active_scan then pcall(function() sv.cancel_youtube_safety_scan(active_scan) end) end
    disp:ExitLoop()
end
function win.On.Refresh.Clicked(ev)
    if selected_page == 1 then pcall(refresh_profiles) end
    update_snapshot("Status refreshed")
end

-- Dashboard -----------------------------------------------------------------
function win.On.DashScanYouTube.Clicked(ev) if active_scan then cancel_youtube_scan() else start_youtube_scan() end end
function win.On.DashFindVoice.Clicked(ev) run_action("Find streamer", sv.find_streamer) end
function win.On.DashSetReference.Clicked(ev) run_action("Set reference", sv.set_reference) end

-- Voice ---------------------------------------------------------------------
function win.On.SetReference.Clicked(ev) run_action("Set reference", sv.set_reference) end
function win.On.FindStreamer.Clicked(ev) run_action("Find streamer", sv.find_streamer) end
function win.On.PrevStreamer.Clicked(ev) run_action("Previous streamer region", sv.previous_streamer) end
function win.On.NextStreamer.Clicked(ev) run_action("Next streamer region", sv.next_streamer) end
function win.On.ClearStreamer.Clicked(ev) run_action("Clear streamer markers", sv.clear_markers) end
function win.On.ProfileChoice.Activated(ev)
    local name = profile_choices[itm.ProfileChoice.CurrentIndex + 1]
    if not name or name == selected_profile then return end
    run_action("Switch voice profile", function() sv.select_profile(name) end)
    show_active_profile(selected_profile)
end

local function create_voice_profile()
    local name = tostring(itm.NewProfileName.Text or "")
    if not name:match("%S") then return end
    run_action("Create voice profile", function()
        sv.create_profile(name)
        itm.NewProfileName.Text = ""
        refresh_profiles()
    end)
end
function win.On.NewProfileName.TextChanged(ev)
    itm.CreateProfile.Enabled = tostring(itm.NewProfileName.Text or ""):match("%S") ~= nil
end
function win.On.NewProfileName.ReturnPressed(ev) create_voice_profile() end
function win.On.CreateProfile.Clicked(ev) create_voice_profile() end
function win.On.AddSample.Clicked(ev) run_action("Add voice sample", sv.add_profile_reference, update_snapshot) end
function win.On.ProfileStatus.Clicked(ev) run_action("Profile status", sv.profile_status) end
function win.On.Correct.Clicked(ev) run_action("Confirm match", sv.feedback_correct) end
function win.On.Wrong.Clicked(ev) run_action("Mark wrong match", sv.feedback_wrong) end
function win.On.ClearSamples.Clicked(ev) run_action("Clear voice samples", sv.clear_profile_references, update_snapshot) end

-- Pauses --------------------------------------------------------------------
function win.On.MarkPauses.Clicked(ev) run_action("Mark pauses", sv.mark_streamer_pauses) end
function win.On.TightenPauses.Clicked(ev) run_timeline_ui_action("Tighten pauses", sv.tighten_streamer_pauses) end
function win.On.PrevPause.Clicked(ev) run_action("Previous pause", sv.previous_pause) end
function win.On.NextPause.Clicked(ev) run_action("Next pause", sv.next_pause) end
function win.On.ClearPauses.Clicked(ev) run_action("Clear pause markers", sv.clear_pause_markers) end

-- YouTube -------------------------------------------------------------------
function win.On.ScanYouTube.Clicked(ev) if active_scan then cancel_youtube_scan() else start_youtube_scan() end end
function win.On.PrevYouTube.Clicked(ev) run_action("Previous YouTube risk", sv.previous_youtube_risk) end
function win.On.NextYouTube.Clicked(ev) run_action("Next YouTube risk", sv.next_youtube_risk) end
function win.On.ClearYouTube.Clicked(ev)
    run_action("Clear YouTube markers", sv.clear_youtube_markers)
end
function win.On.YTRefreshResults.Clicked(ev)
    update_snapshot("YouTube results refreshed")
end
local function risk_context_is_current()
    local ok, key = pcall(sv.get_ui_context_key)
    if ok and key == last_context_key then return true end
    update_snapshot()
    return false
end
function win.On.YTSearch.TextChanged(ev)
    if risk_context_is_current() then refresh_risk_tree() end
end
function win.On.YTSeverityFilter.CurrentIndexChanged(ev)
    if risk_context_is_current() then refresh_risk_tree() end
end
function win.On.YTRisks.ItemClicked(ev)
    if not ev.item or not risk_context_is_current() then return end
    local event = risk_item_events[tonumber(ev.item.WhatsThis[0])]
    if not event then return end
    itm.YTSelectionDetails.PlainText = string.format("%s  •  %s  •  %s\n%s\n%s", format_clock(event.start),
        event.severity:upper(), pretty_category(event.category), event.phrase, event.context)
    itm.FooterStatus.Text = "Selected risk at " .. format_clock(event.start)
end
function win.On.YTRisks.ItemDoubleClicked(ev)
    if not ev.item or not risk_context_is_current() then return end
    local event = risk_item_events[tonumber(ev.item.WhatsThis[0])]
    if event then
        local ok, tc = pcall(function() return sv.jump_to_youtube_seconds(event.start) end)
        if ok then itm.FooterStatus.Text = "Jumped to " .. tostring(tc) else itm.FooterStatus.Text = "Jump failed: " .. tostring(tc) end
    end
end
function win.On.AutoCensor.Clicked(ev)
    run_action("Auto censor YouTube risks", function() sv.auto_censor_youtube(youtube_censor_options()) end, update_snapshot)
end

-- Settings ------------------------------------------------------------------
function win.On.SaveSettings.Clicked(ev)
    local patch = {
        ad_safety_model = tostring(itm.SettingModel.CurrentText or "small"),
        ad_safety_language = tostring(itm.SettingLanguage.CurrentText or "auto"),
        ad_safety_engine = tostring(itm.SettingEngine.CurrentText or "auto"),
        ad_safety_chunk_seconds = itm.SettingChunk.Text,
        threshold = itm.SettingThreshold.Text,
        youtube_censor_pad_before_seconds = itm.SettingPadBefore.Text,
        youtube_censor_pad_after_seconds = itm.SettingPadAfter.Text,
        youtube_censor_beep_hz = itm.SettingBeepHz.Text,
        youtube_censor_beep_db = itm.SettingBeepDb.Text,
        youtube_censor_fade_ms = itm.SettingCensorFade.Text,
        youtube_censor_beep_duck_db = itm.SettingBeepDuck.Text,
    }
    local ok, err = pcall(function() sv.save_config(patch) end)
    if ok then
        itm.SettingsStatus.Text = "Saved"
        itm.SettingsStatus.StyleSheet = STYLE_SUCCESS
        update_snapshot("Settings saved")
    else
        itm.SettingsStatus.Text = "Error: " .. tostring(err)
        itm.SettingsStatus.StyleSheet = STYLE_ERROR
    end
end
function win.On.EditTerms.Clicked(ev) run_action("Open risk rules", sv.open_ad_safety_terms) end

-- Diagnostics ---------------------------------------------------------------
function win.On.Diagnostics.Clicked(ev)
    run_action("Diagnostics", sv.diagnostics, function() itm.LogView.PlainText = sv.get_log_tail(220) end)
end
function win.On.RefreshLog.Clicked(ev) pcall(function() itm.LogView.PlainText = sv.get_log_tail(220) end); itm.FooterStatus.Text = "Log refreshed" end
function win.On.OpenLog.Clicked(ev) pcall(sv.open_log) end
function win.On.OpenData.Clicked(ev) pcall(sv.open_app_folder) end
function win.On.ClearCache.Clicked(ev) run_action("Clear cache", sv.clear_cache) end

function disp.On.Timeout(ev)
    if ev.who == context_timer.ID then
        if not busy then
            local ok, key = pcall(sv.get_ui_context_key)
            if not ok or key ~= last_context_key then
                update_snapshot("Ready")
            end
        end
        return
    end
    if ev.who ~= scan_timer.ID or not active_scan then return end
    local ok, status = pcall(function() return sv.poll_youtube_safety_scan(active_scan) end)
    if not ok then
        finish_scan_ui({ failed = true, error = tostring(status), done = true })
        return
    end
    if status.done then
        finish_scan_ui(status)
    else
        update_scan_ui(status)
        scan_timer:Start()
    end
end

load_settings()
pcall(refresh_profiles)
update_snapshot("Ready")
set_scan_controls(false)

win:Show()
set_page(0)
context_timer:Start()
disp:RunLoop()
context_timer:Stop()
win:Hide()
