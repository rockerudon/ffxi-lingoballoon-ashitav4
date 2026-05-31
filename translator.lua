local translator = {}

local addon_dir = nil
local cache_file = nil
local initialized = false

local copas = nil
local socket = nil
local url_mod = nil
local json_mod = nil

local MAX_INFLIGHT = 4
local MAX_QUEUE = 64
local CONNECT_TIMEOUT = 5
local SEND_TIMEOUT = 5
local RECEIVE_TIMEOUT = 8

translator.cache = {}
translator.pending = {}
translator.queue = {}
translator.inflight = 0
translator.tick = 0
translator.cache_dirty = false

local function normalize_path(path)
    return tostring(path or ''):gsub('\\', '/')
end

local function prepend_paths()
    local base = addon and addon.path or nil
    if (base == nil or base == '') and AshitaCore ~= nil then
        base = string.format('%s/addons/%s', AshitaCore:GetInstallPath(), addon.name)
    end

    base = normalize_path(base or '.')
    local install = AshitaCore and normalize_path(AshitaCore:GetInstallPath()) or ''
    local lingoxi = install ~= '' and string.format('%s/addons/LingoXI', install) or ''
    local lingoxi_lower = install ~= '' and string.format('%s/addons/lingoxi', install) or ''

    package.path = table.concat({
        string.format('%s/?.lua', base),
        string.format('%s/libs/?.lua', base),
        string.format('%s/libs/?/init.lua', base),
        string.format('%s/libs/?/?.lua', base),
        string.format('%s/?.lua', lingoxi),
        string.format('%s/libs/?.lua', lingoxi),
        string.format('%s/libs/?/init.lua', lingoxi),
        string.format('%s/libs/?/?.lua', lingoxi),
        string.format('%s/?.lua', lingoxi_lower),
        string.format('%s/libs/?.lua', lingoxi_lower),
        string.format('%s/libs/?/init.lua', lingoxi_lower),
        string.format('%s/libs/?/?.lua', lingoxi_lower),
        package.path,
    }, ';')
    package.cpath = table.concat({
        string.format('%s/libs/?.dll', base),
        string.format('%s/libs/socket/?.dll', base),
        string.format('%s/libs/?/core.dll', base),
        string.format('%s/libs/?/?.dll', base),
        string.format('%s/libs/?.dll', lingoxi),
        string.format('%s/libs/socket/?.dll', lingoxi),
        string.format('%s/libs/?/core.dll', lingoxi),
        string.format('%s/libs/?/?.dll', lingoxi),
        string.format('%s/libs/?.dll', lingoxi_lower),
        string.format('%s/libs/socket/?.dll', lingoxi_lower),
        string.format('%s/libs/?/core.dll', lingoxi_lower),
        string.format('%s/libs/?/?.dll', lingoxi_lower),
        package.cpath,
    }, ';')

    return base
end

local function ensure_modules()
    if copas ~= nil then
        return true
    end

    addon_dir = prepend_paths()
    cache_file = cache_file or string.format('%s/translation_cache.tsv', addon_dir)

    local ok_socket, socket_mod = pcall(require, 'socket')
    local ok_copas, copas_mod = pcall(require, 'copas')
    local ok_url, url_module = pcall(require, 'socket.url')

    if not ok_copas or not ok_socket then
        return false
    end

    copas = copas_mod
    socket = socket_mod
    url_mod = ok_url and url_module or nil

    local ok_json, loaded_json = pcall(require, 'json')
    if ok_json then
        json_mod = loaded_json
    else
        local ok_wjson, loaded_wjson = pcall(require, 'wlibs.json')
        if ok_wjson then
            json_mod = loaded_wjson
        end
    end

    return true
end

local function norm_lang(value, fallback)
    local s = tostring(value or ''):lower():gsub('%s+', '')
    if s == '' then
        return fallback
    end
    return s
end

local function cache_escape(value)
    return tostring(value or '')
        :gsub('\\', '\\\\')
        :gsub('\r', '\\r')
        :gsub('\n', '\\n')
        :gsub('\t', '\\t')
end

local function cache_unescape(value)
    return tostring(value or ''):gsub('\\([\\rnt])', function(ch)
        if ch == 'r' then
            return '\r'
        elseif ch == 'n' then
            return '\n'
        elseif ch == 't' then
            return '\t'
        end
        return '\\'
    end)
end

local function decode_unicode(str)
    return tostring(str or ''):gsub('\\u(%x%x%x%x)', function(h)
        local n = tonumber(h, 16)
        if n < 0x80 then
            return string.char(n)
        elseif n < 0x800 then
            return string.char(
                0xC0 + math.floor(n / 0x40),
                0x80 + (n % 0x40)
            )
        end

        return string.char(
            0xE0 + math.floor(n / 0x1000),
            0x80 + (math.floor(n / 0x40) % 0x40),
            0x80 + (n % 0x40)
        )
    end)
end

local function decode_json_string(str)
    str = decode_unicode(str)
    str = str:gsub('\\r', '\r')
    str = str:gsub('\\n', '\n')
    str = str:gsub('\\t', '\t')
    str = str:gsub('\\"', '"')
    str = str:gsub('\\/', '/')
    str = str:gsub('\\\\', '\\')
    return str
end

local function urlencode(str)
    if url_mod and url_mod.escape then
        return url_mod.escape(str)
    end

    return (tostring(str or ''):gsub('([^%w%-_%.~ ])', function(c)
        return string.format('%%%02X', string.byte(c))
    end):gsub(' ', '%%20'))
end

local function parse_json(body)
    if type(json_mod) ~= 'table' then
        return nil
    end

    local parser = json_mod.decode or json_mod.parse
    if type(parser) ~= 'function' then
        return nil
    end

    local ok, data = pcall(parser, body)
    if ok then
        return data
    end

    return nil
end

local function extract_translation(body)
    local data = parse_json(body)
    if type(data) == 'table' and type(data[1]) == 'table' then
        local parts = {}
        for _, segment in ipairs(data[1]) do
            if type(segment) == 'table' and segment[1] then
                parts[#parts + 1] = decode_json_string(segment[1])
            end
        end
        if #parts > 0 then
            return table.concat(parts)
        end
    end

    local parts = {}
    for text in tostring(body or ''):gmatch('%[%s*"(.-)"%s*,%s*"') do
        parts[#parts + 1] = decode_json_string(text)
    end

    if #parts > 0 then
        return table.concat(parts)
    end

    return nil
end

local function strip_balloon_tags(text)
    local value = tostring(text or '')
    value = value:gsub('\\cs%([^%)]*%)', '')
    value = value:gsub('\\cr', '')
    value = value:gsub('\r\n', '\n')
    value = value:gsub('\r', '\n')
    value = value:gsub('[ \t]+\n', '\n')
    value = value:gsub('\n[ \t]+', '\n')
    return value:trimex()
end

local function should_translate(text)
    if text == nil or text == '' then
        return false
    end
    return text:match('%w') ~= nil or text:match('[\128-\255]') ~= nil
end

local function make_key(src, tgt, text)
    return table.concat({ src, tgt, text }, '\31')
end

local function http_get(host, path)
    local tcp, err = socket.tcp()
    if not tcp then
        return nil, err
    end

    tcp:settimeout(0)
    local stream = copas.wrap(tcp)
    if type(stream.settimeouts) == 'function' then
        stream:settimeouts(CONNECT_TIMEOUT, SEND_TIMEOUT, RECEIVE_TIMEOUT)
    elseif type(stream.settimeout) == 'function' then
        stream:settimeout(RECEIVE_TIMEOUT)
    end

    local ok, connect_err = stream:connect(host, 80)
    if not ok then
        return nil, connect_err
    end

    local request = table.concat({
        'GET ' .. path .. ' HTTP/1.1',
        'Host: ' .. host,
        'User-Agent: LingoBalloon-copas',
        'Accept: application/json',
        'Accept-Encoding: identity',
        'Connection: close',
        '\r\n',
    }, '\r\n')
    stream:send(request)

    local status = stream:receive('*l')
    if not status then
        return nil, 'no status'
    end

    local code = tonumber(status:match('^HTTP/%d%.%d%s+(%d%d%d)')) or 0
    local headers = {}

    while true do
        local line = stream:receive('*l')
        if not line or line == '' then
            break
        end

        local key, value = line:match('^(.-):%s*(.*)$')
        if key and value then
            headers[string.lower(key)] = value
        end
    end

    local body = {}
    if headers['transfer-encoding'] == 'chunked' then
        while true do
            local size_line = stream:receive('*l')
            if not size_line then
                break
            end

            local size = tonumber(size_line, 16)
            if not size or size == 0 then
                stream:receive('*l')
                break
            end

            local chunk = stream:receive(size)
            if chunk and #chunk > 0 then
                body[#body + 1] = chunk
            end
            stream:receive('*l')
        end
    else
        local length = tonumber(headers['content-length'])
        if length and length > 0 then
            local data = stream:receive(length)
            if data and #data > 0 then
                body[#body + 1] = data
            end
        else
            while true do
                local chunk, read_err, partial = stream:receive(1024)
                chunk = chunk or partial
                if chunk and #chunk > 0 then
                    body[#body + 1] = chunk
                end
                if read_err == 'closed' then
                    break
                end
                if read_err and read_err ~= 'timeout' then
                    break
                end
            end
        end
    end

    return table.concat(body), code
end

local pump_queue

local function finish_job(job, translated)
    local result = translated
    if result == nil or result == '' then
        result = job.original
    elseif result == job.send then
        result = job.original
    end

    if translated and translated ~= '' then
        translator.cache[job.key] = translated
        translator.cache_dirty = true
    end

    local callbacks = job.callbacks or {}
    translator.pending[job.key] = nil

    for _, callback in ipairs(callbacks) do
        pcall(callback, result)
    end
end

pump_queue = function()
    if not ensure_modules() then
        return
    end

    while translator.inflight < MAX_INFLIGHT and #translator.queue > 0 do
        local job = table.remove(translator.queue, 1)
        translator.inflight = translator.inflight + 1

        copas.addthread(function()
            local translated = nil
            local path = '/translate_a/single?client=gtx&sl=' .. job.source
                .. '&tl=' .. job.target
                .. '&dt=t&q=' .. urlencode(job.send)

            local body, code = http_get('translate.googleapis.com', path)
            if code == 200 and type(body) == 'string' then
                translated = extract_translation(body)
            end

            finish_job(job, translated)

            translator.inflight = translator.inflight - 1
            if translator.inflight <= 0 and #translator.queue == 0 then
                translator.save_cache()
            end
            pump_queue()
        end)
    end
end

function translator.init(path)
    addon_dir = normalize_path(path or addon_dir or '')
    prepend_paths()
    cache_file = string.format('%s/translation_cache.tsv', addon_dir)

    if not ensure_modules() then
        return false
    end

    if initialized then
        return true
    end

    translator.load_cache()
    initialized = true
    return true
end

function translator.load_cache()
    if cache_file == nil then
        return
    end

    local file = io.open(cache_file, 'r')
    if not file then
        return
    end

    for line in file:lines() do
        local key, value = line:match('^(.-)\t(.*)$')
        if key and value then
            translator.cache[cache_unescape(key)] = cache_unescape(value)
        end
    end

    file:close()
end

function translator.save_cache()
    if cache_file == nil or not translator.cache_dirty then
        return
    end

    local file = io.open(cache_file, 'w')
    if not file then
        return
    end

    for key, value in pairs(translator.cache) do
        file:write(cache_escape(key))
        file:write('\t')
        file:write(cache_escape(value))
        file:write('\n')
    end

    file:close()
    translator.cache_dirty = false
end

function translator.clear_cache()
    translator.cache = {}
    translator.cache_dirty = true
    translator.save_cache()
end

function translator.cache_count()
    local count = 0
    for _ in pairs(translator.cache) do
        count = count + 1
    end
    return count
end

function translator.translate(text, settings, callback)
    settings = settings or {}
    if settings.translate_enabled == false then
        return text
    end

    if not ensure_modules() then
        return text
    end

    local source = norm_lang(settings.translation_source, 'auto')
    local target = norm_lang(settings.translation_target, 'pt')
    if target == '' then
        return text
    end

    local send_text = strip_balloon_tags(text)
    if not should_translate(send_text) then
        return text
    end

    local key = make_key(source, target, send_text)
    local cached = translator.cache[key]
    if cached ~= nil then
        if cached == send_text then
            return text
        end
        return cached
    end

    if translator.pending[key] ~= nil then
        if type(callback) == 'function' then
            table.insert(translator.pending[key].callbacks, callback)
        end
        return nil
    end

    if #translator.queue >= MAX_QUEUE then
        return text
    end

    local job = {
        key = key,
        source = source,
        target = target,
        send = send_text,
        original = text,
        callbacks = type(callback) == 'function' and { callback } or {},
    }

    translator.pending[key] = job
    table.insert(translator.queue, job)
    pump_queue()

    return nil
end

function translator.step(settings)
    if copas == nil then
        return
    end

    translator.tick = translator.tick + 1
    local interval = tonumber(settings and settings.translation_copas_interval) or 1
    interval = math.max(1, interval)

    if translator.tick % interval == 0 then
        pcall(copas.step, 0)
    end
end

function translator.shutdown()
    translator.save_cache()
end

return translator
