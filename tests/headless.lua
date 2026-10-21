local plugin_dir = arg[1] or "annas.koplugin"
package.path = plugin_dir .. "/?.lua;" .. plugin_dir .. "/?/init.lua;" .. package.path
io.stdout:setvbuf("no")
local ffi = require("ffi")
ffi.cdef[[
struct timeval { long tv_sec; int tv_usec; };
int gettimeofday(struct timeval *, void *);
]]
local function now()
    local tv = ffi.new("struct timeval")
    ffi.C.gettimeofday(tv, nil)
    return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1000000
end
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end

local warnings = {}
package.preload.logger = function()
    local function ignore() end
    return { dbg = ignore, info = ignore, err = ignore,
        warn = function(...) warnings[#warnings + 1] = {...} end }
end
package.preload.gettext = function() return function(text) return text end end
package.preload["annas.gettext"] = package.preload.gettext

local UI = { events = {}, widgets = {}, standby = 0 }
function UI:scheduleIn(seconds, fn)
    self.events[#self.events + 1] = { at = now() + seconds, fn = fn }
end
function UI:nextTick(fn) self:scheduleIn(0, fn) end
function UI:unschedule(fn)
    for i = #self.events, 1, -1 do
        if self.events[i].fn == fn then table.remove(self.events, i) end
    end
end
function UI:show(widget)
    self.widgets[widget] = true
    if widget.onShow then widget:onShow() end
end
function UI:close(widget)
    if not self.widgets[widget] then return end
    self.widgets[widget] = nil
    if widget.onCloseWidget then widget:onCloseWidget() end
end
function UI:preventStandby() self.standby = self.standby + 1 end
function UI:allowStandby() self.standby = self.standby - 1 end
function UI:forceRePaint() end
function UI:setDirty() end
package.preload["ui/uimanager"] = function() return UI end

local Info = {}
function Info:new(options)
    options.modal = true
    if options.dismissable == nil then options.dismissable = true end
    return setmetatable(options, { __index = self })
end
function Info:onShow()
    if self.timeout then
        self._timeout_func = function() UI:close(self) end
        UI:scheduleIn(self.timeout, self._timeout_func)
    end
end
function Info:onCloseWidget()
    if self._timeout_func then UI:unschedule(self._timeout_func) end
    if self.dismiss_callback then
        self.dismiss_callback()
        if not self.is_infomessage then self.dismiss_callback = nil end
    end
end
package.preload["ui/widget/infomessage"] = function() return Info end
package.preload["ui/widget/trapwidget"] = function() return Info end
for _, name in ipairs{
    "ui/widget/confirmbox", "ui/widget/textviewer", "ui/downloadmgr",
    "ui/widget/inputdialog", "ui/widget/buttondialog", "annas.menu",
    "annas.config", "annas.ota", "util",
} do
    package.preload[name] = function() return {} end
end

local native = dofile("tests/upstream/subprocess.lua")
local spawned, killed = {}, {}
local spawn = native.runInSubProcess
native.runInSubProcess = function(...)
    local pid, fd = spawn(...)
    if pid then spawned[#spawned + 1] = pid end
    return pid, fd
end
local terminate = native.terminateSubProcess
native.terminateSubProcess = function(pid)
    killed[#killed + 1] = pid
    return terminate(pid)
end
package.preload["ffi/util"] = function() return native end
local Ui = require("annas.ui")

local function run_until(predicate, limit)
    local deadline = now() + (limit or 2)
    while not predicate() do
        assert(now() < deadline, "test event loop timed out")
        local selected
        for i, event in ipairs(UI.events) do
            if not selected or event.at < UI.events[selected].at then selected = i end
        end
        if selected and UI.events[selected].at <= now() then
            local event = table.remove(UI.events, selected)
            event.fn()
        else
            ffi.C.usleep(1000)
        end
    end
end

local function finish()

    for _, pid in ipairs(spawned) do
        run_until(function() return native.isSubProcessDone(pid) end)
    end
    local pending = UI.events
    UI.events = {}
    for _, event in ipairs(pending) do event.fn() end
    assert(#UI.events == 0, "stale timer/callback after completion")
    assert(next(UI.widgets) == nil, "loading widget was left open")
    assert(UI.standby == 0, "standby inhibition leaked")
    spawned, killed = {}, {}
end

local count = 0
local function test(name, fn)
    fn()
    finish()
    count = count + 1
    print("PASS " .. name)
end

return { UI = UI, Ui = Ui, test = test, run_until = run_until, native = native, finish = finish,
    now = now, warnings = warnings, killed = function() return killed end, count = function() return count end }
