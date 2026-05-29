addon.name      = 'lingoballoon'
addon.author    = 'Originally by Hando, English support added by Yuki & Kenshi, themes added by Ghosty, ported to Ashita v4 by onimitch. Translation fork by rockerudon.'
addon.version   = '4.3.2-lingoballoon.1'
addon.desc      = 'Displays NPC dialogue in a cinematic balloon and translates it using LingoXI-inspired translation logic.'
addon.link      = 'https://github.com/rockmizx/ffxi-lingoballoon-ashitav4'

-- Ashita libs
require('common')
local chat = require('chat')
local settings = require('settings')
local encoding = require('gdifonts.encoding')

-- Windower lua libs
texts = require('wlibs.texts')
images = require('wlibs.images')
require('wlibs.sets')

-- Balloon files
local default_settings = require('defaults')
local theme = require('theme')
local ui = require('ui')
local tests = require('tests')
local defines = require('defines')
local helpers = require('helpers')
local translator = require('translator')


local chat_modes = defines.chat_modes
local chat_color_codes = defines.chat_color_codes

local balloon = {
    debug = 'off',
    debug_closing = false,
    waiting_to_close = false,
    close_timer = 0,
    last_text = '',
    last_mode = 0,
    processing_message = false,
    lang_code = 'en',
    settings = {},
    last_frame_time = 0,
    theme_options = nil,
    move_check_sensitivity = 0.01,
    in_mog_menu = false,
    in_menu = false,
    drag_offset = nil,
    accepted_chat_modes = {},
    auto_hide_game_ui = false,
    status_server = nil,
    auto_hide_after = 0,
    auto_hide_delay = 0.5,
    in_cinematic = false,
    in_event = false,
    last_known_target = nil,
    cinematic_ignore_targets = {
        'Garden Furrow',
    },
    limit_fps_enabled = false,
    limit_fps_restore = 2,
    translation_request_id = 0,
    translation_pending = false,
    translation_pending_time = 0,
    translation_pending_dots = 0,
    translation_pending_base = 'Translating',
}

-- parses a string into char[hex bytecode]
local function parse_codes(str)
	return (str:gsub('.', function (c)
		return string.format('[%02X]', string.byte(c))
	end))
end

-- TODO: Move into a lib/helpers file: game menu, event system, interface hidden, user camera.

-------------------------------------------------------------------------------

balloon.initialize = function(new_settings)
    -- Get game language
    local lang = AshitaCore:GetConfigurationManager():GetInt32('boot', 'ashita.language', 'playonline', 2)
    balloon.lang_code = lang == 1 and 'ja' or 'en'

    balloon.load_chat_mode_settings()

    -- Remove old filter setting
    if balloon.settings.filter ~= nil then
        balloon.settings.filter = nil
    end

	balloon.load_theme()

    if balloon.theme_options ~= nil and new_settings == nil then
        print(chat.header(addon.name):append(chat.message('Theme "%s" (%s)'):format(balloon.settings.theme, balloon.lang_code)))
    end

    if not helpers.stepdialog.available and balloon.settings.cinematic then
        print(chat.header(addon.name):append(chat.error('Unable to load stepdialog pointers for cinematic mode.')))
    end
end

balloon.load_chat_mode_settings = function()
    -- Default chat modes that are always on
    balloon.accepted_chat_modes = S{
        chat_modes.message,
        -- Note that although we have a setting to disable system messages, because some system messages appear
        -- during cutscenes and we always show those, we always accept them here first and filter out later.
        chat_modes.system,
    }

    -- System messages like Home Point etc
    if balloon.settings.system_messages then
        balloon.accepted_chat_modes:add(chat_modes.system)
    end

    -- Get additional chat modes from settings
    local additional_chat_modes = balloon.settings.additional_chat_modes or {}
    for _, v in ipairs(additional_chat_modes) do
        balloon.accepted_chat_modes:add(v)
    end

    -- local chat_mode_list = balloon.accepted_chat_modes:concat(' ')
    -- print(chat.header(addon.name):append(chat.message('chat modes: %s'):format(chat_mode_list)))
end

balloon.load_theme = function()
    -- Load the theme
    balloon.theme_options = theme.load(balloon.settings.theme, balloon.lang_code)
    if balloon.theme_options == nil then
        return
    end

    -- Load UI
	ui:load(balloon.settings, balloon.theme_options)
    ui:position(balloon.settings.position.x, balloon.settings.position.y)

    -- Display balloon if we changed theme while open
	if not ui:hidden() then
		balloon.process_balloon(balloon.last_text, balloon.last_mode)
	end
end

balloon.update_timer = function()
    if not balloon.waiting_to_close then
        return
    end
    if balloon.close_timer >= 0 then
        balloon.close_timer = math.max(0, balloon.close_timer - 1)
        ui.timer_text:text(balloon.close_timer..'')
    end

    if balloon.close_timer <= 0 then
        if balloon.debug_closing then print('Closing from timer') end
        balloon.close()
    else
        ashita.tasks.once(1, balloon.update_timer)
    end
end

balloon.open = function(timed)
	if timed then
		balloon.close_timer = balloon.settings.no_prompt_close_delay
		ui.timer_text:text(''..balloon.close_timer)
    else 
        balloon.close_timer = 0
        balloon.waiting_to_close = false
	end

	ui:show(timed)

    if timed and not balloon.waiting_to_close then
        balloon.waiting_to_close = true
        ashita.tasks.once(1, balloon.update_timer)
    end
end

balloon.close = function()
	ui:hide()

    balloon.waiting_to_close = false
    balloon.close_timer = 0
    balloon.in_mog_menu = false
    balloon.in_menu = false
    balloon.translation_pending = false
end

balloon.handle_player_movement = function(player_entity)
    local new_player_pos = {
        player_entity.Movement.LocalPosition.X,
        player_entity.Movement.LocalPosition.Y,
        player_entity.Movement.LocalPosition.Z,
    }

    if not ui:hidden() and balloon.settings.move_close then
        if balloon.player_pos == nil then
            if balloon.debug_closing then print('Closing from move') end
            balloon.close()
        else
            local moved = {
                new_player_pos[1] - balloon.player_pos[1],
                new_player_pos[2] - balloon.player_pos[2],
                new_player_pos[3] - balloon.player_pos[3],
            }
            for _, v in ipairs(moved) do
                if math.abs(v) > balloon.move_check_sensitivity then
                    if balloon.debug_closing then print('Closing from move') end
                    balloon.close()
                    break
                end
            end
        end
    end

    balloon.player_pos = new_player_pos
end

balloon.handle_cinematics = function(player_ent, delta_time)
    -- Ignore certain cinematics by checking the player's last known target
    local ignore = false
    if balloon.last_known_target ~= nil then
        for _, v in pairs(balloon.cinematic_ignore_targets) do
            if string.find(balloon.last_known_target, v) then
                ignore = true
                break
            end
        end
    end

    -- Detect if player is in a cinematic
    if not ignore and player_ent.StatusServer == 4 then
        -- In an event
        balloon.in_event = true

        if balloon.status_server ~= player_ent.StatusServer then
            -- Small delay to wait for StatusEvent to be updated
            balloon.auto_hide_after = balloon.auto_hide_delay
            -- TODO: Figure out which packet updates StatusEvent so we can listen for that instead
            balloon.status_server = player_ent.StatusServer
        elseif balloon.auto_hide_after > 0 then
            balloon.auto_hide_after = balloon.auto_hide_after - delta_time
            if balloon.auto_hide_after <= 0 then
                balloon.auto_hide_after = 0
            end
        elseif not helpers.is_user_camera_enabled() then
            -- In a cutscene
            balloon.in_cinematic = true
            balloon.limit_fps(true)

            if balloon.settings.cinematic and balloon.settings.display_mode > 0 then
                -- Show game UI if dialog option open
                if helpers.is_dialog_option_open() == balloon.auto_hide_game_ui then
                    balloon.auto_hide_game_ui = not balloon.auto_hide_game_ui
                    helpers.set_game_interface_hidden(balloon.auto_hide_game_ui)

                    -- Small delay before next change
                    balloon.auto_hide_after = balloon.auto_hide_delay
                end
            end
        else
            -- Not in a cutscene
            balloon.in_cinematic = false
            balloon.limit_fps(false)

            if balloon.auto_hide_game_ui then
                balloon.auto_hide_game_ui = false
                helpers.set_game_interface_hidden(false)
            end
        end
    else
        balloon.in_cinematic = false
        balloon.in_event = false
        balloon.limit_fps(false)

        if balloon.auto_hide_game_ui then
            balloon.auto_hide_game_ui = false
            helpers.set_game_interface_hidden(false)
        end
    end
end

balloon.handle_button_continue = function(e)
    if helpers.is_chat_open() then
        return
    end

    if not ui:hidden() then
        balloon.close()

        -- If the game UI is hidden, then ensure dialog continues
        if helpers.is_game_interface_hidden() and not helpers.is_dialog_option_open() then
            e.blocked = helpers.stepdialog.run()
        end
    end
end

balloon.limit_fps = function(enabled)
    enabled = enabled and balloon.settings.control_fps
    if balloon.limit_fps_enabled ~= enabled then
        if enabled then
            balloon.limit_fps_restore = helpers.get_fps_divisor()
            helpers.set_fps_divisor(2) -- 30fps
        else
            helpers.set_fps_divisor(balloon.limit_fps_restore)
        end
        balloon.limit_fps_enabled = enabled
    end
end

balloon.process_incoming_message = function(e)
    -- Obtain the chat mode..
    local mode = bit.band(e.mode, 0x000000FF)

	-- log debug info
	if S{'mode', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Mode: ' .. mode .. ' Text: ' .. e.message) end

	-- Check this message is one of the ones we're interested in
    if not balloon.accepted_chat_modes[mode] then
        if S{'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', ('Not accepted mode: %d'):format(mode)) end
        return
    end

    -- We handle system messsages in a special way here
    -- If the user has turned off system messages, we will ignore them but only when not in a cutscene.
    -- In other words cutscene system message are always displayed. This is mainly because they can be 
    -- easily missed if the user also has the UI hidden duuring cutscenes.
    if mode == chat_modes.system then
        if not balloon.in_cinematic and not balloon.settings.system_messages then
            return
        end
    end

    -- TODO: Check if this is correct, I think we should check it's actually a blank line, since currently this is only checking endswidth
	-- blank prompt line that auto-continues itself,
	-- usually used to clear a space for a scene change?
	if e.message:endswith(defines.AUTO_PROMPT_CHARS) then
        if balloon.debug_closing then 
            print('Closing from auto prompt chars')
            LogManager:Log(5, 'Balloon', 'Closed from ending with Auto prompt characters: ' .. parse_codes(e.message))
        end
		balloon.close()
		return
	end

	if balloon.settings.display_mode >= 1 then
        -- Do we need to check if the player is in combat?
        -- We only check if the player is engaged (has weapon out) but this should be enough for our use case.
        if not balloon.settings.in_combat and not helpers.is_event_system_active() then
            local entity = AshitaCore:GetMemoryManager():GetEntity()
            local party = AshitaCore:GetMemoryManager():GetParty()
            if entity ~= nil and party ~= nil then
                local player_index = party:GetMemberTargetIndex(0)
                if player_index ~= nil and entity:GetStatus(player_index) == 1 then
                    return
                end
            end
        end

        e.message_modified = balloon.process_balloon(e.message, mode)
    end
end

balloon.process_balloon = function(message, mode)
	balloon.last_text = message
	balloon.last_mode = mode

	-- detect whether messages have a prompt button
    local ends_with_prompt = false
    for _, v in ipairs(defines.PROMPT_CHARS) do
        ends_with_prompt = message:endswith(v)
        if ends_with_prompt then
            break
        end
    end
    local timed = (not balloon.in_menu and not ends_with_prompt)

	-- Extract speaker name
    local npc_prefix_start, npc_prefix_end = message:find('.- : ')
	local npc_prefix = ''
    if npc_prefix_start ~= nil then
        if npc_prefix_end < 32 and npc_prefix_start > 0 then
            npc_prefix = message:sub(npc_prefix_start, npc_prefix_end)
        end
	end
	local npc_name = npc_prefix:sub(0, #npc_prefix-2)
	npc_name = npc_name:trimex()

    -- pass through the original message for the log
    local result = message

	-- mode 1, blank log lines and visible balloon
	if balloon.settings.display_mode == 1 then
        -- Preserve ending prompt chars
        local end_of_text_pos = #message
        for _, prompt_chars in ipairs(defines.PROMPT_CHARS) do
            local prompt_pos, _ = message:find(prompt_chars, -4, true)
            if prompt_pos ~= nil then
                end_of_text_pos = prompt_pos
                break
            end
        end
        result = npc_prefix
        if npc_prefix ~= '' then
            result = result .. '...'
        end
        -- Preserve prompt chars
        if end_of_text_pos == #message then
            -- Empty message
        else
            result = result .. message:sub(end_of_text_pos)
        end
	end

    -- strip the NPC name from the start of the message
    if npc_prefix ~= '' then
        message = message:sub(npc_prefix_end)
    end

    -- log debug info
    if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'message: ' .. message) end
	if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'codes: ' .. parse_codes(message)) end
    if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'end codes shiftjis: ' .. parse_codes(message:sub(-4))) end

    -- Convert message to utf8
	message = balloon.convert_shiftjis_to_utf8(message)

	if S{'message+', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Pre-process: ' .. message) end
	if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'end codes utf8: ' .. parse_codes(message:sub(-4))) end

    -- TODO: Check if this is necessary (this was probably an issue with windower text color tags and opening with a \cr tag)
	-- strip the default color code from the start of messages,
	-- it causes the first part of the message to get cut off somehow
	local default_color = chat_color_codes.standard
	if string.sub(message, 1, #default_color) == default_color then
		message = string.sub(message, #default_color + 1)
	end

    -- Strip out prompt characters
    message = message:gsub(defines.auto_prompt_chars_pattern, '')
    message = message:gsub(defines.prompt_chars_pattern, '')

    message = message:gsub(chat_color_codes.standard, '[BL_c1]') --color code 1 (black/reset)
    message = message:gsub(chat_color_codes.item, '[BL_c2]') --color code 2 (green/regular items)
    message = message:gsub(chat_color_codes.key_item, '[BL_c3]') --color code 3 (blue/key items)
    message = message:gsub(chat_color_codes.blue, '[BL_c4]') --color code 4 (blue/???)
    message = message:gsub(chat_color_codes.magenta, '[BL_c5]') --color code 5 (magenta/equipment?)
    message = message:gsub(chat_color_codes.cyan, '[BL_c6]') --color code 6 (cyan/???)
    message = message:gsub(chat_color_codes.yellow, '[BL_c7]') --color code 7 (yellow/???)
    message = message:gsub(chat_color_codes.orange, '[BL_c8]') --color code 8 (orange/RoE objectives?)
    message = message:gsub(chat_color_codes.emote, '') --cutscene emote color code (handled by the message type instead)

    message = message:gsub('^?([%w%.\'(<“])', '%1')
    message = message:gsub('%f[-]%-%-%f[^-]', '—') --replace -- with em dashes

    message = message:gsub('%[BL_c1]', '\\cr')
    message = message:gsub('%[BL_c2]', '\\cs('..ui._type.items..')')
    message = message:gsub('%[BL_c3]', '\\cs('..ui._type.keyitems..')')
    message = message:gsub('%[BL_c4]', '\\cs('..ui._type.keyitems..')')
    message = message:gsub('%[BL_c5]', '\\cs('..ui._type.gear..')')
    message = message:gsub('%[BL_c6]', '\\cs(0,159,173)')
    message = message:gsub('%[BL_c7]', '\\cs(156,149,19)')
    message = message:gsub('%[BL_c8]', '\\cs('..ui._type.roe..')')
    --TODO: theme settings for these element colors
    message = message:gsub('%[BL_Fire]', '\\cs(255,0,0)Fire \\cr')
    message = message:gsub('%[BL_Ice]', '\\cs(0,255,255)Ice \\cr')
    message = message:gsub('%[BL_Wind]', '\\cs(0,255,0)Wind \\cr')
    message = message:gsub('%[BL_Earth]', '\\cs(153,76,0)Earth \\cr')
    message = message:gsub('%[BL_Lightning]', '\\cs(127,0,255)Lightning \\cr')
    message = message:gsub('%[BL_Water]', '\\cs(0,76,153)Water \\cr')
    message = message:gsub('%[BL_Light]', '\\cs(224,224,224)Light \\cr')
    message = message:gsub('%[BL_Dark]', '\\cs(82,82,82)Dark \\cr')
    -- Mid message line breaks
    message = message:gsub(string.char(0x07), '\n')


    if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'codes end: ' .. parse_codes(message:sub(-4))) end
	if S{'message', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Final: ' .. encoding:UTF8_To_ShiftJIS(message)) end


    if not ui:set_character(npc_name) then
		ui:set_type(mode)
	end
    local display_message, pending = balloon.translate_message(message)
    if pending then
        ui:set_pending_message(display_message)
    else
        ui:set_message(display_message)
    end
	balloon.open(timed)

	return result
end

balloon.pending_translation_base = function()
    local target = tostring(balloon.settings.translation_target or default_settings.translation_target or 'en'):lower()
    target = target:gsub('_', '-')
    local base_target = target:match('^([%a]+)') or target

    local labels = {
        af = 'Vertaal',
        am = 'መተርጎም',
        ar = 'جار الترجمة',
        az = 'Tərcümə edilir',
        be = 'Пераклад',
        bg = 'Превеждане',
        bn = 'অনুবাদ হচ্ছে',
        bs = 'Prevođenje',
        ca = 'Traduint',
        ceb = 'Gihubad',
        co = 'Traduzzione',
        cs = 'Překládání',
        cy = 'Cyfieithu',
        da = 'Oversætter',
        de = 'Übersetzen',
        el = 'Μετάφραση',
        pt = 'Traduzindo',
        en = 'Translating',
        es = 'Traduciendo',
        fr = 'Traduction',
        et = 'Tõlkimine',
        eu = 'Itzultzen',
        fa = 'در حال ترجمه',
        fi = 'Käännetään',
        fil = 'Isinasalin',
        ga = 'Á aistriú',
        gl = 'Traducindo',
        gu = 'અનુવાદ થઈ રહ્યો છે',
        ha = 'Ana fassara',
        haw = 'Ke unuhi nei',
        he = 'מתרגם',
        hi = 'अनुवाद हो रहा है',
        hmn = 'Txhais lus',
        hr = 'Prevođenje',
        ht = 'Tradiksyon',
        hu = 'Fordítás',
        hy = 'Թարգմանվում է',
        id = 'Menerjemahkan',
        ig = 'Na-atụgharị',
        is = 'Þýðir',
        it = 'Traduzione',
        ja = '翻訳中',
        jv = 'Nerjemahake',
        ka = 'ითარგმნება',
        kk = 'Аударылуда',
        km = 'កំពុងបកប្រែ',
        kn = 'ಅನುವಾದಿಸಲಾಗುತ್ತಿದೆ',
        ko = '번역 중',
        ku = 'Tercume dibe',
        ky = 'Которулууда',
        la = 'Vertitur',
        lb = 'Iwwersetzen',
        lo = 'ກຳລັງແປ',
        lt = 'Verčiama',
        lv = 'Tulko',
        mg = 'Mandika',
        mi = 'Whakamaori',
        mk = 'Преведување',
        ml = 'വിവർത്തനം ചെയ്യുന്നു',
        mn = 'Орчуулж байна',
        mr = 'भाषांतर होत आहे',
        ms = 'Menterjemah',
        mt = 'Qed jittraduċi',
        my = 'ဘာသာပြန်နေသည်',
        ne = 'अनुवाद हुँदैछ',
        nl = 'Vertalen',
        no = 'Oversetter',
        ny = 'Kumasulira',
        pa = 'ਅਨੁਵਾਦ ਹੋ ਰਿਹਾ ਹੈ',
        pl = 'Tlumaczenie',
        ps = 'ژباړه روانه ده',
        ro = 'Se traduce',
        ru = 'Перевод',
        sd = 'ترجمو ٿي رهيو آهي',
        si = 'පරිවර්තනය වෙමින්',
        sk = 'Prekladá sa',
        sl = 'Prevajanje',
        sm = 'Faaliliu',
        sn = 'Kushandura',
        so = 'Turjumid',
        sq = 'Përkthim',
        sr = 'Превођење',
        st = 'Ho fetolela',
        su = 'Narjamahkeun',
        sv = 'Översätter',
        sw = 'Inatafsiri',
        ta = 'மொழிபெயர்க்கிறது',
        te = 'అనువదిస్తోంది',
        tg = 'Тарҷума',
        th = 'กำลังแปล',
        tk = 'Terjime edilýär',
        tr = 'Cevriliyor',
        uk = 'Переклад',
        ur = 'ترجمہ ہو رہا ہے',
        uz = 'Tarjima qilinmoqda',
        vi = 'Đang dịch',
        xh = 'Kuguqulelwa',
        yi = 'איבערזעצן',
        yo = 'N tumo',
        ['zh'] = '翻译中',
        ['zh-cn'] = '翻译中',
        ['zh-tw'] = '翻譯中',
        zu = 'Iyahumusha',
    }

    return labels[target] or labels[base_target] or 'Translating'
end

balloon.pending_translation_text = function(dot_count)
    dot_count = math.max(1, math.min(3, dot_count or 1))
    return balloon.translation_pending_base .. string.rep('.', dot_count)
end

balloon.update_pending_translation = function(delta_time)
    if not balloon.translation_pending or ui:hidden() then
        return
    end

    balloon.translation_pending_time = (balloon.translation_pending_time + delta_time) % 2.0
    local dot_count = math.floor(balloon.translation_pending_time / (2.0 / 3.0)) + 1
    dot_count = math.max(1, math.min(3, dot_count))

    if dot_count ~= balloon.translation_pending_dots then
        balloon.translation_pending_dots = dot_count
        ui:set_pending_message(balloon.pending_translation_text(dot_count))
    end
end

balloon.translate_message = function(message)
    local display_message = message:trimex()
    balloon.translation_request_id = balloon.translation_request_id + 1
    local request_id = balloon.translation_request_id
    balloon.translation_pending = false

    local translated = translator.translate(display_message, balloon.settings, function(translated)
        if request_id ~= balloon.translation_request_id or ui:hidden() then
            return
        end

        balloon.translation_pending = false
        ui:set_message((translated or display_message):trimex())
    end)

    if translated ~= nil then
        return translated:trimex()
    end

    balloon.translation_pending = true
    balloon.translation_pending_time = 0
    balloon.translation_pending_dots = 1
    balloon.translation_pending_base = balloon.pending_translation_base()
    return balloon.pending_translation_text(1), true
end

balloon.convert_shiftjis_to_utf8 = function(str)
    str = balloon.sub_chars_pre_utf8(str)
	str = encoding:ShiftJIS_To_UTF8(str)
    str = balloon.sub_chars_post_utf8(str)
    return str
end

balloon.sub_chars_pre_utf8 = function(str)
	local new_str = str
	if S{'chars', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Pre-charsub pre-shift: ' .. new_str) end

	new_str = string.gsub(new_str, string.char(0x81, 0x40), '    ') -- tab
	new_str = string.gsub(new_str, string.char(0x81, 0xF4), '[BL_note]') -- musical note
	new_str = string.gsub(new_str, string.char(0x81, 0x99), '[BL_bstar]') -- empty star
	new_str = string.gsub(new_str, string.char(0x81, 0x9A), '[BL_wstar]') -- full star
	new_str = string.gsub(new_str, string.char(0x81, 0x60), '[BL_wave]') -- wide tilde
	new_str = string.gsub(new_str, string.char(0x87, 0xB2), '[BL_cldquote]') -- centered left double quote
	new_str = string.gsub(new_str, string.char(0x87, 0xB3), '[BL_crdquote]') -- centered right double quote
	new_str = string.gsub(new_str, string.char(0x88, 0x69), '[BL_e_acute]') -- acute accented e

	-- element symbols
	new_str = string.gsub(new_str, string.char(0xEF,0x1F), '[BL_Fire]')
	new_str = string.gsub(new_str, string.char(0xEF,0x20), '[BL_Ice]')
	new_str = string.gsub(new_str, string.char(0xEF,0x21), '[BL_Wind]')
	new_str = string.gsub(new_str, string.char(0xEF,0x22), '[BL_Earth]')
	new_str = string.gsub(new_str, string.char(0xEF,0x23), '[BL_Lightning]')
	-- extra 0x25 in these two to escape the characters
	new_str = string.gsub(new_str, string.char(0xEF,0x25,0x24), '[BL_Water]')
	new_str = string.gsub(new_str, string.char(0xEF,0x25,0x25), '[BL_Light]')
	new_str = string.gsub(new_str, string.char(0xEF,0x26), '[BL_Dark]')

	if S{'chars', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Post-charsub pre-shift: ' .. new_str) end
	return new_str
end

balloon.sub_chars_post_utf8 = function(str)
	local new_str = str
	if S{'chars', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Pre-charsub post-shift: ' .. new_str) end

	new_str = string.gsub(new_str, '%[BL_note]', '♪')
	new_str = string.gsub(new_str, '%[BL_bstar]', '☆')
	new_str = string.gsub(new_str, '%[BL_wstar]', '★')
	new_str = string.gsub(new_str, '%[BL_wave]', '~')
	new_str = string.gsub(new_str, '%[BL_cldquote]', '“')
	new_str = string.gsub(new_str, '%[BL_crdquote]', '”')
	new_str = string.gsub(new_str, '%[BL_e_acute]', 'é')

	if S{'chars', 'all'}[balloon.debug] then LogManager:Log(5, 'Balloon', 'Post-charsub post-shift: ' .. new_str) end
	return new_str
end

balloon.print_help = function(isError)
    -- Print the help header..
    if (isError) then
        print(chat.header(addon.name):append(chat.error('Invalid command syntax for command: ')):append(chat.success('/' .. addon.name)))
    else
        print(chat.header(addon.name):append(chat.message('Available commands:')))
    end

    local cmds = T{
        { '/lingoballoon help', 'Displays this help information.' },
        { '/lingoballoon 0', 'Hiding balloon & displaying log.' },
        { '/lingoballoon 1', 'Show balloon & hide log.' },
        { '/lingoballoon 2', 'Show balloon & displaying log.' },
        { '/lingoballoon translate', 'Toggle translation.' },
        { '/lingoballoon lang <source> <target>', 'Set translation languages. Use "auto" for source.' },
        { '/lingoballoon target <target>', 'Set translation target language.' },
        { '/lingoballoon interval <frames>', 'Set translation Copas frame interval.' },
        { '/lingoballoon cache clear', 'Clear translation cache.' },
        { '/lingoballoon reset', 'Reset to default settings.' },
        { '/lingoballoon reset pos', 'Reset the balloon position.' },
        { '/lingoballoon theme <theme>', 'Loads the specified theme.' },
        { '/lingoballoon scale <scale>', 'Scales the size of the balloon by a decimal (eg: 1.5).' },
        { '/lingoballoon delay <seconds>', 'Delay before closing promptless balloons.' },
        { '/lingoballoon speed <chars per second>', 'Speed that text is displayed, in characters per second.' },
        { '/lingoballoon portrait', 'Toggle the display of character portraits, if the theme has settings for them.' },
        { '/lingoballoon move_close', 'Toggle balloon auto-close on player movement.' },
        { '/lingoballoon always_on_top', 'Toggle always on top (IMGUI mode).' },
        { '/lingoballoon in_combat', 'Toggle displaying balloon during combat.' },
        { '/lingoballoon system', 'Toggle displaying balloon for system messages (e.g Home Point).' },
        { '/lingoballoon cinematic', 'Toggle auto hide of game UI during cutscenes.' },
        { '/lingoballoon fps', 'Toggle fps control during cutscenes to prevent lockups in certain cutscenes.' },
        { '/lingoballoon test <name> <lang> <mode>', 'Display a test bubble. Lang: - (auto), en or ja. Mode: 1 (dialogue), 2 (system). "/lingoballoon test" to see the list of available tests.' },
    }

    -- Print the command list..
    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])))
    end)
end

-- Ashita events

ashita.events.register('command', 'lingoballoon_command_cb', function(e)
    -- Parse the command arguments..
    local args = e.command:args()
    if (#args == 0 or (args[1] ~= '/lb' and args[1] ~= '/lgb' and args[1] ~= '/lingoballoon')) then
        return
    end

    -- Block all related commands..
    e.blocked = true

    -- Handle: /lingoballoon help
    if (#args == 2 and args[2]:any('help')) then
        balloon.print_help(false)
        return
    end

    -- Handle: /lingoballoon [0,1,2]
    if (#args == 2 and args[2]:any('0', '1', '2')) then
        balloon.settings.display_mode = tonumber(args[2])
        local mode_desc = {
            'Hiding balloon & displaying log.',
            'Show balloon & hide log.',
            'Show balloon & displaying log.',
        }
        print(chat.header(addon.name):append(chat.message('Display mode changed: ')):append(chat.success(mode_desc[balloon.settings.display_mode + 1])))
        settings.save()
        return
    end

    -- Handle: /lingoballoon reset
    if (#args >= 2 and args[2]:any('reset')) then
        if #args >= 3 and args[3]:any('pos', 'position') then
            print(chat.header(addon.name):append(chat.message('Resetting position')))
            balloon.settings.position.x = default_settings.position.x
            balloon.settings.position.y = default_settings.position.y
            settings.save()
            ui:position(balloon.settings.position.x, balloon.settings.position.y)
        else
            settings.reset()
        end
        return
    end

    -- Handle: /lingoballoon theme
    if (#args >= 2 and args[2]:any('theme')) then
        if #args > 2 then
            local old_theme = balloon.settings.theme
            local old_theme_options = balloon.theme_options

            balloon.settings.theme = args[3]

            balloon.load_theme()
            if balloon.theme_options ~= nil then
                print(chat.header(addon.name):append(chat.message('Theme changed: ')):append(chat.success(balloon.settings.theme)))
            else
                -- Restore old settings
                balloon.theme_options = old_theme_options
                balloon.settings.theme = old_theme
            end

            settings.save()
        else
            print(chat.header(addon.name):append(chat.message('Theme: ')):append(chat.success(balloon.settings.theme)))
        end
        return
    end

    -- Handle: /lingoballoon lang [source] [target]
    if (#args >= 2 and args[2]:any('lang', 'language')) then
        if #args >= 4 then
            balloon.settings.translation_source = args[3]
            balloon.settings.translation_target = args[4]
            settings.save()
        elseif #args == 3 then
            balloon.settings.translation_target = args[3]
            settings.save()
        end

        print(chat.header(addon.name):append(chat.message('Translation language: ')):append(chat.success('%s -> %s'):format(balloon.settings.translation_source, balloon.settings.translation_target)))
        return
    end

    -- Handle: /lingoballoon source <source>
    -- Handle: /lingoballoon target <target>
    if (#args >= 2 and args[2]:any('source', 'target')) then
        local setting_key = args[2] == 'source' and 'translation_source' or 'translation_target'
        if #args >= 3 then
            balloon.settings[setting_key] = args[3]
            settings.save()
        end

        print(chat.header(addon.name):append(chat.message('%s: '):format(args[2])):append(chat.success('%s'):format(balloon.settings[setting_key])))
        return
    end

    -- Handle: /lingoballoon cache [clear]
    if (#args >= 2 and args[2]:any('cache')) then
        if #args >= 3 and args[3]:any('clear', 'reset') then
            translator.clear_cache()
            print(chat.header(addon.name):append(chat.message('Translation cache cleared.')))
        else
            print(chat.header(addon.name):append(chat.message('Translation cache entries: ')):append(chat.success('%d'):format(translator.cache_count())))
        end
        return
    end

    -- Handle numerical options
    -- Handle: /lingoballoon scale
    -- Handle: /lingoballoon delay
    -- Handle: /lingoballoon speed
    -- Handle: /lingoballoon interval
    if (#args >= 2 and args[2]:any('scale', 'delay', 'speed', 'interval', 'copas_interval')) then
        local setting_key_alias = {
            delay = 'no_prompt_close_delay',
            speed = 'text_speed',
            interval = 'translation_copas_interval',
            copas_interval = 'translation_copas_interval',
        }
        local setting_names = {
            no_prompt_close_delay = 'Promptless close delay',
            text_speed = 'Text speed',
            scale = 'Scale',
            translation_copas_interval = 'Translation Copas interval',
        }
        local setting_fmts = {
            no_prompt_close_delay = '%d',
            text_speed = '%d',
            scale = '%.2f',
            translation_copas_interval = '%d',
        }
        local setting_key = setting_key_alias[args[2]] or args[2]
        local setting_name = setting_names[setting_key] or args[2]
        local setting_fmt = setting_fmts[setting_key] or args[2]

		if #args > 2 then
            local old_val = balloon.settings[setting_key]
			balloon.settings[setting_key] = tonumber(args[3]) or 0
            if setting_key == 'translation_copas_interval' then
                balloon.settings[setting_key] = math.max(1, math.floor(balloon.settings[setting_key]))
            end

            -- Some additional logic we need to run depending on the setting change
            if setting_key == 'scale' then
                ui:scale(balloon.settings.scale, balloon.settings.position)
            elseif setting_key == 'text_speed' then
                ui:text_speed(balloon.settings.text_speed)
            end

            print(chat.header(addon.name):append(chat.message('%s changed: '):format(setting_name)):append(chat.success('from ' .. setting_fmt .. ' to ' .. setting_fmt):format(old_val, balloon.settings[setting_key])))
            settings.save()
		else
			print(chat.header(addon.name):append(chat.message('%s: '):format(setting_name)):append(chat.success(setting_fmt):format(balloon.settings[setting_key])))
		end
        return
    end

    -- Handle toggle options
    -- Handle: /lingoballoon portrait
    -- Handle: /lingoballoon move_close
    -- Handle: /lingoballoon always_on_top
    -- Handle: /lingoballoon in_combat
    -- Handle: /lingoballoon system
    -- Handle: /lingoballoon cinematic
    -- Handle: /lingoballoon fps
    -- Handle: /lingoballoon translate
    if (#args == 2 and args[2]:any(
        'portrait', 'portraits',
        'move_closes', 'move_close',
        'always_on_top',
        'in_combat',
        'system', 'system_messages',
        'cinematic', 'cinema',
        'fps',
        'translate', 'translation')
    ) then
        local setting_key_alias = {
            portrait = 'portraits',
            move_closes = 'move_close',
            cinema = 'cinematic',
            system = 'system_messages',
            translate = 'translate_enabled',
            translation = 'translate_enabled',
        }
        local setting_names = {
            portraits = 'Display portraits',
            move_close = 'Close balloons on player movement',
            always_on_top = 'Always on top (IMGUI mode)',
            in_combat = 'Display in combat',
            system_messages = 'Display for system messages',
            cinematic = 'Cinematic mode',
            fps = 'Control fps during cutscenes',
            translate_enabled = 'Translation',
        }
        local setting_key = setting_key_alias[args[2]] or args[2]
        local setting_name = setting_names[setting_key] or args[2]

        local old_val = balloon.settings[setting_key]
        balloon.settings[setting_key] = not old_val

        -- Some additional logic we need to run depending on the setting change
        if setting_key == 'portraits' then
            balloon.load_theme()
        elseif setting_key == 'system_messages' then
            balloon.load_chat_mode_settings()
        elseif setting_key == 'always_on_top' then
            ui:always_on_top(balloon.settings.always_on_top)
        elseif setting_key == 'fps' then
            balloon.limit_fps(balloon.limit_fps_enabled)
        end

        print(chat.header(addon.name):append(chat.message('%s changed: '):format(setting_name)):append(chat.success(balloon.settings[setting_key] and 'on' or 'off')))
        settings.save()
        return
    end

    -- Handle: /lingoballoon test
    if (#args >= 2 and args[2]:any('test')) then
        local test_name = args[3]

        if test_name == nil then
            local test_names = T{}
            for k, _ in pairs(tests) do
                table.insert(test_names, k)
            end
            print(chat.header(addon.name):append('Available tests: '):append(chat.success(test_names:join(', '))))
            return
        end

        local lang = args[4] or balloon.lang_code
        if lang == '-' then
            lang = balloon.lang_code
        end
        local lang_map = {
            en = 2,
            ja = 3,
        }
        local lang_index = lang_map[lang] or 2

        local test_entry = tests[test_name]
        if test_entry == nil then
            print(chat.header(addon.name):append(chat.error('Invalid test: %s'):format(test_name)))
            return
        end

        local npc_name = test_entry[1]
        print(chat.header(addon.name):append(chat.message('Test: %s (%s)'):format(test_name, lang)))
        local message = test_entry[lang_index]
        local mode = (args[5] == '2' or npc_name == '') and chat_modes.system or chat_modes.message
        local message_prefix = npc_name ~= '' and (npc_name .. ' : ') or ''
        balloon.process_balloon(message_prefix .. message, mode)
        return
    end

    -- Unhandled: Print help information..
    balloon.print_help(true)
end)

ashita.events.register('load', 'lingoballoon_load', function()
    balloon.settings = settings.load(default_settings)
    local copas_interval = tonumber(balloon.settings.translation_copas_interval)
    -- Migrate the old slow default while still allowing users to pick any other value.
    if copas_interval == nil or copas_interval < 1 or copas_interval == 17 then
        balloon.settings.translation_copas_interval = default_settings.translation_copas_interval
        settings.save()
    end
    balloon.last_frame_time = os.clock()
    translator.init(addon.path)

    balloon.initialize()

    -- Register for settings updates
    settings.register('settings', 'lingoballoon_settings_update', function(s)
        if (s ~= nil) then
            balloon.settings = s
            balloon.initialize(s)
        end
    end)
end)

ashita.events.register('unload', 'lingoballoon_unload', function()
    translator.shutdown()
    ui:destroy()
end)

ashita.events.register('packet_in', 'lingoballoon_packet_in', function(e)
    if balloon.theme_options == nil then
        return
    end

	-- Check if player has left a conversation
    if e.id == defines.packets.inc.mog_menu then
        balloon.in_mog_menu = true
    elseif e.id == defines.packets.inc.zone_out then
		balloon.close()
    elseif e.id == defines.packets.inc.leave_conversation then
        if balloon.in_mog_menu then
            balloon.in_mog_menu = false
            return
        end
        local type = struct.unpack('b', e.data_modified, 0x04 + 1)
        -- LogManager:Log(5, 'Balloon', 'packets.inc.leave_conversation - type: ' .. tostring(type))
        if tonumber(type) == 0 then
            if balloon.debug_closing then print('Closing from leave conversation: ' .. type) end
            balloon.close()
        end
	end
end)

ashita.events.register('packet_out', 'lingoballoon_packet_out', function (e)
    if balloon.theme_options == nil then
        return
    end

    -- Check if player has left a conversation
    -- Since this is outgoing, this comes sooner than the incoming LEAVE_CONVERSATION_PACKET
	if e.id == defines.packets.out.dialogue_option then
        local in_menu = struct.unpack('H', e.data_modified, 0x0E + 1)
        local option_index = struct.unpack('H', e.data_modified, 0x08 + 1)

        if in_menu == 1 then
            balloon.in_menu = true
        else
            balloon.in_menu = false
            if option_index == 0 or option_index == 2 then --if option_index ~= 2 then -- 2 = selected a home point warp
                if balloon.debug_closing then print('Closing from dialogue option') end
                balloon.close()
            end
        end

        -- LogManager:Log(5, 'Balloon', 'packets.out.dialogue_option - option_index: ' .. tostring(option_index) .. ', in_menu: ' .. tostring(in_menu))
    elseif e.id == defines.packets.out.homepoint_map then
        -- User is viewing home point map
        balloon.close()
        -- We're still in the menu
        balloon.in_menu = true
    end
end)

ashita.events.register('text_in', 'lingoballoon_text_in', function(e)
    if balloon.theme_options == nil then
        return
    end
    -- Ignore text in from Ashita addons/plugins
    if e.injected then
        return
    end

    if not balloon.processing_message then
        balloon.processing_message = true

        balloon.process_incoming_message(e)

        balloon.processing_message = false
    end
end)

ashita.events.register('d3d_present', 'lingoballoon_d3d_present', function()
    -- Calculate delta time for animations
    local frame_time = os.clock()
    local delta_time = frame_time - balloon.last_frame_time
    balloon.last_frame_time = frame_time
    translator.step(balloon.settings)

    if balloon.theme_options == nil then
        return
    end

    -- Don't display unless we have a player entity and we're not zoning
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local player_ent = GetPlayerEntity()
    if player == nil or player.isZoning or player_ent == nil then
		return
	end

    -- Check player's last target so we can ignore certain "cutscenes"
    local player_target = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0)
    local entity = GetEntity(tonumber(player_target))
    local last_known_target = entity and entity.Name or nil
    if last_known_target ~= nil and last_known_target ~= balloon.last_known_target then
        -- print('player_target entity: ' ..last_known_target)
        balloon.last_known_target = last_known_target
    end

    -- Handle movement closes balloon
    balloon.handle_player_movement(player_ent)
    -- Handle cinematics
    balloon.handle_cinematics(player_ent, delta_time)
    -- Animate the translation placeholder without using the typewriter clip.
    balloon.update_pending_translation(delta_time)

    if not ui:hidden() then
        if balloon.settings.always_on_top then
            ui:render_imgui(delta_time)
        else
            ui:render(delta_time)
        end
    end
end)

ashita.events.register('mouse', 'lingoballoon_mouse', function (e)
    if e.message == defines.MOUSE_DOWN then
        if ui:hidden() then
            return
        end

        local ui_x, ui_y = ui:position()
        local w, h = ui:window_size()
        local mouse_x, mouse_y = e.x, e.y

        -- Mouse click inside balloon?
        if mouse_x >= ui_x and mouse_x <= ui_x + w and
           mouse_y >= ui_y and mouse_y <= ui_y + h then
            balloon.drag_offset = {
                ui_x - mouse_x,
                ui_y - mouse_y,
            }
            e.blocked = true
        end
    elseif balloon.drag_offset ~= nil then
        e.blocked = true

        local new_position = {
            e.x + balloon.drag_offset[1],
            e.y + balloon.drag_offset[2],
        }

        if e.message == defines.MOUSE_UP or ui:hidden() then
            ui:position(new_position[1], new_position[2], true)

            -- Convert to center anchor for saving to settings
            local w, h = ui:window_size()
            balloon.settings.position.x = new_position[1] + w / 2
            balloon.settings.position.y = new_position[2] + h / 2
            settings.save()

            balloon.drag_offset = nil
        else
            ui:position(new_position[1], new_position[2], true)
        end
    end
end)

ashita.events.register('key_data', 'lingoballoon_key_data', function(e)
    -- DirectInput key codes http://www.flint.jp/misc/?q=dik
    if e.down and (e.key == 0x01 or e.key == 0x1C or e.key == 0x9C) then
        balloon.handle_button_continue(e)
    end
end)

ashita.events.register('dinput_button', 'lingoballoon_dinput_button', function(e)
    if defines.DINPUT_CONTROLLER_DISMISS[e.button] ~= nil and e.state == 128 then
        balloon.handle_button_continue(e)
    end
end)

ashita.events.register('xinput_button', 'lingoballoon_xinput_button', function(e)
    if defines.XINPUT_CONTROLLER_DISMISS[e.button] ~= nil and e.state == 1 then
        balloon.handle_button_continue(e)
    end
end)
