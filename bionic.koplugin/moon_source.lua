--[[--
月读 (Moon) extension descriptor: adds a "Bionic reading" button to 月读's reader quick panel.

月读 dofile()s this file after all plugins are loaded. If 月读 is not installed nothing ever
loads it, so it is harmless. The plugin itself (main.lua) works with or without 月读.
Contract: see examples/moonsource-demo.koplugin/moon_source.lua in the 月读 repository.
--]]

local I18n = require("bionic_i18n")

local ok, Registry = pcall(require, "source.registry")

local function plugin(ctx)
    return ctx and ctx.ui and ctx.ui.bionic
end

return {
    api = ok and Registry.API or 1,
    id = "ext.bionic",
    provides = { source = false },
    features = {
        panel = {
            actions = function()
                return {
                    {
                        id = "toggle", -- becomes ext.bionic.toggle; do not rename once released
                        title = I18n.tr("Bionic reading"),
                        icon = "format_bold",
                        scope = "reader",
                        -- always listed in the settings page (no ui); in a book only when it can work there
                        available = function(ctx)
                            if not (ctx and ctx.ui) then return true end
                            local p = plugin(ctx)
                            return p ~= nil and p:canToggle()
                        end,
                        active = function(ctx)
                            local p = plugin(ctx)
                            return p ~= nil and p:isActive()
                        end,
                        run = function(ctx)
                            local p = plugin(ctx)
                            if p then p:toggle() end
                        end,
                    },
                }
            end,
        },
    },
}
