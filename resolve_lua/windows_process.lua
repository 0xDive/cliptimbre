-- GNU AGPL version 3 only. See LICENSE and LICENSE-RESOLVE-EXCEPTION.md.
-- Loaded only on Windows, where Resolve supplies LuaJIT.

local ffi = ffi or require("ffi")
local bit = require("bit")
local M = {}

-- The panel can be opened more than once in the same Lua state.
if not pcall(ffi.typeof, "ClipTimbreStartupInfo") then
    ffi.cdef[[
        typedef struct {
            uint32_t length;
            void *descriptor;
            int inherit;
        } ClipTimbreSecurity;

        typedef struct {
            uint32_t size;
            uint16_t *reserved, *desktop, *title;
            uint32_t x, y, x_size, y_size, x_chars, y_chars, fill, flags;
            uint16_t show, reserved_size;
            void *reserved_data, *input, *output, *error;
        } ClipTimbreStartupInfo;

        typedef struct {
            ClipTimbreStartupInfo startup;
            void *attributes;
        } ClipTimbreStartupInfoEx;

        typedef struct {
            void *process, *thread;
            uint32_t process_id, thread_id;
        } ClipTimbreProcessInfo;

        typedef struct {
            uint32_t attributes;
            uint32_t creation_time[2], access_time[2], write_time[2];
            uint32_t size_high, size_low, reserved0, reserved1;
            uint16_t name[260], short_name[14];
        } ClipTimbreFindData;

        int __stdcall MultiByteToWideChar(uint32_t, uint32_t, const char *, int, uint16_t *, int);
        int __stdcall WideCharToMultiByte(uint32_t, uint32_t, const uint16_t *, int, char *, int,
                                         const char *, int *);
        void *__stdcall CreateFileW(const uint16_t *, uint32_t, uint32_t, ClipTimbreSecurity *,
                                    uint32_t, uint32_t, void *);
        int __stdcall InitializeProcThreadAttributeList(void *, uint32_t, uint32_t, size_t *);
        int __stdcall UpdateProcThreadAttribute(void *, uint32_t, uintptr_t, void *, size_t, void *, size_t *);
        void __stdcall DeleteProcThreadAttributeList(void *);
        int __stdcall CreateProcessW(const uint16_t *, uint16_t *, void *, void *, int, uint32_t,
                                     void *, const uint16_t *, ClipTimbreStartupInfo *, ClipTimbreProcessInfo *);
        uint32_t __stdcall GetLastError(void);
        uint32_t __stdcall WaitForSingleObject(void *, uint32_t);
        int __stdcall GetExitCodeProcess(void *, uint32_t *);
        int __stdcall CloseHandle(void *);
        void __stdcall Sleep(uint32_t);
        uint32_t __stdcall GetFileAttributesW(const uint16_t *);
        int __stdcall CreateDirectoryW(const uint16_t *, void *);
        void *__stdcall FindFirstFileW(const uint16_t *, ClipTimbreFindData *);
        int __stdcall FindNextFileW(void *, ClipTimbreFindData *);
        int __stdcall FindClose(void *);
        intptr_t __stdcall ShellExecuteW(void *, const uint16_t *, const uint16_t *,
                                         const uint16_t *, const uint16_t *, int);
    ]]
end

local kernel = ffi.load("kernel32")
local shell = ffi.load("shell32")
local invalid_handle = ffi.cast("void *", -1)
local CP_UTF8, MB_ERR_INVALID_CHARS = 65001, 8
local FILE_ATTRIBUTE_DIRECTORY, INVALID_FILE_ATTRIBUTES = 16, 0xFFFFFFFF
local GENERIC_READ, GENERIC_WRITE, FILE_APPEND_DATA = 0x80000000, 0x40000000, 4
local FILE_SHARE_ALL = 7
local CREATE_ALWAYS, OPEN_EXISTING, OPEN_ALWAYS = 2, 3, 4
local STARTF_USESTDHANDLES, PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x100, 0x20002
local CREATE_NO_WINDOW, EXTENDED_STARTUPINFO_PRESENT = 0x08000000, 0x00080000
local WAIT_OBJECT_0, WAIT_TIMEOUT, INFINITE = 0, 258, 0xFFFFFFFF

local function wide(value)
    local cp, flags = CP_UTF8, MB_ERR_INVALID_CHARS
    local size = kernel.MultiByteToWideChar(cp, flags, value, -1, nil, 0)
    if size == 0 then
        -- Environment paths from the C runtime may use the Windows code page.
        cp, flags = 0, 0
        size = kernel.MultiByteToWideChar(cp, flags, value, -1, nil, 0)
    end
    assert(size > 0, "Could not convert a Windows command or path")
    local buffer = ffi.new("uint16_t[?]", size)
    assert(kernel.MultiByteToWideChar(cp, flags, value, -1, buffer, size) > 0)
    return buffer
end

local function utf8(value)
    local size = kernel.WideCharToMultiByte(CP_UTF8, 0, value, -1, nil, 0, nil, nil)
    if size == 0 then return nil end
    local buffer = ffi.new("char[?]", size)
    if kernel.WideCharToMultiByte(CP_UTF8, 0, value, -1, buffer, size, nil, nil) == 0 then return nil end
    return ffi.string(buffer, size - 1)
end

local function windows_path(path)
    return (path:gsub("/", "\\"))
end

-- Encode one argv entry using the Windows C runtime's backslash and quote rules.
local function quote(value)
    local escaped = tostring(value):gsub('(\\*)"', '%1%1\\"'):gsub("(\\+)$", "%1%1")
    return '"' .. escaped .. '"'
end

function M.system_exe(name)
    return (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\" .. name
end

function M.start(args, output, error_log, append)
    local executable = wide(windows_path(args[1]))
    local quoted = {quote(windows_path(args[1]))}
    for i = 2, #args do quoted[i] = quote(args[i]) end
    local command = wide(table.concat(quoted, " "))

    local security = ffi.new("ClipTimbreSecurity", {
        length = ffi.sizeof("ClipTimbreSecurity"),
        inherit = 1,
    })
    local startup = ffi.new("ClipTimbreStartupInfoEx")
    startup.startup.size = ffi.sizeof(startup)
    startup.startup.flags = STARTF_USESTDHANDLES
    local handles = {}

    local function open_stream(path, access, disposition)
        local handle = kernel.CreateFileW(wide(path and windows_path(path) or "NUL"), access, FILE_SHARE_ALL,
            security, path and disposition or OPEN_EXISTING, 0, nil)
        if handle == invalid_handle then return nil end
        handles[#handles + 1] = handle
        return handle
    end

    local function close_streams()
        for _, handle in ipairs(handles) do kernel.CloseHandle(handle) end
    end

    startup.startup.input = open_stream(nil, GENERIC_READ, OPEN_EXISTING)
    startup.startup.output = open_stream(output, append and FILE_APPEND_DATA or GENERIC_WRITE,
        append and OPEN_ALWAYS or CREATE_ALWAYS)
    if output and output == error_log then
        startup.startup.error = startup.startup.output
    else
        startup.startup.error = open_stream(error_log, error_log and FILE_APPEND_DATA or GENERIC_WRITE, OPEN_ALWAYS)
    end
    if startup.startup.input == nil or startup.startup.output == nil or startup.startup.error == nil then
        close_streams()
        return nil, "Could not open Windows process streams"
    end

    -- Restrict inheritance to these streams. Resolve may own other handles.
    local size = ffi.new("size_t[1]")
    kernel.InitializeProcThreadAttributeList(nil, 1, 0, size)
    local attributes = ffi.new("uint8_t[?]", size[0])
    if kernel.InitializeProcThreadAttributeList(attributes, 1, 0, size) == 0 then
        close_streams()
        return nil, "Could not initialize Windows process attributes"
    end
    startup.attributes = attributes
    local handle_list = ffi.new("void *[?]", #handles, handles)
    local ok = kernel.UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        handle_list, ffi.sizeof(handle_list), nil, nil)
    local process = ffi.new("ClipTimbreProcessInfo")
    if ok ~= 0 then
        ok = kernel.CreateProcessW(executable, command, nil, nil, 1,
            CREATE_NO_WINDOW + EXTENDED_STARTUPINFO_PRESENT, nil, nil, startup.startup, process)
    end
    local error_code = ok == 0 and kernel.GetLastError()
    kernel.DeleteProcThreadAttributeList(attributes)
    close_streams()
    if ok == 0 then
        return nil, "Could not start " .. args[1] .. " (Windows error " .. tostring(error_code) .. ")"
    end
    kernel.CloseHandle(process.thread)
    return ffi.gc(process.process, kernel.CloseHandle)
end

function M.exit_code(process, wait)
    local result = kernel.WaitForSingleObject(process, wait and INFINITE or 0)
    if result == WAIT_TIMEOUT then return nil end
    local code = ffi.new("uint32_t[1]")
    if result ~= WAIT_OBJECT_0 or kernel.GetExitCodeProcess(process, code) == 0 then return 1 end
    return tonumber(code[0])
end

function M.close(process)
    kernel.CloseHandle(ffi.gc(process, nil))
end

function M.run(args, output, error_log, append)
    local process, err = M.start(args, output, error_log, append)
    if not process then return false, err end
    local code = M.exit_code(process, true)
    M.close(process)
    return code == 0
end

function M.sleep(seconds)
    kernel.Sleep(math.floor(seconds * 1000 + 0.5))
end

function M.open(target, argument)
    if not target:find("://", 1, true) then target = windows_path(target) end
    if argument then argument = windows_path(argument) end
    local result = shell.ShellExecuteW(nil, nil, wide(target), argument and wide(quote(argument)) or nil, nil, 1)
    return result > 32
end

function M.mkdir_p(path)
    path = windows_path(path):gsub("\\+$", "")
    local name = wide(path)
    local attrs = kernel.GetFileAttributesW(name)
    if attrs ~= INVALID_FILE_ATTRIBUTES then return bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0 end
    local parent = path:match("^(.*)\\[^\\]+$")
    if parent and parent ~= "" and parent:sub(-1) ~= ":" then M.mkdir_p(parent) end
    if kernel.CreateDirectoryW(name, nil) ~= 0 then return true end
    -- A concurrent worker may have created this directory.
    attrs = kernel.GetFileAttributesW(name)
    return attrs ~= INVALID_FILE_ATTRIBUTES and bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0
end

function M.files(dir, pattern, first_only)
    local result = {}
    local entry = ffi.new("ClipTimbreFindData")
    local handle = kernel.FindFirstFileW(wide(windows_path(dir .. "/" .. pattern)), entry)
    if handle == invalid_handle then return result end
    repeat
        if bit.band(entry.attributes, FILE_ATTRIBUTE_DIRECTORY) == 0 then
            local name = utf8(entry.name)
            if name then
                result[#result + 1] = name
                if first_only then break end
            end
        end
    until kernel.FindNextFileW(handle, entry) == 0
    kernel.FindClose(handle)
    return result
end

return M
