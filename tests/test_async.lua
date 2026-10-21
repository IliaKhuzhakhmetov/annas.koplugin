-- Run from the plugin directory: luajit tests/test_async.lua .
local h = dofile("tests/headless.lua")
local Trapper = dofile("tests/upstream/trapper.lua")
package.preload["ui/trapper"] = function() return Trapper end
local Async = require("annas.async_helper")
local ffi = require("ffi")
local UI, Ui, test, run_until, native, now = h.UI, h.Ui, h.test, h.run_until, h.native, h.now
local warnings = h.warnings

test("slow request yields UI; results survive serialization", function()
    local result, heartbeat
    UI:scheduleIn(0.02, function() heartbeat = true end)
    local started = now()
    Async.run(function()
        ffi.C.usleep(200000)
        return {{ title = "Нейромант", author = "William Gibson", format = "epub" }}
    end, function(value) result = value end, function(err) error(err) end,
        Ui.showLoadingMessage("Searching", true))
    assert(now() - started < 0.15, "starting request blocked UI")
    run_until(function() return heartbeat end)
    assert(result == nil, "heartbeat did not run while request was pending")
    run_until(function() return result ~= nil end)
    assert(result[1].title == "Нейромант" and result[1].format == "epub")
end)

test("tap cancels a hung worker without success/error or late result", function()
    local succeeded, failed, cancelled
    local message = Ui.showLoadingMessage("Searching", true)
    UI:scheduleIn(0.04, function() UI:close(message) end)
    Async.run(function()
        ffi.C.usleep(10000000)
        return "late result"
    end, function() succeeded = true end, function() failed = true end, message, {
        on_cancel = function() cancelled = true end,
    })
    run_until(function() return cancelled end)
    assert(not succeeded and not failed and #h.killed() == 1)
    assert(message._annas_closed)
end)

test("deadline terminates a hung request and reports timeout", function()
    local failure, success
    Async.run(function() ffi.C.usleep(10000000) end,
        function() success = true end, function(err) failure = err end,
        Ui.showLoadingMessage("Searching", true), { timeout_seconds = 0.05 })
    run_until(function() return failure ~= nil end)
    assert(failure:find("timed out", 1, true) and not success and #h.killed() == 1)
end)

test("cancel kills shell and curl/wget-like descendants too", function()
    local marker = os.tmpname()
    os.remove(marker)
    local message = Ui.showLoadingMessage("Downloading", true)
    local cancelled
    UI:scheduleIn(0.08, function() UI:close(message) end)
    Async.run(function()
        -- Delayed output stands in for a network command still running.
        local pipe = assert(io.popen("sleep 0.4; printf stale > '" .. marker .. "'; printf result", "r"))
        local data = pipe:read("*a")
        pipe:close()
        return data
    end, function() error("cancelled task delivered a result") end,
        function(err) error(err) end, message, {
            on_cancel = function() cancelled = true end,
        })
    run_until(function() return cancelled end)
    ffi.C.usleep(500000)
    local file = io.open(marker, "r")
    if file then file:close(); os.remove(marker) end
    assert(file == nil, "descendant command continued after cancellation")
end)

test("child exception is reported and closes loading widget", function()
    local failure
    Async.run(function() error("network failure") end,
        function() error("unexpected success") end, function(err) failure = err end,
        Ui.showLoadingMessage("Searching", true))
    run_until(function() return failure ~= nil end)
    assert(failure:find("network failure", 1, true))
end)

test("download path and filesystem changes reach parent", function()
    local path, result = os.tmpname()
    os.remove(path)
    Async.run(function()
        local file = assert(io.open(path .. ".part", "wb"))
        assert(file:write("ebook-test-bytes"))
        file:close()
        assert(os.rename(path .. ".part", path))
        return path
    end, function(value) result = value end, function(err) error(err) end,
        Ui.showLoadingMessage("Downloading", true), { timeout_seconds = 300 })
    run_until(function() return result ~= nil end)
    local file = assert(io.open(result, "rb"))
    assert(file:read("*a") == "ebook-test-bytes")
    file:close()
    os.remove(path)
end)

test("fork failure is an error, not silent cancellation", function()
    local original = native.runInSubProcess
    native.runInSubProcess = function() return false, "fork failed" end
    local failure
    Async.run(function() error("must not run in UI process") end,
        function() error("unexpected success") end, function(err) failure = err end,
        Ui.showLoadingMessage("Searching", true))
    native.runInSubProcess = original
    assert(failure == "Could not start the background task.")
end)

test("worker exit without data is reported", function()
    local failure
    Async.run(function() ffi.C._exit(1) end,
        function() error("unexpected success") end, function(err) failure = err end,
        Ui.showLoadingMessage("Searching", true))
    run_until(function() return failure ~= nil end)
    assert(failure == "The background task ended without a result.")
end)

test("repeat cancellation and retry do not leak widgets or callbacks", function()
    for i = 1, 3 do
        local message = Ui.showLoadingMessage("Searching", true)
        local cancelled
        UI:scheduleIn(0.01, function() UI:close(message) end)
        Async.run(function() ffi.C.usleep(10000000) end,
            function() error("unexpected success") end, function(err) error(err) end,
            message, { on_cancel = function() cancelled = true end })
        run_until(function() return cancelled end)
        assert(message._annas_closed and message.dismiss_callback == nil)
        Ui.closeMessage(message) -- must be harmless when already closed
    end
    local result
    Async.run(function() return {} end,
        function(value) result = value end, function(err) error(err) end,
        Ui.showLoadingMessage("Searching", true))
    run_until(function() return result ~= nil end)
    assert(type(result) == "table" and #result == 0)
end)

test("structured API errors use error callback", function()
    local failure
    Async.run(function() return {error = "HTTP 503"} end,
        function() error("unexpected success") end, function(err) failure = err end,
        Ui.showLoadingMessage("Searching", true))
    run_until(function() return failure ~= nil end)
    assert(failure == "HTTP 503")
end)

for _, warning in ipairs(warnings) do
    assert(warning[1] ~= "error in wrapped function:", tostring(warning[2]))
    assert(not tostring(warning[1]):find("unwrapped", 1, true), "Trapper ran without wrap()")
end
print(string.format("%d integration tests passed", h.count()))
return { UI = UI, Ui = Ui, test = test, run_until = run_until, native = native, finish = finish }
