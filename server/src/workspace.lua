local fs = require 'bee.filesystem'
local async = require 'async'
local config = require 'config'
local ll = require 'lpeglabel'

local function split(str, sep)
    local t = {}
    for s in str:gmatch('[^' .. sep .. ']+') do
        t[#t+1] = s
    end
    return t
end

local function similarity(a, b)
    local ta = split(a, '/\\')
    local tb = split(b, '/\\')
    for i = 1, #ta do
        if ta[i] ~= tb[i] then
            return i - 1
        end
    end
    return #ta
end

local mt = {}
mt.__index = mt

function mt:uriDecode(uri)
    if uri:sub(1, 8) ~= 'file:///' then
        log.error('uri decode failed: ', uri)
        return nil
    end
    local names = {}
    for name in uri:sub(9):gmatch '[^%/]+' do
        names[#names+1] = name:gsub('%%([0-9a-fA-F][0-9a-fA-F])', function (hex)
            return string.char(tonumber(hex, 16))
        end)
    end
    if #names == 0 then
        log.error('uri decode failed: ', uri)
        return nil
    end
    -- 盘符后面加个斜杠
    local path = fs.path(names[1] .. '\\')
    for i = 2, #names do
        path = path / names[i]
    end
    return fs.absolute(path)
end

function mt:uriEncode(path)
    local names = {}
    local cur = fs.absolute(path)
    while true do
        local name = cur:filename():string()
        if name == '' then
            -- 盘符，去掉一个斜杠
            name = cur:string():sub(1, -2)
        end
        name = name:gsub([=[[^%w%-%_%.%~]]=], function (char)
            return ('%%%02X'):format(string.byte(char))
        end)
        table.insert(names, 1, name)
        if cur == cur:parent_path() then
            break
        end
        cur = cur:parent_path()
    end
    return 'file:///' .. table.concat(names, '/')
end

function mt:scanFiles()
    if self._scanRequest then
        log.info('中断上次扫描文件任务')
        self._scanRequest:push('stop')
        self._scanRequest = nil
        self._complete = false
        self:reset()
    end

    local ignored = {'.git'}
    for path in pairs(config.config.workspace.ignoreDir) do
        ignored[#ignored+1] = path
    end
    if config.config.workspace.ignoreSubmodules then
        local buf = io.load(self.root / '.gitmodules')
        if buf then
            for path in buf:gmatch('path = ([^\r\n]+)') do
                log.info('忽略子模块：', path)
                ignored[#ignored+1] = path
            end
        end
    end
    if config.config.workspace.useGitIgnore then
        local buf = io.load(self.root / '.gitignore')
        if buf then
            for line in buf:gmatch '[^\r\n]+' do
                ignored[#ignored+1] = line
            end
        end
    end

    log.info('忽略文件：\r\n' .. table.concat(ignored, '\r\n'))
    log.info('开始扫描文件任务')
    local compiled = {}
    local count = 0
    self._scanRequest = async.run('scanfiles', {
        root = self.root:string(),
        ignored = ignored,
    }, function (mode, ...)
        if mode == 'ok' then
            log.info('扫描文件任务完成，共', count, '个文件。')
            self._complete = true
            self._scanRequest = nil
            self:reset()
            return true
        elseif mode == 'log' then
            log.debug(...)
        elseif mode == 'file' then
            local file = ...
            local path = fs.path(file.path)
            local name = path:string():lower()
            local uri = self:uriEncode(path)
            self.files[name] = uri
            self.lsp:readText(uri, path, file.buf, compiled)
            count = count + 1
        elseif mode == 'stop' then
            log.info('扫描文件任务中断')
            return false
        end
    end)
end

function mt:init(rootUri)
    self.root = self:uriDecode(rootUri)
    self.uri = rootUri
    if not self.root then
        return
    end
    log.info('Workspace inited, root: ', self.root)
    local logPath = ROOT / 'log' / (rootUri:gsub('[/:]+', '_') .. '.log')
    log.info('Log path: ', logPath)
    log.init(ROOT, logPath)

    self:scanFiles()
end

function mt:isComplete()
    return not not self._complete
end

function mt:addFile(uri)
    if uri:sub(-4) == '.lua' then
        local path = self:uriDecode(uri)
        local name = path:string():lower()
        self.files[name] = uri
        self.lsp:readText(uri, path)
    end
end

function mt:removeFile(uri)
    local name = self:uriDecode(uri):string():lower()
    self.files[name] = nil
    self.lsp:removeText(uri)
end

function mt:findPath(baseUri, searchers)
    local results = {}
    for filename, uri in pairs(self.files) do
        for _, searcher in ipairs(searchers) do
            if filename:sub(-#searcher) == searcher then
                local sep = filename:sub(-#searcher-1, -#searcher-1)
                if sep == '/' or sep == '\\' then
                    results[#results+1] = uri
                end
            end
        end
    end

    if #results == 0 then
        return nil
    end
    local uri
    if #results == 1 then
        uri = results[1]
    else
        table.sort(results, function (a, b)
            return similarity(a, baseUri) > similarity(b, baseUri)
        end)
        uri = results[1]
    end
    return uri
end

function mt:createCompiler(str)
    local state = {
        'Main',
    }
    local function push(c)
        if state.Main then
            state.Main = state.Main * c
        else
            state.Main = c
        end
    end
    local count = 0
    local function code()
        count = count + 1
        local name = 'C' .. tostring(count)
        local nextName = 'C' .. tostring(count + 1)
        state[name] = ll.P(1) * (#ll.V(nextName) + ll.V(name))
        return ll.V(name)
    end
    local function static(c)
        count = count + 1
        local name = 'C' .. tostring(count)
        local nextName = 'C' .. tostring(count + 1)
        state[name] = ll.P(c) * #ll.V(nextName)
        return ll.V(name)
    end
    local function eof()
        count = count + 1
        local name = 'C' .. tostring(count)
        state[name] = ll.Cmt(ll.P(1) + ll.Cp(), function (_, _, c)
            return type(c) == 'number'
        end)
        return ll.V(name)
    end
    local isFirstCode = true
    local firstCode
    local compiler = ll.P {
        'Result',
        Result = (ll.V'Code' + ll.V'Static')^1,
        Code   = ll.P'?' / function ()
            if isFirstCode then
                isFirstCode = false
                push(ll.Cmt(ll.C(code()), function (_, pos, code)
                    firstCode = code
                    return pos, code
                end))
            else
                push(ll.Cmt(
                    ll.C(code()),
                    function (_, _, me)
                        return firstCode == me
                    end
                ))
            end
        end,
        Static = (1 - ll.P'?')^1 / function (c)
            push(static(c))
        end,
    }
    compiler:match(str)
    push(eof())
    return ll.P(state)
end

function mt:compileLuaPath()
    for i, luapath in ipairs(self.luapath) do
        self.pathMatcher[i] = self:createCompiler(luapath)
    end
end

function mt:convertPathAsRequire(filename, start)
    local list
    for _, matcher in ipairs(self.pathMatcher) do
        local str, a2, a3 = matcher:match(filename:sub(start))
        if str then
            if not list then
                list = {}
            end
            list[#list+1] = str:gsub('/', '.')
        end
    end
    return list
end

function mt:matchPath(baseUri, input)
    input = input:lower()
    local first = input:match '[^%.]+'
    if not first then
        return nil
    end
    local baseName = self:uriDecode(baseUri):string():lower()
    local rootLen = #self.root:string()
    local map = {}
    for filename in pairs(self.files) do
        local start = filename:find('/' .. first, rootLen + 1, true)
        if start then
            local list = self:convertPathAsRequire(filename, start + 1)
            if list then
                for _, str in ipairs(list) do
                    if #str >= #input and str:sub(1, #input) == input then
                        if not map[str] then
                            map[str] = filename
                        else
                            local s1 = similarity(filename, baseName)
                            local s2 = similarity(map[str], baseName)
                            if s1 > s2 then
                                map[str] = filename
                            elseif s1 == s2 then
                                if filename < map[str] then
                                    map[str] = filename
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local list = {}
    for str in pairs(map) do
        list[#list+1] = str
        map[str] = map[str]:sub(rootLen + 2)
    end
    if #list == 0 then
        return nil
    end
    table.sort(list, function (a, b)
        local sa = similarity(map[a], baseName)
        local sb = similarity(map[b], baseName)
        if sa == sb then
            return a < b
        else
            return sa > sb
        end
    end)
    return list, map
end

function mt:searchPath(baseUri, str)
    if self.searched[baseUri] and self.searched[baseUri][str] then
        return self.searched[baseUri][str]
    end
    str = str:gsub('%.', '/')
    local searchers = {}
    for i, luapath in ipairs(self.luapath) do
        searchers[i] = luapath:gsub('%?', str):lower()
    end

    local uri = self:findPath(baseUri, searchers)
    if uri then
        if not self.searched[baseUri] then
            self.searched[baseUri] = {}
        end
        self.searched[baseUri][str] = uri
    end
    return uri
end

function mt:loadPath(baseUri, str)
    str = fs.relative(fs.absolute(self.root / str), self.root):string():lower()
    if self.loaded[str] then
        return self.loaded[str]
    end

    local searchers = { str }

    local uri = self:findPath(baseUri, searchers)
    if uri then
        self.loaded[str] = uri
    end
    return uri
end

function mt:reset()
    self.searched = {}
    self.loaded = {}
    self.lsp:reCompile()
end

function mt:relativePathByUri(uri)
    local path = self:uriDecode(uri)
    local relate = fs.relative(path, self.root)
    return relate
end

return function (lsp, name)
    local workspace = setmetatable({
        lsp = lsp,
        name = name,
        files = {},
        searched = {},
        loaded = {},
        luapath = {
            '?.lua',
            '?/init.lua',
            '?/?.lua',
        },
        pathMatcher = {}
    }, mt)
    workspace:compileLuaPath()
    return workspace
end
