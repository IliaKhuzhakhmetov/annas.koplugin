local h = dofile("tests/headless.lua")
local test, UI, run_until = h.test, h.UI, h.run_until
local ffi = require("ffi")
local U = require("annas.cover_utils")
local root = os.tmpname()
os.remove(root)
local directory = root .. "/cache/annas-covers"
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local function mkdir(path) assert(os.execute("mkdir -p " .. quote(path)) == 0) end
mkdir(directory)
package.loaded.util.makePath = mkdir
package.preload.datastorage = function() return {getFullDataDir = function() return root end} end
local mtimes = {}
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            if path == directory then
                if field == "mode" then return "directory" end
                return {mode = "directory", modification = os.time()}
            end
            local file = io.open(path, "rb")
            if not file then return nil end
            local size = file:seek("end")
            file:close()
            local a = {mode = "file", size = size, modification = mtimes[path] or os.time()}
            return field and a[field] or a
        end,
        dir = function(path)
            local process = assert(io.popen("ls -1 " .. quote(path), "r"))
            local names = {}
            for name in process:lines() do names[#names + 1] = name end
            process:close()
            local i = 0
            return function() i = i + 1; return names[i] end
        end,
    }
end
local responses, calls = {}, {}
package.preload["annas.api"] = function()
    return {makeHttpRequest = function(options)
        calls[#calls + 1] = options.url
        local response = responses[options.url]
        if not response then return {error = "HTTP 404", status_code = 404} end
        local bytes = response.body
        if options.on_headers then
            options.on_headers(response.headers or (response.no_length and {} or {["content-length"] = tostring(#bytes)}))
        end
        if response.delay then ffi.C.usleep(response.delay) end
        local chunk_size = response.chunk_size or math.max(1, #bytes)
        for first = 1, #bytes, chunk_size do
            if not options.sink(bytes:sub(first, first + chunk_size - 1)) then return {error = "response too large"} end
            if response.chunk_delay then ffi.C.usleep(response.chunk_delay) end
        end
        options.sink(nil)
        return {status_code = 200}
    end}
end
local Cache = require("annas.cover_cache")
local Loader = require("annas.cover_loader")
local png = ("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082")
    :gsub("..", function(hex) return string.char(tonumber(hex, 16)) end)
local function book(n)
    return {md5 = string.format("%032x", n), cover_page = "https://books.test/ads.php?md5=" .. n}
end
local function serve(b, delay)
    local image = "https://books.test/covers/" .. b.md5 .. ".png"
    responses[b.cover_page] = {body = '<img src="/img/logo.png"><img src="' .. image .. '">'}
    responses[image] = {body = png, delay = delay}
    return image
end

test("cover HTML skips logo and blank images", function()
    assert(U.extract_image('<img src="/img/logo.png"><img src="/fictioncovers/1/book.jpg" width=300>', "https://books.test/ads.php")
        == "https://books.test/fictioncovers/1/book.jpg")
    assert(U.extract_image('<img src="/img/blank.png">', "https://books.test") == nil)
end)

test("lazy, relative and unquoted image URLs", function()
    assert(U.extract_image('<IMG data-src="//cdn.test/covers/a.jpg?a=1&amp;b=2" src="/blank.png">', "https://books.test/search")
        == "https://cdn.test/covers/a.jpg?a=1&b=2")
    assert(U.extract_image('<img src=../covers/a.png>', "https://books.test/details/a") == "https://books.test/covers/a.png")
    assert(U.absolute_url("../../covers/a.png", "https://books.test/details/a") == "https://books.test/covers/a.png")
    assert(U.absolute_url("javascript:alert(1)", "https://books.test") == nil)
    assert(U.absolute_url("data:image/png;base64,AAAA", "https://books.test") == nil)
end)

test("cache keys reject paths and HTML is never treated as an image", function()
    assert(U.key{md5 = "../outside"} == nil)
    assert(U.key{md5 = string.rep("A", 32)} == string.rep("a", 32))
    assert(U.image_type("<html>403 Forbidden</html>") == nil)
    assert(U.image_type(png) == "png")
end)

test("cover fetch saves atomically and reuses cached bytes", function()
    local b = book(1)
    serve(b)
    local before = #calls
    local path = assert(Cache.fetch(b))
    assert(path == directory .. "/" .. b.md5 .. ".png")
    local file = assert(io.open(path, "rb"))
    assert(file:read("*a") == png)
    file:close()
    assert(not io.open(directory .. "/" .. b.md5 .. ".part", "r"))
    assert(#calls == before + 2)
    assert(Cache.fetch(b) == path and #calls == before + 2)
end)

test("direct Anna image URL avoids metadata request", function()
    local b = book(2)
    b.cover_url = serve(b)
    local before = #calls
    assert(Cache.fetch(b))
    assert(#calls == before + 1)
end)

test("edition page is a fallback when download page lacks a cover", function()
    local b = book(3)
    b.edition_url = "https://books.test/edition.php?id=3"
    local image = serve(b)
    responses[b.cover_page] = {body = '<img src="/img/blank.png">'}
    responses[b.edition_url] = {body = '<img src="' .. image .. '">'}
    assert(Cache.fetch(b))
end)

test("missing images are retried after a short negative-cache TTL", function()
    local b = book(4)
    assert(Cache.fetch(b) == nil)
    assert(not Cache.should_fetch(b))
    mtimes[directory .. "/" .. b.md5 .. ".miss"] = os.time() - 301
    assert(Cache.should_fetch(b))
end)

test("Anna exact-file page is used when LibGen has no image", function()
    local b = book(7)
    b.annas_page = "https://en.annas-archive.test/md5/" .. b.md5
    local image = serve(b)
    responses[b.cover_page] = {body = '<img src="/img/blank.png">'}
    responses[b.annas_page] = {body = '<img data-src="' .. image .. '">'}
    assert(Cache.fetch(b))
    local html = '<a href="' .. b.annas_page .. '">Anna</a>'
    assert(U.extract_anna_page(html, "https://libgen.test", b.md5) == b.annas_page)
    assert(U.extract_anna_page(html, "https://libgen.test", string.rep("f", 32)) == nil)
end)

test("HTML response and oversized image do not become cache entries", function()
    for n, bytes in pairs{[5] = "<html>bot check</html>", [6] = png .. string.rep("x", 1024 * 1024)} do
        local b = book(n)
        local image = serve(b)
        responses[image] = {body = bytes}
        assert(Cache.fetch(b) == nil and Cache.get(b) == nil)
    end
end)

test("background covers leave UI interactive and publish completed files", function()
    local b = book(10)
    serve(b, 300000)
    local loader = Loader:new()
    local heartbeat, updated
    UI:scheduleIn(0.03, function() heartbeat = true end)
    loader:start({b}, function() updated = true end)
    run_until(function() return heartbeat end)
    assert(not updated, "cover loading blocked UI until completion")
    run_until(function() return updated and loader.pid == nil end)
    assert(Cache.get(b))
end)

test("page change cancels old cover worker without stale repaint", function()
    local old, new = book(11), book(12)
    serve(old, 10000000)
    serve(new)
    local loader = Loader:new()
    local stale, updated
    loader:start({old}, function() stale = true end)
    UI:scheduleIn(0.03, function()
        loader:start({new}, function() updated = true end)
    end)
    run_until(function() return updated and loader.pid == nil end)
    assert(not stale and Cache.get(new) and not Cache.get(old))
end)

test("closing cover loader removes timers and terminates its worker", function()
    local b = book(13)
    serve(b, 10000000)
    local loader = Loader:new()
    local stopped
    loader:start({b}, function() error("closed menu received a repaint") end)
    UI:scheduleIn(0.02, function() loader:stop(); stopped = true end)
    run_until(function() return stopped end)
    assert(loader.pid == nil and Cache.get(b) == nil)
end)

test("cover deadline kills stalled metadata/image requests", function()
    local b = book(14)
    serve(b, 10000000)
    local loader = Loader:new()
    loader:start({b}, function() assert(loader.states[b.md5].stage == "timeout") end)

    UI:unschedule(loader.deadline)
    UI:scheduleIn(0.03, loader.deadline)
    run_until(function() return loader.pid == nil end)
    assert(Cache.get(b) == nil)
end)

test("scraper preserves exact-edition cover metadata", function()
    local config = package.loaded["annas.config"]
    config.getSearchOrder = function() return {} end
    config.getSearchLanguages = function() return {} end
    config.getSearchExtensions = function() return {} end
    config.getLibgenTopics = function() return {} end
    config.getLibgenMaxPages = function() return 1 end
    local b = book(20)
    local html = '<title>Library Genesis</title><table><tr><td><a href="edition.php?id=42">A book</a></td><td>An author</td><td>Publisher</td><td>2024</td><td>English</td><td>100</td><td>1 MB</td><td>epub</td><td><a href="ads.php?md5=' .. b.md5 .. '">Get</a></td></tr></table>'
    assert(loadfile((arg[1] or "annas.koplugin") .. "/src/scraper.lua"))("src.scraper")
    local requests = 0
    check_url = function() requests = requests + 1; return "success", html end
    local books = scraper("A book")
    assert(#books == 1 and requests == 1, "search fetched extra pages for covers")
    assert(books[1].edition_url == "https://libgen.gl/edition.php?id=42")
    assert(books[1].cover_page == "https://libgen.gl/ads.php?md5=" .. b.md5)
end)

local Base = {}
Base.__index = Base
function Base:extend(class) class.__index = class; return setmetatable(class, {__index = self}) end
function Base:new(options)
    local instance = setmetatable(options, self)
    instance:init()
    return instance
end
function Base:init()
    self.page, self.perpage = 1, self.items_per_page
    self:updateItems()
end
function Base:_recalculateDimen() self.item_dimen = {w = 600, h = 120} end
function Base:updateItems()
    self:_recalculateDimen()
    self.updates = (self.updates or 0) + 1
end
function Base:onCloseWidget() self.base_closed = true end
package.loaded["annas.menu"] = Base
for name, kind in pairs{
    ["ui/widget/imagewidget"] = "image",
    ["ui/widget/container/framecontainer"] = "placeholder",
    ["ui/widget/container/centercontainer"] = "center",
    ["ui/widget/textwidget"] = "text",
    ["ui/widget/textboxwidget"] = "text",
} do
    package.preload[name] = function()
        return {new = function(_, options) options.kind = kind; return options end}
    end
end
package.preload["ui/font"] = function() return {getFace = function() return {} end} end
package.preload["ui/geometry"] = function() return {new = function(_, options) return options end} end
package.preload.device = function() return {screen = {scaleBySize = function(_, value) return value end}} end
local CoverMenu = require("annas.cover_menu")

test("menu shows six rows, adds cached images and retries cancelled pages", function()
    local items = {}
    for n = 30, 37 do
        local b = book(n)
        serve(b, 100000)
        items[#items + 1] = {text = "Book " .. n, original_book_data_ref = b}
    end
    local menu = CoverMenu:new{item_table = items}
    assert(menu.perpage == 6 and menu.state_w > 0)
    assert(items[1].state.kind == "placeholder" and items[7].state == nil)
    run_until(function() return menu.updates > 1 end)
    assert(items[1].state.kind == "image" and items[1].state.scale_factor == 0)
    menu.page = 2
    menu:updateItems()
    run_until(function() return items[7].state.kind == "image" end)
    menu.page = 1
    menu:updateItems()
    run_until(function() return items[6].state.kind == "image" and menu._cover_loader.pid == nil end)
    menu:onCloseWidget()
    assert(menu.base_closed)
end)

test("closing results before next tick prevents cover loading", function()
    local b = book(40)
    serve(b)
    local menu = CoverMenu:new{item_table = {{text = "Book", original_book_data_ref = b}}}
    menu:onCloseWidget()
    assert(menu._cover_loader.pid == nil and Cache.get(b) == nil)
end)

assert(os.execute("rm -rf " .. quote(root)) == 0)
print("16 cover integration tests passed")
return {h = h, UI = UI, test = test, run_until = run_until, root = root, directory = directory,
    responses = responses, calls = calls, Cache = Cache, Loader = Loader,
    CoverMenu = CoverMenu, book = book, serve = serve, mkdir = mkdir, png = png, quote = quote}
