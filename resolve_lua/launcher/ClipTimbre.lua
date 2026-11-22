-- ClipTimbre launcher for DaVinci Resolve.
-- GNU AGPL version 3 only. See LICENSE and LICENSE-RESOLVE-EXCEPTION.md.

local PATH_SEP = package.config:sub(1, 1)
local IS_WINDOWS = PATH_SEP == "\\"
local home = IS_WINDOWS and (os.getenv("USERPROFILE") or os.getenv("HOME") or "") or (os.getenv("HOME") or os.getenv("USERPROFILE") or "")
local data_dir = os.getenv("STREAMER_VOICE_DATA_DIR") or home .. "/.streamer_voice"
local common_path = data_dir .. "/resolve/streamer_voice_common.lua"
local version_file = io.open(data_dir .. "/VERSION", "rb")
local installed_version
if version_file then
    installed_version = (version_file:read("*l") or ""):match("^%s*(%d+%.%d+%.%d+)%s*$")
    version_file:close()
end
local version_label = installed_version and ("v" .. installed_version) or "Version unavailable"

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
QWidget { background-color:#1b1d20; color:#e7e9ed; font-size:12px; }
QLabel { background-color:transparent; }
QGroupBox { background-color:transparent; }
QPushButton { background-color:#292c31; border:1px solid #41464e; border-radius:4px; padding:6px 10px; color:#e7e9ed; }
QPushButton:hover { background-color:#33373e; border-color:#58616d; }
QPushButton:pressed { background-color:#25282e; }
QPushButton:disabled { color:#9298a2; background-color:#24272c; border-color:#343941; }
QLineEdit, QComboBox, QSpinBox, QTextEdit { background-color:#22252a; border:1px solid #41464e; border-radius:4px; padding:4px 7px; color:#e7e9ed; selection-background-color:#3a526a; }
QTreeWidget { background-color:#1f2227; alternate-background-color:#25282e; border:1px solid #393e46; color:#e7e9ed; }
QTreeWidget::item:selected { background-color:#354d64; color:#ffffff; }
QHeaderView::section { background-color:#2b2e34; color:#ced3da; border:0; border-right:1px solid #41464e; padding:5px; }
QCheckBox { spacing:6px; }
QPushButton:focus, QLineEdit:focus, QComboBox:focus, QSpinBox:focus, QTreeWidget:focus, QTextEdit:focus { border-color:#91b3d5; }
]]

local STYLE_TITLE = "font-size:18px; font-weight:700; color:#f1f3f5;"
local STYLE_PAGE_TITLE = "font-size:21px; font-weight:600; color:#f1f3f5;"
local STYLE_SECTION = "font-size:14px; font-weight:600; color:#e7e9ed;"
local STYLE_MUTED = "font-size:12px; color:#b9c0ca;"
local STYLE_MICRO = "font-size:11px; color:#b0b8c2;"
local STYLE_ACCENT_BUTTON = "QPushButton { background-color:#91b3d5; border-color:#91b3d5; color:#14202b; font-weight:600; } QPushButton:hover { background-color:#a6c4e1; border-color:#a6c4e1; } QPushButton:focus { border-color:#e4f2ff; } QPushButton:disabled { background-color:#24272c; border-color:#343941; color:#9298a2; }"
local STYLE_DANGER_BUTTON = "QPushButton { border-color:#75494d; color:#efb6ba; } QPushButton:hover { background-color:#412c32; border-color:#a66a70; } QPushButton:disabled { border-color:#343941; color:#9298a2; }"
local STYLE_ACTIVE_BUTTON = "QPushButton { border-color:#7799bc; color:#d5e8fb; }"
local icon_dir = data_dir:gsub("\\", "/"):gsub('"', '\\"') .. "/resolve/icons"
local STYLE_TOOL_HEADER = ([[
QPushButton {
    text-align:left; font-size:14px; font-weight:600; padding:8px 12px;
    background-color:#26292e; border-color:#3a4048;
    background-image:url("%s/chevron-right.png");
    background-repeat:no-repeat; background-position:right center; background-origin:content;
}
QPushButton:hover { background-color:#30343b; border-color:#535d68; }
QPushButton:checked {
    background-color:#2d333a; border-color:#47525e;
    background-image:url("%s/chevron-down.png");
}
QPushButton:focus { border-color:#91b3d5; }
]]):format(icon_dir, icon_dir)
local STYLE_SUCCESS = "font-size:12px; font-weight:600; color:#9ed3ac;"
local STYLE_WARN = "font-size:12px; font-weight:600; color:#efc17d;"
local STYLE_ERROR = "font-size:12px; font-weight:600; color:#f09ca0;"
local STYLE_PROGRESS = "font-weight:600; color:#91b3d5;"

local function separator(id)
    return ui:Label {
        ID = id, Text = "", Weight = 0,
        MinimumSize = {1, 1}, MaximumSize = {16777215, 1},
        StyleSheet = "background-color:#363b43;",
    }
end

local TOOL_SECTIONS = {"Voice", "Pauses", "YouTube"}
local TOOL_TITLES = {Voice = "Voice", Pauses = "Pauses", YouTube = "YouTube Safety"}
local TOOL_PAGES = {
    {id = "VoicePage", section = "Voice"},
    {id = "PausesPage", section = "Pauses"},
    {id = "YouTubePage", section = "YouTube"},
    {id = "CollapsedPage"},
}

local function header_id(page, section)
    return page.id .. section
end

local function tool_page(page, body)
    -- Separate layouts let Fusion collapse a section without reserving its height.
    local contents = {ID = page.id, Spacing = 7}
    for _, section in ipairs(TOOL_SECTIONS) do
        local expanded = section == page.section
        table.insert(contents, ui:Button {
            ID = header_id(page, section), Text = TOOL_TITLES[section],
            Checkable = true, Checked = expanded, StyleSheet = STYLE_TOOL_HEADER, Weight = 0,
        })
        if expanded then
            table.insert(contents, ui:HGroup {
                Weight = section == "YouTube" and 1 or 0, Spacing = 0,
                ui:HGap(12, 0), body, ui:HGap(12, 0),
            })
        end
    end
    if page.section ~= "YouTube" then table.insert(contents, ui:VGap(0, 1)) end
    return ui:VGroup(contents)
end

local function field(label, input)
    return ui:VGroup {
        Weight = 1, Spacing = 3,
        ui:Label { Text = label, StyleSheet = STYLE_MICRO, Weight = 0 },
        input,
    }
end

local win = disp:AddWindow({
    ID = "ClipTimbreWindow",
    WindowTitle = "ClipTimbre",
    Geometry = {120, 72, 820, 650},
    Spacing = 0,
    StyleSheet = ROOT_STYLE,
}, ui:VGroup {
    ID = "DialogContent",
    -- The Resolve window provides its own inset. Group margins can offset
    -- child controls without reducing their allocation in Fusion UIManager.
    Spacing = 8,

    ui:HGroup {
        ID = "Header",
        Weight = 0,
        Spacing = 12,
        ui:Label { ID = "HeaderTitle", Text = "ClipTimbre", StyleSheet = STYLE_TITLE, Weight = 0 },
        ui:Label { ID = "HeaderContext", Text = "", StyleSheet = STYLE_MUTED, WordWrap = true, Weight = 1 },
        ui:Label { ID = "UpdateNotice", Text = "Update available", StyleSheet = STYLE_WARN, Visible = false, Weight = 0 },
        ui:Button { ID = "BackToTools", Text = "Timeline tools", Weight = 0 },
        ui:Button { ID = "NavSettings", Text = "Settings", Weight = 0 },
        ui:Button { ID = "NavAbout", Text = "About && updates", Weight = 0 },
    },

    separator("TopSeparator"),

    ui:Stack {
        ID = "PageStack", CurrentIndex = 0, Weight = 1,

        tool_page(TOOL_PAGES[1], ui:VGroup {
            ID = "VoiceControls", Weight = 1, Spacing = 8,
            ui:HGroup {
                Weight = 0, Spacing = 9,
                ui:Label { Text = "Voice profile", StyleSheet = STYLE_SECTION, Weight = 0 },
                ui:ComboBox {
                    ID = "ProfileChoice", Events = { Activated = true },
                    ToolTip = "Choose a saved voice profile", Weight = 1,
                },
                ui:Label { ID = "VoiceProfileSummary", Text = "", StyleSheet = STYLE_MUTED, Weight = 0 },
                ui:Button { ID = "FindStreamer", Text = "Find voice", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
            },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "SetReference", Text = "Set temporary reference",
                    ToolTip = "Save a fallback reference from clean speech at the playhead.", Weight = 0 },
                ui:Button { ID = "AddSample", Text = "Add voice sample", Weight = 0 },
                ui:HGap(0, 1),
                ui:Button { ID = "ManageProfiles", Text = "Manage profiles", Weight = 0 },
            },
            separator("VoiceResultsSeparator"),
            ui:Label { Text = "Review matches", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "PrevStreamer", Text = "Previous", Weight = 0 },
                ui:Button { ID = "NextStreamer", Text = "Next", Weight = 0 },
                ui:HGap(0, 1),
                ui:Button { ID = "Correct", Text = "Correct match", Weight = 0 },
                ui:Button { ID = "Wrong", Text = "Wrong match", Weight = 0 },
                ui:Button { ID = "ClearStreamer", Text = "Clear markers", Weight = 0 },
            },
        }),

        tool_page(TOOL_PAGES[2], ui:VGroup {
            ID = "PauseControls", Weight = 1, Spacing = 8,
            ui:Label { Text = "Speech pauses", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:Label { Text = "Mark gaps in detected speech. Long pauses and uncertain cuts are flagged for manual review.", StyleSheet = STYLE_MUTED, WordWrap = true, Weight = 0 },
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
            ui:Label { Text = "Video playback", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:Label { Text = "Find still frames followed by motion in the selected area of a video track.", StyleSheet = STYLE_MUTED, WordWrap = true, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Label { Text = "Video track", StyleSheet = STYLE_MUTED, Weight = 0 },
                ui:SpinBox { ID = "VideoPauseTrack", Minimum = 1, Maximum = 128, Value = 1, Weight = 0 },
                ui:Label { Text = "Crop %", StyleSheet = STYLE_MUTED, Weight = 0 },
                ui:LineEdit { ID = "VideoPauseCrop", Text = "0,0,100,100", ToolTip = "x, y, width, height as percentages. Exclude a moving webcam overlay.", MinimumSize = {115, 0}, Weight = 0 },
                ui:HGap(0, 1),
            },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "MarkVideoPauses", Text = "Mark possible video pauses", Weight = 0 },
                ui:Button { ID = "ClearVideoPauses", Text = "Clear video markers", Weight = 0 },
                ui:HGap(0, 1),
            },
        }),

        tool_page(TOOL_PAGES[3], ui:VGroup {
            ID = "YouTubeControls", Weight = 1, Spacing = 7,
            ui:HGroup {
                Weight = 0,
                Spacing = 8,
                ui:Button { ID = "ScanYouTube", Text = "Scan timeline", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
                ui:Button { ID = "RebuildYouTubeMarkers", Text = "Rebuild markers", Enabled = false,
                    ToolTip = "Place timeline markers from the saved scan.", Weight = 0 },
                ui:HGap(0, 1),
                ui:Label { ID = "YTCountHigh", Text = "HIGH 0", StyleSheet = "font-weight:600; color:#dc9db8;", ToolTip = "Pink timeline markers", Weight = 0 },
                ui:Label { ID = "YTCountReview", Text = "REVIEW 0", StyleSheet = "font-weight:600; color:#8fc1c5;", ToolTip = "Cyan timeline markers", Weight = 0 },
                ui:Label { ID = "YTCountPersonal", Text = "PERSONAL 0", StyleSheet = "font-weight:600; color:#d4ad82;", ToolTip = "Sand timeline markers", Weight = 0 },
                ui:Label { Text = "MUTED", StyleSheet = "font-weight:600; color:#c497d4;", ToolTip = "Fuchsia timeline markers", Weight = 0 },
            },

            ui:HGroup {
                Weight = 0,
                Spacing = 8,
                ui:Label { ID = "YTScanRuntime", Text = "Runtime: —", StyleSheet = STYLE_MUTED, Weight = 0 },
                ui:Label { ID = "YTProgressBar", Text = "0%", StyleSheet = STYLE_PROGRESS, Weight = 0 },
                ui:Label { ID = "YTProgressText", Text = "Idle", StyleSheet = STYLE_MUTED, WordWrap = true, Weight = 1 },
            },

            ui:HGroup {
                Weight = 0,
                Spacing = 6,
                ui:LineEdit { ID = "YTSearch", PlaceholderText = "Filter risks…", Weight = 1 },
                ui:ComboBox { ID = "YTSeverityFilter", Weight = 0 },
                ui:Button { ID = "YTRefreshResults", Text = "Refresh", Weight = 0 },
                ui:Button { ID = "PrevYouTube", Text = "Previous", Weight = 0 },
                ui:Button { ID = "NextYouTube", Text = "Next", Weight = 0 },
                ui:Button { ID = "ClearYouTube", Text = "Clear markers", Weight = 0 },
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
                MinimumSize = {0, 54}, MaximumSize = {16777215, 54},
                StyleSheet = STYLE_MUTED,
                Weight = 0,
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
        }),

        tool_page(TOOL_PAGES[4]),

        ui:VGroup {
            ID = "ProfilesPage", Spacing = 9,
            ui:Label { Text = "Manage voice profiles", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },
            ui:Label { ID = "ProfileManagementContext", Text = "", StyleSheet = STYLE_MUTED, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:LineEdit { ID = "NewProfileName", PlaceholderText = "New profile name", Weight = 1 },
                ui:Button { ID = "CreateProfile", Text = "Create profile", Enabled = false, Weight = 0 },
            },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "ProfileStatus", Text = "Profile status", Weight = 0 },
                ui:Button { ID = "ClearSamples", Text = "Clear samples", StyleSheet = STYLE_DANGER_BUTTON, Weight = 0 },
                ui:HGap(0, 1),
            },
            ui:VGap(0, 1),
        },

        -- SETTINGS -------------------------------------------------------
        ui:VGroup {
            ID = "SettingsPage",

            Spacing = 9,
            ui:Label { Text = "Settings", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },
            ui:Label { Text = "Transcription", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 8,
                field("Model", ui:ComboBox { ID = "SettingModel", ToolTip = "Whisper model. Small balances speed and accuracy.", Weight = 0 }),
                field("Language", ui:ComboBox { ID = "SettingLanguage", ToolTip = "Force a language or let Whisper detect it automatically.", Weight = 0 }),
                field("Engine", ui:ComboBox { ID = "SettingEngine", ToolTip = "Auto selects MLX on Apple Silicon and compatible engines elsewhere.", Weight = 0 }),
                field("Chunk length (sec)", ui:LineEdit { ID = "SettingChunk", ToolTip = "Audio processed per Whisper chunk.", Weight = 0 }),
            },
            ui:Label { ID = "SettingEngineRuntime", Text = "Current runtime: —", StyleSheet = STYLE_MICRO, Weight = 0 },

            separator("SettingsVoiceSeparator"),
            ui:Label { Text = "Voice recognition", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 10,
                field("Voice threshold", ui:LineEdit { ID = "SettingThreshold", ToolTip = "Higher values are stricter when deciding whether speech matches the profile.", Weight = 0 }),
                ui:Label { Text = "Higher thresholds require a closer voice match.", StyleSheet = STYLE_MUTED, WordWrap = true, Weight = 2 },
            },

            separator("SettingsCensorSeparator"),
            ui:Label { Text = "Auto Censor", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 8,
                field("Pad before (sec)", ui:LineEdit { ID = "SettingPadBefore", ToolTip = "Extra censor time before a matched word.", Weight = 0 }),
                field("Pad after (sec)", ui:LineEdit { ID = "SettingPadAfter", ToolTip = "Extra censor time after a matched word.", Weight = 0 }),
                field("Censor fade (ms)", ui:LineEdit { ID = "SettingCensorFade", ToolTip = "Fade down and up around a mute or beep.", Weight = 0 }),
            },
            ui:HGroup {
                Weight = 0, Spacing = 8,
                field("Beep frequency (Hz)", ui:LineEdit { ID = "SettingBeepHz", ToolTip = "Frequency of the censor tone in Beep mode.", Weight = 0 }),
                field("Beep level (dB)", ui:LineEdit { ID = "SettingBeepDb", ToolTip = "Level of the censor tone.", Weight = 0 }),
                field("Source under beep (dB)", ui:LineEdit { ID = "SettingBeepDuck", ToolTip = "How far the original audio is ducked under the beep.", Weight = 0 }),
            },
            ui:Label { Text = "Timeline Mute keeps separate tracks. Beep and Smooth Mute use one mix.", StyleSheet = STYLE_MICRO, WordWrap = true, Weight = 0 },
            ui:HGroup {
                Weight = 0, Spacing = 7,
                ui:Button { ID = "SaveSettings", Text = "Save settings", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
                ui:Button { ID = "EditTerms", Text = "Edit risk rules", Weight = 0 },
                ui:HGap(0, 1),
                ui:Button { ID = "NavDiagnostics", Text = "Diagnostics", Weight = 0 },
            },
            ui:Label { ID = "SettingsStatus", Text = "", StyleSheet = STYLE_MUTED, Weight = 0 },
            ui:VGap(0, 1),
        },

        -- DIAGNOSTICS ----------------------------------------------------
        ui:VGroup {
            ID = "DiagnosticsPage",

            Spacing = 8,
            ui:Label { Text = "Diagnostics", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },
            ui:Label { ID = "HeaderRuntime", Text = version_label, StyleSheet = STYLE_MUTED, Weight = 0 },
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
                StyleSheet = "background-color:#17181b; color:#ceced5; font-family:monospace; font-size:11px; border:1px solid #3c3d43;",
            },
        },

        -- ABOUT & UPDATES ------------------------------------------------
        ui:VGroup {
            ID = "AboutPage",
            Spacing = 8,
            ui:Label { Text = "About ClipTimbre", StyleSheet = STYLE_PAGE_TITLE, Weight = 0 },
            ui:Label { Text = "Updates", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:Label { ID = "UpdateVersion", Text = "", StyleSheet = STYLE_MUTED, WordWrap = true, Weight = 0 },
            ui:Label { ID = "UpdateStatus", Text = "", StyleSheet = STYLE_MUTED, Weight = 0 },
            ui:HGroup {
                ID = "UpdateActions", Weight = 0, Spacing = 6,
                ui:Button { ID = "CheckUpdates", Text = "Check for updates", StyleSheet = STYLE_ACCENT_BUTTON, Weight = 0 },
                ui:Button { ID = "OpenRelease", Text = "Open release", Enabled = false, Weight = 0 },
                ui:HGap(0, 1),
            },
            separator("AboutSeparator"),
            ui:Label { Text = "Project links", StyleSheet = STYLE_SECTION, Weight = 0 },
            ui:HGroup {
                ID = "ProjectLinks", Weight = 0, Spacing = 6,
                ui:Button { ID = "OpenGitHub", Text = "GitHub repository", Weight = 0 },
                ui:Button { ID = "OpenTelegram", Text = "Telegram @dev_dive", Weight = 0 },
                ui:HGap(0, 1),
            },
            ui:VGap(0, 1),
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
local update_job
local latest_release
local busy = false
local PAGE_VOICE, PAGE_COLLAPSED, PAGE_PROFILES, PAGE_SETTINGS, PAGE_DIAGNOSTICS, PAGE_ABOUT = 0, 3, 4, 5, 6, 7
local selected_page = PAGE_VOICE
local last_tools_page = PAGE_VOICE
local voice_summary = ""
local youtube_summary = "Not scanned"
local youtube_tooltip = ""
local risk_item_events = {}
local cached_events = {}
local risk_empty_message = "Open a timeline to scan its audio."
local profile_choices = {}
local selected_profile = ""
local timeline_controls = {
    "SetReference", "FindStreamer",
    "PrevStreamer", "NextStreamer", "ClearStreamer", "AddSample", "Correct", "Wrong",
    "MarkPauses", "TightenPauses", "PrevPause", "NextPause", "ClearPauses", "MarkVideoPauses", "ClearVideoPauses", "ScanYouTube",
    "PrevYouTube", "NextYouTube", "ClearYouTube", "AutoCensor", "Diagnostics",
}
local timeline_available = false
local last_context_key = nil

local PAGE_IDS = {"VoicePage", "PausesPage", "YouTubePage", "CollapsedPage", "ProfilesPage", "SettingsPage", "DiagnosticsPage", "AboutPage"}

local function update_tool_headers()
    local scan_status = youtube_summary
    if active_scan then
        if active_scan.cancel_requested then
            scan_status = "Stopping scan…"
        elseif active_scan.context_key == last_context_key then
            scan_status = "Scanning " .. itm.YTProgressBar.Text
        else
            scan_status = "Scanning another timeline"
        end
    end
    local summary = {
        Voice = voice_summary,
        Pauses = "Speech and video",
        YouTube = scan_status,
    }
    for _, page in ipairs(TOOL_PAGES) do
        for _, section in ipairs(TOOL_SECTIONS) do
            local button = itm[header_id(page, section)]
            local expanded = page.section == section
            local title = TOOL_TITLES[section]
            button.Text = title .. (not expanded and summary[section] ~= "" and "  ·  " .. summary[section] or "")
            button.ToolTip = (expanded and "Collapse " or "Expand ") .. title ..
                (section == "YouTube" and youtube_tooltip ~= "" and ("\n" .. youtube_tooltip) or "")
        end
    end
end

local function set_page(index)
    selected_page = index
    itm.PageStack.CurrentIndex = index
    for position, id in ipairs(PAGE_IDS) do
        -- Some Resolve builds leave inactive stack pages visible.
        itm[id].Visible = position - 1 == index
    end
    if index <= PAGE_COLLAPSED then last_tools_page = index end
    itm.BackToTools.Visible = index > PAGE_COLLAPSED
    itm.NavSettings.StyleSheet = (index == PAGE_SETTINGS or index == PAGE_DIAGNOSTICS) and STYLE_ACTIVE_BUTTON or ""
    itm.NavAbout.StyleSheet = index == PAGE_ABOUT and STYLE_ACTIVE_BUTTON or ""
    pcall(function() itm.PageStack:Update() end)

    if index == PAGE_DIAGNOSTICS then
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
        itm.ScanYouTube.Enabled = active_scan ~= nil
        itm.RebuildYouTubeMarkers.Enabled = false
        cached_events = {}
        risk_empty_message = "Could not read the current timeline."
        refresh_risk_tree()
        itm.YTCountHigh.Text = "HIGH 0"
        itm.YTCountReview.Text = "REVIEW 0"
        itm.YTCountPersonal.Text = "PERSONAL 0"
        youtube_summary = "Timeline unavailable"
        youtube_tooltip = ""
        update_tool_headers()
        itm.HeaderContext.Text = "Timeline unavailable"
        itm.HeaderContext.ToolTip = ""
        itm.HeaderRuntime.Text = version_label
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
    itm.RebuildYouTubeMarkers.Enabled = timeline_available and snap.youtube_valid and not active_scan
    itm.AutoCensor.Enabled = timeline_available and not active_scan
    if changed then
        itm.YTProgressBar.Text = "0%"
        itm.YTProgressText.Text = "Idle"
    end
    local timeline_context = snap.project .. " / " .. snap.timeline
    itm.HeaderContext.Text = timeline_available and string.format("%s  ·  %s  ·  %.3g fps",
        compact_context(timeline_context, 48), snap.duration_text, snap.fps) or "Open a timeline in Resolve to start editing"
    itm.HeaderContext.ToolTip = timeline_available and timeline_context or ""
    local rt = tostring(snap.runtime_engine or "not scanned")
    if tostring(snap.runtime_device or "") ~= "" then rt = rt .. " / " .. tostring(snap.runtime_device) end
    itm.HeaderRuntime.Text = "Runtime: " .. rt .. "  •  " .. version_label
    voice_summary = compact_context(snap.profile, 36)
    local sample_count = string.format("%d voice sample%s", snap.reference_count, snap.reference_count == 1 and "" or "s")
    itm.VoiceProfileSummary.Text = sample_count
    itm.ProfileManagementContext.Text = voice_summary .. "  ·  " .. sample_count
    if snap.profile ~= selected_profile then show_active_profile(snap.profile) end

    cached_events = snap.youtube_rows
    risk_empty_message = not timeline_available and "Open a timeline to scan its audio."
        or (snap.youtube_valid and "No risks found in this scan." or "Scan this timeline to see its results.")
    refresh_risk_tree()

    if snap.youtube_valid then
        youtube_summary = string.format("%d high / %d review", snap.youtube_high, snap.youtube_review)
        youtube_tooltip = "Last scan: " .. tostring(snap.youtube_scanned_text)
    else
        youtube_summary = timeline_available and "Not scanned" or "No timeline open"
        youtube_tooltip = snap.youtube_problem == "YouTube scan state is missing" and "" or snap.youtube_problem
    end
    itm.YTScanRuntime.ToolTip = youtube_tooltip
    update_tool_headers()
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
    itm.DiagnosticsSummary.Text = compact_context(string.format("%s · %s (%d samples) · %d high / %d review",
        timeline_available and snap.timeline or "No timeline open", snap.profile, snap.reference_count, snap.youtube_high, snap.youtube_review), 120)
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
    itm.ScanYouTube.StyleSheet = running and STYLE_DANGER_BUTTON or STYLE_ACCENT_BUTTON
    if running then itm.RebuildYouTubeMarkers.Enabled = false end
    itm.AutoCensor.Enabled = timeline_available and not running
end

local function update_scan_ui(status)
    if active_scan.context_key ~= last_context_key then
        local detail = "Scan running on another timeline."
        itm.YTProgressText.Text = detail
        update_tool_headers()
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
    itm.YTProgressText.Text = detail
    update_tool_headers()
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
        return
    end
    if status.cancelled then
        itm.YTProgressText.Text = "Scan cancelled."
        itm.FooterStatus.Text = "YouTube scan cancelled"
        itm.FooterDot.StyleSheet = STYLE_WARN
        return
    end
    if status.failed then
        itm.YTProgressText.Text = "Scan failed: " .. tostring(status.error or "unknown error")
        itm.FooterStatus.Text = itm.YTProgressText.Text
        itm.FooterDot.StyleSheet = STYLE_ERROR
        pcall(function() itm.LogView.PlainText = sv.get_log_tail(220) end)
        return
    end
    itm.YTProgressBar.Text = "100%"
    itm.YTProgressText.Text = string.format("Complete — %d HIGH, %d REVIEW", tonumber(status.high_count) or 0, tonumber(status.review_count) or 0)
    itm.FooterStatus.Text = "YouTube scan complete"
    if status.added and status.event_count and status.added < status.event_count then
        itm.FooterStatus.Text = string.format("%d of %d YouTube markers placed", status.added, status.event_count)
        itm.FooterDot.StyleSheet = STYLE_WARN
    end
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
    update_tool_headers()
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
function win.On.BackToTools.Clicked(ev) set_page(last_tools_page) end
for _, page in ipairs(TOOL_PAGES) do
    for position, section in ipairs(TOOL_SECTIONS) do
        local id = header_id(page, section)
        local expanded = section == page.section
        local target = expanded and PAGE_COLLAPSED or position - 1
        win.On[id].Clicked = function(ev)
            itm[id].Checked = expanded
            set_page(target)
            if not expanded and section == "Voice" then
                local ok, err = pcall(refresh_profiles)
                if not ok then itm.FooterStatus.Text = tostring(err):gsub("^.-:%d+: ", "") end
            elseif not expanded and section == "YouTube" then
                update_snapshot()
            end
        end
    end
end
function win.On.NavSettings.Clicked(ev) set_page(PAGE_SETTINGS); load_settings() end
function win.On.NavDiagnostics.Clicked(ev) set_page(PAGE_DIAGNOSTICS) end
function win.On.NavAbout.Clicked(ev) set_page(PAGE_ABOUT) end

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
    if selected_page == PAGE_VOICE or selected_page == PAGE_PROFILES then pcall(refresh_profiles) end
    update_snapshot("Status refreshed")
end

-- Voice ---------------------------------------------------------------------
function win.On.ManageProfiles.Clicked(ev) set_page(PAGE_PROFILES) end
function win.On.SetReference.Clicked(ev) run_action("Set reference", sv.set_reference) end
function win.On.FindStreamer.Clicked(ev) run_action("Find voice", sv.find_streamer) end
function win.On.PrevStreamer.Clicked(ev) run_action("Previous voice match", sv.previous_streamer) end
function win.On.NextStreamer.Clicked(ev) run_action("Next voice match", sv.next_streamer) end
function win.On.ClearStreamer.Clicked(ev) run_action("Clear voice markers", sv.clear_markers) end
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
function win.On.MarkVideoPauses.Clicked(ev)
    run_action("Scan video playback", function() sv.mark_video_pauses(itm.VideoPauseTrack.Value, itm.VideoPauseCrop.Text) end)
end
function win.On.ClearVideoPauses.Clicked(ev) run_action("Clear video markers", sv.clear_video_pauses) end

-- YouTube -------------------------------------------------------------------
function win.On.ScanYouTube.Clicked(ev) if active_scan then cancel_youtube_scan() else start_youtube_scan() end end
function win.On.RebuildYouTubeMarkers.Clicked(ev)
    local placed, total
    run_action("Rebuild YouTube markers", function()
        placed, total = sv.rebuild_youtube_markers()
    end, function()
        itm.FooterStatus.Text = string.format("%d of %d YouTube markers placed", placed, total)
        if placed < total then itm.FooterDot.StyleSheet = STYLE_WARN end
    end)
end
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
    local review_only = event.auto_censor == false or event.category == "frequent_profanity"
    local badge = review_only and "  •  Manual review only" or ""
    itm.YTSelectionDetails.PlainText = string.format("%s  •  %s  •  %s%s\n%s\n%s", format_clock(event.start),
        event.severity:upper(), pretty_category(event.category), badge, event.phrase, event.context)
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

-- About & updates -----------------------------------------------------------
local function show_update_info()
    local info = sv.get_update_info(installed_version)
    latest_release = info and info.latest
    local label = installed_version and ("Installed v" .. installed_version) or version_label
    if info then
        label = label .. "  •  Latest release v" .. info.latest ..
            "  •  Last checked " .. os.date("%Y-%m-%d %H:%M", info.checked_at)
    end
    itm.UpdateVersion.Text = label
    itm.UpdateNotice.Visible = info ~= nil and info.relation == -1
    itm.OpenRelease.Enabled = info ~= nil
    if not info then
        itm.UpdateStatus.Text = "No update check yet."
        itm.UpdateStatus.StyleSheet = STYLE_MUTED
    elseif info.relation == -1 then
        itm.UpdateStatus.Text = "Update available."
        itm.UpdateStatus.StyleSheet = STYLE_WARN
    elseif info.relation == 0 then
        itm.UpdateStatus.Text = "ClipTimbre is up to date."
        itm.UpdateStatus.StyleSheet = STYLE_SUCCESS
    elseif info.relation == 1 then
        itm.UpdateStatus.Text = "Installed version is newer than the latest release."
        itm.UpdateStatus.StyleSheet = STYLE_MUTED
    else
        itm.UpdateStatus.Text = "Installed version could not be verified."
        itm.UpdateStatus.StyleSheet = STYLE_WARN
    end
end

function win.On.CheckUpdates.Clicked(ev)
    if update_job then return end
    local ok, job, message = pcall(sv.start_update_check)
    if not ok or not job then
        itm.UpdateStatus.Text = message or "Could not start the update check."
        itm.UpdateStatus.StyleSheet = STYLE_ERROR
        return
    end
    update_job = job
    itm.CheckUpdates.Enabled = false
    itm.UpdateStatus.Text = "Checking GitHub for updates…"
    itm.UpdateStatus.StyleSheet = STYLE_MUTED
end
function win.On.OpenRelease.Clicked(ev) sv.open_release(latest_release) end
function win.On.OpenGitHub.Clicked(ev) sv.open_github() end
function win.On.OpenTelegram.Clicked(ev) sv.open_telegram() end

function disp.On.Timeout(ev)
    if ev.who == context_timer.ID then
        if update_job then
            local checked = sv.poll_update_check(update_job)
            if checked ~= nil then
                update_job = nil
                itm.CheckUpdates.Enabled = true
                show_update_info()
                if not checked then
                    itm.UpdateStatus.Text = "Could not check GitHub for updates. Try again."
                    itm.UpdateStatus.StyleSheet = STYLE_ERROR
                end
            end
        end
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
show_update_info()
update_snapshot("Ready")
set_scan_controls(false)

win:Show()
set_page(PAGE_VOICE)
context_timer:Start()
disp:RunLoop()
context_timer:Stop()
win:Hide()
