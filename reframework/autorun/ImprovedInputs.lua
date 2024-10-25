local cfg = json.load_file("ImprovedInputs.json")

local function initialize_config()
    cfg = {
        ["hbg_charge_on"] = false,
        ["shortcuts_on"] = false,
        ["pad_dodge_on"] = false,
        ["db_special_on"] = false,
        ["chainsaw_on"] = true,
        ["use_sub_binds"] = false,
    }
end

if not cfg then
    initialize_config()
end

local player_manager = nil
local player_character = nil
local player_typedef_name = nil
local input_manager = nil
local gui_manager = nil
local key_config = nil
local pad_config = nil
local keyboard_device = nil
local mouse_device = nil
local pad_device = nil
local initialized = false

local mouse_mask = 0
local mouse_special_mask = 0
local kb_binds = {}
local kb_special_code = 0
local pad_mask = 0
local pad_left_shoulder_mask = 0
local pad_special_mask = 0
local pad_non_special_mask = 0

local keyboard_typedef = sdk.find_type_definition("snow.GameKeyboard.HardwareKeyboard")
local mouse_typedef = sdk.find_type_definition("snow.StmMouse.HardwareDevice")
local pad_typedef = sdk.find_type_definition("snow.Pad.Device")
local keyboard_on_field = keyboard_typedef:get_field("_on")
local keyboard_on_get_item_method = keyboard_on_field:get_type():get_method("get_Item")
local keyboard_on_set_item_method = keyboard_on_field:get_type():get_method("set_Item")
local keyboard_trg_field = keyboard_typedef:get_field("_trg")
local keyboard_trg_set_item_method = keyboard_trg_field:get_type():get_method("set_Item")
local keyboard_rel_field = keyboard_typedef:get_field("_rel")
local keyboard_rel_set_item_method = keyboard_rel_field:get_type():get_method("set_Item")
local mouse_on_field = mouse_typedef:get_field("_on")
local mouse_trg_field = mouse_typedef:get_field("_trg")
local mouse_rel_field = mouse_typedef:get_field("_rel")
local pad_on_field = pad_typedef:get_field("_on")
local pad_trg_field = pad_typedef:get_field("_trg")
local pad_rel_field = pad_typedef:get_field("_rel")

local player_manager_typedef = sdk.find_type_definition("snow.player.PlayerManager")
local find_master_method = player_manager_typedef:get_method("findMasterPlayer")
local get_special_mode_method = sdk.find_type_definition("snow.player.HeavyBowgun"):get_method("get_SpecialMode")
local is_chainsaw_buff_method = sdk.find_type_definition("snow.player.ChargeAxe"):get_method("isChainsawBuff")
local weapon_on_method = sdk.find_type_definition("snow.player.PlayerBase"):get_method("isWeaponOn")
local input_manager_update_method = sdk.find_type_definition("snow.StmInputManager"):get_method("update")
local gui_manager_typedef = sdk.find_type_definition("snow.gui.GuiManager")
local can_open_start_menu_method = gui_manager_typedef:get_method("isCanOpenStartMenu")
local start_menu_open_method = gui_manager_typedef:get_method("IsStartMenuAndSubmenuOpen")
local input_config_typedef = sdk.find_type_definition("snow.StmInputConfig")
local update_player_keybind_method = input_config_typedef:get_method("UpdatePlayerKeyBind")
local update_settings_method = input_config_typedef:get_method("updateSettingOptionChange")

local function find_player_typedef_name()
    if not player_manager then
        return
    end
    player_character = find_master_method:call(player_manager)
    if player_character then
        player_typedef_name = player_character:get_type_definition():get_full_name()
    end
end

local function player_is_ranged()
    local n = player_typedef_name
    return n == "snow.player.HeavyBowgun" or n == "snow.player.LightBowgun" or n == "snow.player.Bow"
end

local function player_in_lobby()
    return player_typedef_name == "snow.player.PlayerLobbyBase"
end

local function special_bind_needed()
    local n = player_typedef_name
    return not (n == "snow.player.GreatSword" or n == "snow.player.ShortSword" or n == "snow.player.Lance" or
        n == "snow.player.GunLance" or
        n == "snow.player.Hammer" or (n == "snow.player.DualBlades" and not cfg.db_special_on))
end

local function keybind_should_be_ignored(keybind_idx)
    local ignore = false

    if keybind_idx == 14 and not special_bind_needed() then
        ignore = true
    end

    -- Combo bind for lance charge. Shield charge gets instantly canceled if this isn't tapped extremely quickly so just turn it off
    if keybind_idx == 26 and player_typedef_name == "snow.player.Lance" then
        ignore = true
    end

    if not cfg.shortcuts_on and keybind_idx >= 47 and keybind_idx <= 54 then
        ignore = true
    end

    return ignore
end

local function menu_is_open()
    return not can_open_start_menu_method:call(gui_manager, 0, 0) or start_menu_open_method:call(gui_manager)
end

local function main_or_sub_binds()
    if cfg.use_sub_binds then return "_Sub" else return "_Main" end
end

local function get_ranged_keybind(idx)
    return key_config:get_field("_Range"):get_field("_CodeSets")[idx]:get_field("_KeySet"):get_field(main_or_sub_binds())
end

local function get_melee_keybind(idx)
    return key_config:get_field("_Melee"):get_field("_CodeSets")[idx]:get_field("_KeySet"):get_field(main_or_sub_binds())
end

local function get_pad_bind(idx)
    return pad_config[idx]:get_field("value")
end

local function update_pad_settings(retval)
    if not initialized then
        return retval
    end

    pad_special_mask = get_pad_bind(2) -- Ranged primary fire, melee special/guard
    pad_mask = 0xF0 | 0x60000          -- All the right side face buttons + confirm/decline
    if special_bind_needed() then
        pad_mask = pad_mask | pad_special_mask
    end
    if not cfg.pad_dodge_on then
        pad_mask = pad_mask & ~0x20
    end

    pad_non_special_mask = 0xC00 ~ pad_special_mask -- Right shoulder button/trigger that isn't the special bind
    pad_left_shoulder_mask = get_pad_bind(1)        -- Left shoulder button/trigger used for menuing/items

    return retval
end

local function update_keybinds(retval)
    if not initialized then
        return retval
    end
    find_player_typedef_name()

    -- 7 Dodge
    -- 8 Interact
    -- 12 Primary Attack / Reload
    -- 13 Secondary Attack / Special Attack
    -- 14 Guard or Special / Primary Fire
    -- 22-31 Combo binds
    -- 32 Use Item
    -- 47-54 Shortcuts
    -- 59, 64, 65 Combo binds
    local keybind_indexes = { 7, 8, 12, 13, 14, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 47, 48, 49, 50, 51, 52, 53, 54, 59, 64, 65 }

    mouse_mask = 0
    kb_binds = {}
    for i = 1, #keybind_indexes do
        local idx = keybind_indexes[i]
        if keybind_should_be_ignored(idx) then
            goto continue
        end
        if player_is_ranged() then
            local ranged_key = get_ranged_keybind(idx)
            if ranged_key >= 500 then
                mouse_mask = (ranged_key - 500) | mouse_mask
                if idx == 14 then
                    mouse_special_mask = ranged_key - 500
                end
            elseif ranged_key > 0 then
                kb_binds[#kb_binds + 1] = ranged_key
                if idx == 14 then
                    kb_special_code = ranged_key
                end
            end
        else
            local melee_key = get_melee_keybind(idx)
            if melee_key >= 500 then
                mouse_mask = (melee_key - 500) | mouse_mask
            elseif melee_key > 0 then
                kb_binds[#kb_binds + 1] = melee_key
            end
        end
        ::continue::
    end

    update_pad_settings(nil)

    return retval
end

local function initialize()
    if initialized then
        return
    end

    initialized = true

    if not player_manager then
        initialized = false
        player_manager = sdk.get_managed_singleton("snow.player.PlayerManager")
    end

    if not player_typedef_name then
        initialized = false
        find_player_typedef_name()
    end

    if not input_manager then
        initialized = false
        input_manager = sdk.get_managed_singleton("snow.StmInputManager")
    end

    if not key_config or not pad_config then
        initialized = false
        local input_config = sdk.get_managed_singleton("snow.StmInputConfig")
        if not key_config and input_config then
            local active_config = input_config:get_field("_ActiveConfigData")
            if active_config then
                local pl_1 = active_config:get_field("_PLHolder")
                if pl_1 then
                    local pl_2 = pl_1:get_field("_PLHolder")
                    if pl_2 then
                        key_config = pl_2[0]
                    end
                end
            end
        end
        if not pad_config and input_config then
            local pad_pl_conf = input_config:get_field("pad_pl_Conf")
            if pad_pl_conf then
                pad_config = pad_pl_conf:get_field("_entries")
            end
        end
    end


    if not gui_manager then
        initialized = false
        gui_manager = sdk.get_managed_singleton("snow.gui.GuiManager")
    end

    if not mouse_device then
        initialized = false
        local stmMouse = sdk.get_managed_singleton("snow.StmMouse")
        if stmMouse then
            mouse_device = stmMouse:get_field("hardmouse")
        end
    end

    if not keyboard_device then
        initialized = false
        local GameKeyboard = sdk.get_managed_singleton("snow.GameKeyboard")
        if GameKeyboard then
            keyboard_device = GameKeyboard:get_field("hardKeyboard")
        end
    end

    if not pad_device then
        initialized = false
        local pad = sdk.get_managed_singleton('snow.Pad')
        if pad then
            pad_device = pad:get_field('app')
        end
    end

    if initialized then
        update_keybinds(nil)
    end
end

local function hbg_normal_firing()
    return player_typedef_name == "snow.player.HeavyBowgun" and not cfg.hbg_charge_on and
        weapon_on_method:call(player_character) and not get_special_mode_method:call(player_character)
end

local function should_deactivate_during_chainsaw()
    if player_typedef_name == "snow.player.ChargeAxe" and not cfg.chainsaw_on then
        return is_chainsaw_buff_method:call(player_character)
    end
    return false
end

local function handle_mouse_input()
    local on = mouse_on_field:get_data(mouse_device)
    local enabled_mask = on & mouse_mask
    if enabled_mask ~= 0 then
        local trg = mouse_trg_field:get_data(mouse_device) | enabled_mask
        mouse_device:set_field("_trg", trg)

        if hbg_normal_firing() and on & mouse_special_mask ~= 0 then
            local rel = mouse_rel_field:get_data(mouse_device) | mouse_special_mask
            mouse_device:set_field("_rel", rel)
            local negate_on = on & ~mouse_special_mask
            mouse_device:set_field("_on", negate_on)
        end
    end
end

local function handle_kb_input()
    local on = keyboard_on_field:get_data(keyboard_device)
    for i = 1, #kb_binds do
        local key_code = kb_binds[i]
        local on_key = keyboard_on_get_item_method:call(on, key_code)
        if on_key then
            local trg = keyboard_trg_field:get_data(keyboard_device)
            keyboard_trg_set_item_method:call(trg, key_code, true)

            if hbg_normal_firing() and key_code == kb_special_code then
                local rel = keyboard_rel_field:get_data(keyboard_device)
                keyboard_rel_set_item_method:call(rel, key_code, true)
                keyboard_on_set_item_method:call(on, key_code, false)
            end
        end
    end
end

local function handle_pad_input()
    local on = pad_on_field:get_data(pad_device)
    if on & pad_left_shoulder_mask == 0 then
        local enabled_mask = on & pad_mask
        if enabled_mask ~= 0 then
            local trg = pad_trg_field:get_data(pad_device) | enabled_mask
            pad_device:set_field("_trg", trg)

            if hbg_normal_firing() and on & pad_special_mask ~= 0 and pad_non_special_mask & on == 0 then
                local rel = pad_rel_field:get_data(pad_device) | pad_special_mask
                pad_device:set_field("_rel", rel)
                local negate_on = on & ~pad_special_mask
                pad_device:set_field("_on", negate_on)
            end
        end
    end
end

local function handle_player_input(args)
    if not initialized then
        initialize()
        return
    end
    if not menu_is_open() and not player_in_lobby() and not should_deactivate_during_chainsaw() then
        handle_mouse_input()
        handle_kb_input()
        handle_pad_input()
    end
end

local function empty_pre(args) end
local function empty_post(retval) return retval end

sdk.hook(input_manager_update_method, handle_player_input, empty_post)

sdk.hook(update_player_keybind_method, empty_pre, update_keybinds)

sdk.hook(update_settings_method, empty_pre, update_pad_settings)

local function save_config()
    json.dump_file("ImprovedInputs.json", cfg)
end

local mod_name = "Improved Inputs"
local mod_description = "Hold down buttons to activate them continuously."

local function imgui_menu()
    if imgui.tree_node(mod_name) then
        local changed = false
        changed, cfg.hbg_charge_on = imgui.checkbox("HBG Charged Shots", cfg.hbg_charge_on)
        if changed then
            update_keybinds(nil)
        end

        changed, cfg.shortcuts_on = imgui.checkbox("Shortcut bar", cfg.shortcuts_on)
        if changed then
            update_keybinds(nil)
        end

        changed, cfg.pad_dodge_on = imgui.checkbox("Controller dodge", cfg.pad_dodge_on)
        if changed then
            update_pad_settings(nil)
        end

        changed, cfg.db_special_on = imgui.checkbox("Dual Blades demon mode activation", cfg.db_special_on)
        if changed then
            update_keybinds(nil)
        end

        changed, cfg.chainsaw_on = imgui.checkbox("Active during Charge Blade Condensed Spinning Slash", cfg.chainsaw_on)
        if changed then
            update_keybinds(nil)
        end

        changed, cfg.use_sub_binds = imgui.checkbox("Use secondary keybinds", cfg.use_sub_binds)
        if changed then
            update_keybinds(nil)
        end
        imgui.tree_pop()
    end
end

re.on_draw_ui(imgui_menu)

re.on_config_save(save_config)

local function is_module_available(name)
    if package.loaded[name] then
        return true
    else
        for _, searcher in ipairs(package.searchers or package.loaders) do
            local loader = searcher(name)
            if type(loader) == 'function' then
                package.preload[name] = loader
                return true
            end
        end
        return false
    end
end

local mod_menu_package = "ModOptionsMenu.ModMenuApi"
local mod_ui = nil

if is_module_available(mod_menu_package) then
    mod_ui = require(mod_menu_package)
end

local function mod_ui_menu()
    local changed = false
    changed, cfg.hbg_charge_on = mod_ui.CheckBox("HBG charged shots", cfg.hbg_charge_on,
        "Disables the mod for HBG primary fire, letting you charge/crouching fire normally.")
    if changed then
        update_keybinds(nil)
    end

    changed, cfg.shortcuts_on = mod_ui.CheckBox("Shortcut bar", cfg.shortcuts_on,
        "Enables the mod for the keyboard shortcut bar.")
    if changed then
        update_keybinds(nil)
    end

    changed, cfg.pad_dodge_on = mod_ui.CheckBox("Controller dodge", cfg.pad_dodge_on,
        "Enables the mod for controller dodging.")
    if changed then
        update_pad_settings(nil)
    end

    changed, cfg.db_special_on = mod_ui.CheckBox("Dual Blades demon mode activation", cfg.db_special_on,
        "Enables the mod for the dual blades demon mode button.")
    if changed then
        update_keybinds(nil)
    end

    changed, cfg.chainsaw_on = mod_ui.CheckBox("Active during Charge Blade Condensed Spinning Slash", cfg.chainsaw_on,
        "Enables the mod during the Condensed Spinning Slash buff.")
    if changed then
        update_keybinds(nil)
    end

    changed, cfg.use_sub_binds = mod_ui.CheckBox("Use secondary keybinds", cfg.use_sub_binds,
        "Enable the mod for secondary keybinds instead of primary ones.")
    if changed then
        update_keybinds(nil)
    end
end

if mod_ui then
    local mod_ui_obj = mod_ui.OnMenu(mod_name, mod_description, mod_ui_menu)
    mod_ui_obj.OnResetAllSettings = initialize_config
end
