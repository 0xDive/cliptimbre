-- Exercise the launcher with Win32 test doubles so it can also run in Linux CI.

local ffi = require("ffi")
local kernel, shell = {}, {}
local original_load = ffi.load
ffi.load = function(name, ...)
    if name == "kernel32" then return kernel end
    if name == "shell32" then return shell end
    return original_load(name, ...)
end

local function pointer(v) return ffi.cast("void *", v) end
local function read_wide(value)
    local out = {}
    local i = 0
    while value[i] ~= 0 do
        assert(value[i] < 256)
        out[#out + 1] = string.char(value[i])
        i = i + 1
    end
    return table.concat(out)
end

function kernel.MultiByteToWideChar(_, _, value, _, buffer)
    if buffer then
        for i = 1, #value do buffer[i - 1] = value:byte(i) end
        buffer[#value] = 0
    end
    return #value + 1
end

local file_count, close_count = 0, 0
function kernel.CreateFileW(name, access, share, security, disposition)
    assert(ffi.sizeof(security) == 24 and security.length == 24 and security.inherit == 1)
    assert(share == 7)
    if file_count == 0 then
        assert(read_wide(name) == "NUL" and access == 0x80000000 and disposition == 3)
    else
        assert(read_wide(name) == [[C:\logs\app.log]] and access == 4 and disposition == 4)
    end
    file_count = file_count + 1
    return pointer(file_count)
end

function kernel.InitializeProcThreadAttributeList(list, count, flags, size)
    assert(count == 1 and flags == 0)
    if list == nil then
        size[0] = 48
        return 0
    end
    return 1
end

function kernel.UpdateProcThreadAttribute(list, flags, attr, handles, size)
    assert(attr == 0x20002 and size == 16 and handles[0] == pointer(1) and handles[1] == pointer(2))
    return 1
end

local create_failure
function kernel.CreateProcessW(exe, command, _, _, inherit, flags, _, _, startup, process)
    assert(read_wide(exe) == [[C:\Program Files\Python\pythonw.exe]])
    local line = read_wide(command)
    local expected = [["C:\Program Files\Python\pythonw.exe" "-c" "a \"b\" %PATH% !x! &" "C:\a\\" ""]]
    assert(line == expected, line)
    assert(inherit == 1 and flags == 0x08080000 and startup.size == 112 and startup.flags == 0x100)
    assert(startup.input == pointer(1) and startup.output == pointer(2) and startup.error == startup.output)
    if create_failure then return 0 end
    process.process = pointer(10)
    process.thread = pointer(11)
    return 1
end

function kernel.GetLastError() return 5 end
function kernel.DeleteProcThreadAttributeList() end
function kernel.CloseHandle()
    close_count = close_count + 1
    return 1
end
function kernel.WaitForSingleObject(handle, timeout)
    assert(handle == pointer(10))
    return timeout == 0 and 258 or 0
end
function kernel.GetExitCodeProcess(handle, code)
    code[0] = 0
    return 1
end

local win = assert(loadfile("resolve_lua/windows_process.lua"))()
local args = {[[C:/Program Files/Python/pythonw.exe]], "-c", [[a "b" %PATH% !x! &]], [[C:\a\]], ""}
local log = "C:/logs/app.log"
local process = assert(win.start(args, log, log, true))
assert(win.exit_code(process, false) == nil)
assert(win.exit_code(process, true) == 0)
win.close(process)
assert(close_count == 4)

create_failure, file_count, close_count = true, 0, 0
local missing, err = win.start(args, log, log, true)
assert(not missing and err:find("Windows error 5", 1, true) and close_count == 2)

assert(loadfile("resolve_lua/windows_process.lua"))()
ffi.load = original_load
print("Windows launcher ABI, quoting, hidden flags, streams, exit status, and launch failure passed")
