-- main.lua — SimpleUI Extra Modules
-- Plugin entry point.
--
-- HOW TO ADD A NEW MODULE
--   Drop module_yourname.lua into simpleui_ext.koplugin/modules/
--   It will be auto-registered with SimpleUI on the next KOReader start.
--
-- HOW TO ADD A NEW PATCH
--   Drop patch_yourname.lua into simpleui_ext.koplugin/patches/
--   The file must return a table with:
--     patch.id     string   — unique identifier used in log messages
--     patch.apply  func()   — called once after SimpleUI has initialised
--   Patches are applied in alphabetical order after modules are registered.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings     = require("luasettings")
local logger          = require("logger")
local _ = require("sui_ext_i18n").translate

-- Settings file path helper - computed at runtime to ensure consistency
local function getSettingsFilePath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/simpleui_ext.lua"
end

-- ---------------------------------------------------------------------------
-- discover_patches — scans patches/ for patch_*.lua files.
-- Returns a sorted list of require-paths (e.g. "patches/patch_foo").
-- Mirrors discover_modules; runs once at startup.
-- ---------------------------------------------------------------------------
local function discover_patches(plugin_dir)
    if not plugin_dir then return {} end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return {} end
    local patches = {}
    local ok, iter, dir_obj = pcall(lfs.dir, plugin_dir .. "/patches")
    if not ok then return patches end
    for entry in iter, dir_obj do
        local stem = entry:match("^(patch_%a[%w_]*)%.lua$")
        if stem then
            patches[#patches + 1] = "patches/" .. stem
        end
    end
    table.sort(patches)   -- deterministic, alphabetical order
    return patches
end

-- Auto-discover all module_*.lua files inside the modules/ subdirectory.
-- Runs once at startup; with a handful of files the overhead is negligible.
-- plugin_dir is self.path, set automatically by KOReader's pluginloader.
local function discover_modules(plugin_dir)
    if not plugin_dir then
        logger.warn("simpleui_ext: could not resolve plugin directory, skipping auto-discovery")
        return {}
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.warn("simpleui_ext: lfs unavailable, skipping auto-discovery")
        return {}
    end

    local modules = {}
    local ok, iter, dir_obj = pcall(lfs.dir, plugin_dir .. "/modules")
    if not ok then
        logger.warn("simpleui_ext: cannot scan modules/ dir: " .. tostring(iter))
        return modules
    end
    for entry in iter, dir_obj do
        -- Only pick up files like  module_foo.lua  (prefix required, no sub-dirs)
        local stem = entry:match("^(module_%a[%w_]*)%.lua$")
        if stem then
            modules[#modules + 1] = "modules/" .. stem
        end
    end
    table.sort(modules)   -- deterministic load order
    return modules
end

-- ---------------------------------------------------------------------------
local SimpleUIExtPlugin = WidgetContainer:new{
    name           = "simpleui_ext",
    is_doc_only    = false,   -- must be false so onCloseDocument fires in Reader context
    _settings      = nil,     -- LuaSettings instance (lazy-loaded)
    _registry      = nil,
    _mod_ids       = {},
    _mods          = {},      -- module objects, for event forwarding
    _patches_meta  = {},      -- all discovered patch tables (for menu)
    _modules_meta  = {},      -- all discovered module tables (for menu)
}

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:_getSettings()
    if not self._settings then
        self._settings = LuaSettings:open(getSettingsFilePath())
    end
    return self._settings
end

function SimpleUIExtPlugin:_isPatchEnabled(patch_id, default_enabled)
    local states = self:_getSettings():readSetting("patch_states") or {}
    local enabled = states[patch_id]
    if enabled == nil then
        -- Patches default to false (opt-in) unless explicitly set to true
        return default_enabled == true
    end
    return enabled == true
end

function SimpleUIExtPlugin:_setPatchEnabled(patch_id, enabled)
    local states = self:_getSettings():readSetting("patch_states") or {}
    states[patch_id] = enabled
    self:_getSettings():saveSetting("patch_states", states)
    self:_getSettings():flush()
end

function SimpleUIExtPlugin:_isModuleEnabled(module_id, default_enabled)
    local states = self:_getSettings():readSetting("module_states") or {}
    local enabled = states[module_id]
    if enabled == nil then
        -- Modules default to true unless explicitly set to false
        return default_enabled ~= false
    end
    return enabled == true
end

function SimpleUIExtPlugin:_setModuleEnabled(module_id, enabled)
    local states = self:_getSettings():readSetting("module_states") or {}
    states[module_id] = enabled
    self:_getSettings():saveSetting("module_states", states)
    self:_getSettings():flush()
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:init()
    -- Register menu (must be before _register for menu to appear)
    self.ui.menu:registerToMainMenu(self)

    -- Delay registration by one scheduler tick so that all plugins
    -- (including SimpleUI itself) have finished their own init().
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0, function()
        self:_register()
        -- Synchronous on purpose: by the time the user reaches the home
        -- screen (separate code path, after file manager etc. close) the
        -- stats cache is already warm.
        self:_prewarmBookModuleCaches()
    end)
end

function SimpleUIExtPlugin:_register()
    local ok, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok or not Registry then
        logger.warn("simpleui_ext: SimpleUI moduleregistry not found. " ..
                    "Make sure SimpleUI is installed.")
        return
    end
    self._registry     = Registry
    self._mod_ids      = {}
    self._mods         = {}
    self._modules_meta = {}

    -- Load modules: Hybrid approach (same as patches)
    -- - New modules (not in settings): require() once to get metadata, store in settings
    -- - Known modules: check enabled state, skip require() if disabled
    -- This ensures all modules appear in menu while maximizing performance.
    local module_states = self:_getSettings():readSetting("module_states") or {}
    local existing_modules = {}  -- Track which modules exist (for cleanup later)
    
    for _i, path in ipairs(discover_modules(self.path)) do
        -- Extract module_id from path (e.g., "modules/module_hero_currently" -> "hero_currently")
        -- Note: [%w_]+ matches alphanumeric + underscore (not just %w which excludes underscore)
        local module_id = path:match("module_([%w_]+)$")
        if not module_id then
            logger.warn("simpleui_ext: could not extract module_id from path '" .. path .. "'")
            goto continue_module
        end
        existing_modules[module_id] = true  -- Mark as existing
        
        -- Check if this module is known (exists in settings)
        local is_known = module_states[module_id] ~= nil
        
        if is_known then
            -- Known module: check enabled state BEFORE require (performance optimization)
            if not self:_isModuleEnabled(module_id, true) then
                -- Still need to add minimal metadata for menu (without requiring)
                self._modules_meta[#self._modules_meta + 1] = {
                    id = module_id,
                    name = module_id:gsub("_", " "):gsub("(%a)([%w_']*)", function(first, rest)
                        return first:upper() .. rest:lower()
                    end),
                    description = _("Disabled module (enable to load)"),
                    default_enabled = true,
                }
                goto continue_module
            end
        end
        
        -- New module OR enabled module: require() to get full metadata
        local ok2, mod = pcall(require, path)
        if not ok2 or not mod then
            logger.warn("simpleui_ext: failed to load module '" .. path ..
                        "': " .. tostring(mod))
            goto continue_module
        elseif type(mod.id) ~= "string" then
            logger.warn("simpleui_ext: module '" .. path ..
                        "' has no id field — skipped.")
            goto continue_module
        end
        
        -- Validate: mod.id MUST match filename-based module_id
        if mod.id ~= module_id then
            logger.err("simpleui_ext: module '" .. path .. "' has mismatched ID — SKIPPED")
            logger.err("  Expected (from filename): '" .. module_id .. "'")
            logger.err("  Actual (from mod.id):  '" .. mod.id .. "'")
            logger.err("  Fix: Rename file to 'module_" .. mod.id .. ".lua' OR change M.id to '" .. module_id .. "'")
            goto continue_module
        end
        
        -- Store full metadata
        self._modules_meta[#self._modules_meta + 1] = mod
        
        -- If this is a new module, register it in settings with its default state
        if not is_known then
            local default_state = mod.default_enabled ~= false
            module_states[mod.id] = default_state
            self:_getSettings():saveSetting("module_states", module_states)
            self:_getSettings():flush()
        end
        
        -- Register module with SimpleUI if enabled
        if self:_isModuleEnabled(mod.id, mod.default_enabled) then
            Registry.register(mod)
            self._mod_ids[#self._mod_ids + 1] = mod.id
            self._mods[#self._mods + 1]       = mod
        end
        ::continue_module::
    end

    -- Apply patches from patches/.
    -- Hybrid approach: First-time discovery + subsequent skip for disabled patches.
    -- - New patches (not in settings): require() once to get metadata, store in settings
    -- - Known patches: check enabled state, skip require() if disabled
    -- This ensures all patches appear in menu while maximizing performance.
    self._patches_meta = {}
    local patch_states = self:_getSettings():readSetting("patch_states") or {}
    local existing_patches = {}  -- Track which patches exist (for cleanup later)
    
    for _i, path in ipairs(discover_patches(self.path)) do
        -- Extract patch_id from path (e.g., "patches/patch_coverdeck_exclude" -> "coverdeck_exclude")
        -- Note: [%w_]+ matches alphanumeric + underscore (not just %w which excludes underscore)
        local patch_id = path:match("patch_([%w_]+)$")
        if not patch_id then
            logger.warn("simpleui_ext: could not extract patch_id from path '" .. path .. "'")
            goto continue_patch
        end
        existing_patches[patch_id] = true  -- Mark as existing
        
        -- Check if this patch is known (exists in settings)
        -- IMPORTANT: We assume patch.id == filename-based patch_id for performance
        -- If they differ, the patch must be loaded to get the real ID
        local is_known = patch_states[patch_id] ~= nil
        
        if is_known then
            -- Known patch: check enabled state BEFORE require (performance optimization)
            if not self:_isPatchEnabled(patch_id, false) then
                -- Still need to add minimal metadata for menu (without requiring)
                self._patches_meta[#self._patches_meta + 1] = {
                    id = patch_id,
                    name = patch_id:gsub("_", " "):gsub("(%a)([%w_']*)", function(first, rest)
                        return first:upper() .. rest:lower()
                    end),
                    description = _("Disabled patch (enable to load)"),
                    default_enabled = false,
                }
                goto continue_patch
            end
        end
        
        -- New patch OR enabled patch: require() to get full metadata
        local ok3, patch = pcall(require, path)
        if not ok3 or type(patch) ~= "table" then
            logger.warn("simpleui_ext: failed to load patch '" .. path ..
                        "': " .. tostring(patch))
            goto continue_patch
        elseif type(patch.apply) ~= "function" then
            logger.warn("simpleui_ext: patch '" .. path ..
                        "' has no apply() function — skipped")
            goto continue_patch
        end
        
        -- Validate: patch.id MUST match filename-based patch_id
        if patch.id ~= patch_id then
            logger.err("simpleui_ext: patch '" .. path .. "' has mismatched ID — SKIPPED")
            logger.err("  Expected (from filename): '" .. patch_id .. "'")
            logger.err("  Actual (from patch.id):  '" .. patch.id .. "'")
            logger.err("  Fix: Rename file to 'patch_" .. patch.id .. ".lua' OR change P.id to '" .. patch_id .. "'")
            goto continue_patch
        end
        
        if is_known then
            -- Already known, check if enabled
            if not self:_isPatchEnabled(patch.id, false) then
                -- Still need to add minimal metadata for menu (without requiring)
                self._patches_meta[#self._patches_meta + 1] = {
                    id = patch_id,
                    name = patch_id:gsub("_", " "):gsub("(%a)([%w_']*)", function(first, rest)
                        return first:upper() .. rest:lower()
                    end),
                    description = _("Disabled patch (enable to load)"),
                    default_enabled = false,
                }
                goto continue_patch
            end
        end
        
        -- Store full metadata (patch already loaded above)
        self._patches_meta[#self._patches_meta + 1] = patch
        
        -- If this is a new patch, register it in settings with its default state
        if not is_known then
            local default_state = patch.default_enabled == true
            patch_states[patch.id] = default_state
            self:_getSettings():saveSetting("patch_states", patch_states)
            self:_getSettings():flush()
        end
        
        -- Apply patch if enabled
        if self:_isPatchEnabled(patch.id, patch.default_enabled) then
            local ok4, err = pcall(patch.apply)
            if not ok4 then
                logger.warn("simpleui_ext: patch '" .. (patch.id or path) ..
                            "' apply() failed: " .. tostring(err))
            end
        end
        ::continue_patch::
    end
    
    -- Cleanup: Remove deleted files from settings
    -- This prevents "ghost" entries in the menu for files that no longer exist
    local module_states_cleaned = false
    for module_id in pairs(module_states) do
        if not existing_modules[module_id] then
            module_states[module_id] = nil
            module_states_cleaned = true
        end
    end
    if module_states_cleaned then
        self:_getSettings():saveSetting("module_states", module_states)
        self:_getSettings():flush()
    end
    
    local patch_states_cleaned = false
    for patch_id in pairs(patch_states) do
        if not existing_patches[patch_id] then
            patch_states[patch_id] = nil
            patch_states_cleaned = true
        end
    end
    if patch_states_cleaned then
        self:_getSettings():saveSetting("patch_states", patch_states)
        self:_getSettings():flush()
    end
end

-- Runs once after _register. Opens the stats DB, pulls the current +
-- recent books from the shared prefetcher, and hands the result to every
-- module that exposes a `prewarm` hook. Without this, the home screen's
-- first paint runs under _defer_stats=true (db_conn=nil) and stats render
-- empty; with this, the SQL has already run and the first paint has data.
-- Every step is pcall-wrapped — a bad DB or any module's prewarm throwing
-- does not abort registration.
function SimpleUIExtPlugin:_prewarmBookModuleCaches()
    if not self._mods or #self._mods == 0 then return end

    pcall(function()
        local ok_cfg, Config = pcall(require, "sui_config")
        if not ok_cfg or not Config or type(Config.openStatsDB) ~= "function" then
            return
        end

        local db_conn = Config.openStatsDB()
        if not db_conn then return end

        local ok_sh, SH = pcall(require, "desktop_modules/module_books_shared")
        if not ok_sh or not SH or type(SH.prefetchBooks) ~= "function" then
            pcall(function() db_conn:close() end)
            return
        end

        local books_state
        pcall(function()
            -- 5 books: current + 4 most recent. Matches the typical
            -- "Recently read" rail width and keeps prewarm well under
            -- a frame even on cold cache.
            books_state = SH.prefetchBooks(true, true, 5)
        end)
        if not books_state then
            pcall(function() db_conn:close() end)
            return
        end

        for _i, mod in ipairs(self._mods) do
            if type(mod.prewarm) == "function" then
                pcall(function() mod.prewarm(books_state, db_conn) end)
            end
        end

        pcall(function() db_conn:close() end)
    end)
end

-- Flags a deferred refresh; _runDeferredStatsRefresh() does the actual
-- SQL re-query + repaint after the 2-second settle window.
function SimpleUIExtPlugin:onCloseDocument()
    for _i, mod in ipairs(self._mods) do
        if type(mod.invalidateCache) == "function" then
            mod.invalidateCache()
        end
    end

    -- Settle window: ReaderUI flushes page_stat rows synchronously on
    -- close, but a brief defer avoids racing with whatever else KOReader
    -- may still be writing (highlights, time-on-page). 2s gives the DB
    -- a comfortable margin without making the stats feel stale.
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(2, function()
        -- Bail if the reader reopened during the settle window.
        local ok_r, RUI = pcall(require, "apps/reader/readerui")
        if not ok_r or (RUI and RUI.instance) then return end

        -- Skip if the homescreen is not on screen — there is nothing to
        -- repaint, and the next HS open pulls fresh data on its own.
        local ok_hs, HS = pcall(require, "sui_homescreen")
        if not ok_hs or not HS or not HS._instance then return end

        self:_runDeferredStatsRefresh(HS._instance)
    end)
end

-- Single-shot: open a stats DB connection, run refreshStats on every
-- module that exposes it, close the connection, then trigger an HS
-- rebuild so the freshly-cached values appear in the next render.
--
-- Why _updatePage(false) and not setDirty("ui"): setDirty only repaints
-- existing widgets — fetchStatsFromDB lives inside the build path, so
-- the new cache values would never be read unless we force a rebuild.
-- _updatePage(false) clears _ctx_cache, so the next paint runs _buildCtx
-- and every module's build() sees the new cache.
function SimpleUIExtPlugin:_runDeferredStatsRefresh(hs_instance)
    local ok_cfg, Config = pcall(require, "sui_config")
    if not ok_cfg or not Config or type(Config.openStatsDB) ~= "function" then return end
    local db_conn = Config.openStatsDB()
    if not db_conn then return end

    for _i, mod in ipairs(self._mods) do
        if type(mod.refreshStats) == "function" then
            pcall(function() mod.refreshStats(nil, db_conn) end)
        end
    end
    pcall(function() db_conn:close() end)

    -- pcall-wrapped: _updatePage drives a full module rebuild and can
    -- throw if the homescreen is mid-teardown. UIManager:setDirty after
    -- a successful rebuild nudges E-ink to repaint immediately.
    pcall(function()
        hs_instance:_updatePage(false)
        local UIManager = require("ui/uimanager")
        UIManager:setDirty(hs_instance, "ui")
    end)
end

function SimpleUIExtPlugin:onClosePlugin()
    if self._registry then
        for _i, id in ipairs(self._mod_ids) do
            self._registry.unregister(id)
        end
    end
    self._registry     = nil
    self._mod_ids      = {}
    self._mods         = {}
    self._patches_meta = {}
    self._modules_meta = {}
end

-- ---------------------------------------------------------------------------
-- Menu Integration
-- ---------------------------------------------------------------------------
function SimpleUIExtPlugin:addToMainMenu(menu_list)
    menu_list["simpleui_ext"] = {
        text = _("SimpleUI Extra"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Patches"),
                sub_item_table_func = function() return self:_buildPatchMenu() end,
            },
            {
                text = _("Modules"),
                sub_item_table_func = function() return self:_buildModuleMenu() end,
            },
        },
    }
end

function SimpleUIExtPlugin:_buildPatchMenu()
    local Blitbuffer = require("ffi/blitbuffer")
    local UIManager  = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    
    local menu = {}
    for _i, patch in ipairs(self._patches_meta) do
        table.insert(menu, {
            text = patch.name or patch.id,
            help_text = patch.description,
            checked_func = function()
                return self:_isPatchEnabled(patch.id, patch.default_enabled)
            end,
            callback = function()
                local currently_enabled = self:_isPatchEnabled(patch.id, patch.default_enabled)
                self:_setPatchEnabled(patch.id, not currently_enabled)
                
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Patch '%s' %s.\n\nPlease restart KOReader for changes to take effect."),
                            patch.name or patch.id, currently_enabled and _("disabled") or _("enabled")),
                    timeout = 3,
                })
            end,
        })
    end
    
    if #menu == 0 then
        table.insert(menu, {
            text = _("No patches available"),
            enabled = false,
        })
    end
    
    return menu
end

function SimpleUIExtPlugin:_buildModuleMenu()
    local Blitbuffer = require("ffi/blitbuffer")
    local UIManager  = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    
    local menu = {}
    for _i, mod in ipairs(self._modules_meta) do
        table.insert(menu, {
            text = mod.name or mod.id,
            help_text = mod.description,
            checked_func = function()
                return self:_isModuleEnabled(mod.id, mod.default_enabled)
            end,
            callback = function()
                local currently_enabled = self:_isModuleEnabled(mod.id, mod.default_enabled)
                self:_setModuleEnabled(mod.id, not currently_enabled)
                
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Module '%s' %s.\n\nPlease restart KOReader for changes to take effect."),
                            mod.name or mod.id, currently_enabled and _("disabled") or _("enabled")),
                    timeout = 3,
                })
            end,
        })
    end
    
    if #menu == 0 then
        table.insert(menu, {
            text = _("No modules available"),
            enabled = false,
        })
    end
    
    return menu
end

return SimpleUIExtPlugin
