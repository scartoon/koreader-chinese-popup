--[[--
Chinese popup: tap a Chinese character to see its CC-CEDICT entry and every
dictionary word around it that contains it. Nothing is computed until a tap.

  cp_text.lua     Han detection, candidate words, ordering, popup text (pure Lua)
  cp_context.lua  tap -> character and its neighbours, through CreDocument
  cp_db.lua       data/cedict.sqlite lookups (KOReader's bundled SQLite binding)
  cp_popup.lua    the popup (from the interlinear-pinyin plugin)

Companion to the interlinear-pinyin plugin, which lists this plugin's touch zone
in its own zone's `overrides`, so a tap on a pinyin-annotated character reaches
that plugin first. Each plugin works without the other.
]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Text = require("cp_text")
local Context = require("cp_context")

local ChinesePopup = WidgetContainer:extend{
    name = "chinesepopup",
    is_doc_only = true,
}

ChinesePopup.VERSION = "0.1.0"

local PREFIX = "chinesepopup_"
local BUTTONS_PER_ROW = 4

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

function ChinesePopup:isEnabled()
    local value = G_reader_settings and G_reader_settings:readSetting(PREFIX .. "enabled")
    if value == nil then return true end
    return value == true
end

function ChinesePopup:setEnabled(on)
    if not G_reader_settings then return end
    G_reader_settings:saveSetting(PREFIX .. "enabled", on)
    if G_reader_settings.flush then pcall(function() G_reader_settings:flush() end) end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

function ChinesePopup:init()
    if self.ui and self.ui.menu then
        pcall(function() self.ui.menu:registerToMainMenu(self) end)
    end
end

-- v1: reflowable (CreDocument) only. PDF/DjVu/CBZ register nothing, so every
-- tap there is KOReader's.
function ChinesePopup:isCompatibleDocument()
    local document = self.ui and self.ui.document
    return document ~= nil and self.ui.rolling ~= nil and document.getTextFromXPointers ~= nil
end

function ChinesePopup:onReaderReady()
    self:updateTapZone()
end

function ChinesePopup:onCloseDocument()
    if self.db then self.db:close() end
    self.db = nil
end

------------------------------------------------------------------------
-- Tap handling
------------------------------------------------------------------------

-- One full-screen "tap" zone, like ReaderHighlight's readerhighlight_tap and
-- the interlinear-pinyin plugin's zone: it overrides the page-turn, menu,
-- footer and corner zones so it is asked first, and returns false (the tap
-- falls through to them) unless the tap is on a Chinese character's glyph.
-- Links and highlights come earlier (registered before plugins) and are also
-- checked in the handler. The pinyin plugin's zone overrides this one by id.
-- Nothing is registered for hold, swipe or any other gesture.
ChinesePopup.TAP_ZONE_ID = "chinesepopup_tap"

function ChinesePopup:tapZone()
    return {
        id = ChinesePopup.TAP_ZONE_ID,
        ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        overrides = {
            "tap_top_left_corner",
            "tap_top_right_corner",
            "tap_left_bottom_corner",
            "tap_right_bottom_corner",
            "readerfooter_tap",
            "readerconfigmenu_ext_tap",
            "readerconfigmenu_tap",
            "readermenu_ext_tap",
            "readermenu_tap",
            "tap_forward",
            "tap_backward",
        },
        handler = function(ges) return self:onTapCharacter(ges) end,
    }
end

function ChinesePopup:updateTapZone()
    local ui = self.ui
    if not ui or not ui.registerTouchZones or not Device:isTouchDevice() then return end
    local want = self:isEnabled() and self:isCompatibleDocument()
    if want and not self._tap_registered then
        ui:registerTouchZones({ self:tapZone() })
        self._tap_registered = true
    elseif not want and self._tap_registered then
        ui:unRegisterTouchZones({ self:tapZone() })
        self._tap_registered = false
    end
end

function ChinesePopup:tapIsOnLink(pos)
    local document = self.ui.document
    if not document or not document.getLinkFromPosition then return false end
    local ok, link = pcall(document.getLinkFromPosition, document, pos)
    return ok and link ~= nil and link ~= ""
end

-- Same test as ReaderHighlight:onTap.
function ChinesePopup:tapIsOnHighlight(pos)
    local view = self.ui.view
    local boxes = view and view.highlight and view.highlight.visible_boxes
    if not boxes or #boxes == 0 then return false end
    for _, box in ipairs(boxes) do
        local r = box.rect
        if r and r.x <= pos.x and r.y <= pos.y and r.x + r.w >= pos.x and r.y + r.h >= pos.y then
            return true
        end
    end
    return false
end

function ChinesePopup:textHeight()
    local ok, size = pcall(function() return self.ui.document:getFontSize() end)
    return ok and tonumber(size) or nil
end

function ChinesePopup:onTapCharacter(ges)
    if not self:isEnabled() or not ges or not ges.pos then return false end
    local highlight = self.ui.highlight
    -- A tap while selecting text, or in highlight select mode, is ReaderHighlight's.
    if highlight and (highlight.hold_pos or highlight.select_mode) then return false end
    local ok, result = pcall(function()
        local pos = { x = ges.pos.x, y = ges.pos.y }
        local hit = Context.charAt(self.ui.document, pos, self:textHeight())
        if not hit then return false end
        if self:tapIsOnLink(ges.pos) or self:tapIsOnHighlight(pos) then return false end
        self:showPopup(hit)
        return true
    end)
    if not ok then
        logger.warn("chinesepopup: tap failed:", tostring(result))
        return false
    end
    return result
end

------------------------------------------------------------------------
-- Lookup and popup
------------------------------------------------------------------------

-- Opened on the first tap and kept until the book is closed.
function ChinesePopup:getDB()
    if self.db then return self.db end
    if self._db_error then return nil end
    local DB = require("cp_db")
    local db, err = DB.open(self.path .. "/data/cedict.sqlite")
    if not db then
        logger.warn("chinesepopup:", err)
        self._db_error = err
    end
    self.db = db
    return db
end

function ChinesePopup:lookupInKOReader(text, box)
    local dictionary = self.ui and self.ui.dictionary
    if not dictionary then return end
    dictionary:onLookupWord(text, false, box and { box } or nil)
end

-- The ordered matches for a hit (Text.order's result), or nil, err.
function ChinesePopup:matchesFor(hit)
    local db = self:getDB()
    if not db then return nil, self._db_error end
    local left, right = Context.around(self.ui.document, hit)
    local cands, texts = Text.candidates(left, hit.char, right)
    return Text.order(cands, db:lookup(texts)), left, right
end

function ChinesePopup:showPopup(hit)
    local time = require("ui/time")
    local t0 = time.monotonic()
    local matches, left, right = self:matchesFor(hit)
    if not matches then
        -- No database (data/cedict.sqlite missing): say so; left holds the error.
        UIManager:show(InfoMessage:new{
            text = T(_("Chinese popup: dictionary not available (%1)."), tostring(left)), timeout = 4 })
        return
    end
    if #matches == 0 then
        -- Nothing in CC-CEDICT: straight to KOReader's dictionaries.
        self:lookupInKOReader(hit.char, hit.box)
        return
    end
    local Popup = require("cp_popup")
    local popup
    local buttons = {}
    for _, m in ipairs(matches) do
        local word = m.word
        buttons[#buttons + 1] = {
            text = word,
            callback = function()
                UIManager:close(popup, "ui", popup.frame.dimen)
                self:lookupInKOReader(word, hit.box)
            end,
        }
    end
    buttons[#buttons + 1] = { text = _("Close"), callback = function() popup:onClose() end }
    popup = Popup:new{
        title = hit.char,
        text = Text.render(matches, Popup.BOLD_START, Popup.BOLD_END),
        buttons = Text.rows(buttons, BUTTONS_PER_ROW),
        anchor = hit.box,
    }
    UIManager:show(popup)
    logger.dbg(string.format("chinesepopup: %s [%s|%s] %d matches in %.1f ms",
        hit.char, table.concat(left, ""), table.concat(right, ""), #matches,
        time.to_ms(time.monotonic() - t0)))
end

------------------------------------------------------------------------
-- Menu
------------------------------------------------------------------------

function ChinesePopup:addToMainMenu(menu_items)
    local plugin = self
    menu_items.chinesepopup = {
        text = _("Chinese popup"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Tap a Chinese character for its words"),
                help_text = _("A single tap on a Chinese character shows its CC-CEDICT entry and every dictionary word around it that contains it. Other taps turn the page as usual; long-press is unchanged."),
                checked_func = function() return plugin:isEnabled() end,
                callback = function()
                    plugin:setEnabled(not plugin:isEnabled())
                    plugin:updateTapZone()
                end,
            },
        },
    }
end

return ChinesePopup
