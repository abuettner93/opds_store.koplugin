-- Home Menu renderer for OPDS Browser
-- Renders the "store front" screen shown right after entering a server: a search row,
-- a few shelves of book covers (fixed row, no swipe - see plan notes), and plain
-- "browse by..." links for root nav entries that aren't shelves of books.
--
-- Follows the same override pattern as ui/menus/grid_menu.lua: it drives the host Menu
-- widget's internal item_group/layout/perpage directly rather than being a Menu subclass
-- of its own, so it plugs into OPDSCoverMenu the same way grid/list modes already do.

local UIUtils = require("ui.utils")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local Debug = require("utils.debug")
local Constants = require("models.constants")
local _ = require("gettext")

local HOME_CONFIG = {
	side_margin = 10,
	section_gap = 16,
	thumb_gap = 10,
	thumb_caption_gap = 4,
	cover_height_ratio = 0.16, -- fraction of screen height, deliberately larger than list default
	book_aspect_ratio = 2 / 3,
	row_height = 44,
}

-- ============================================
-- Shelf thumbnail cell (cover + caption)
-- Mirrors OPDSGridCell's self-contained init()/update() pattern so CoverLoader's
-- {entry=, widget=} lazy-load contract (rebuild widget after entry.cover_bb is set) works
-- unmodified.
-- ============================================
local HomeThumbnailWidget = InputContainer:extend {
	entry = nil,
	menu = nil,
	show_parent = nil,
	cover_width = nil,
	cover_height = nil,
}

function HomeThumbnailWidget:init()
	local cover_widget = UIUtils.buildCoverWidget(self.entry, self.cover_width, self.cover_height)

	local caption_face = Font:getFace("smallinfofont", 12)
	local title = self.entry.title or self.entry.text or ""
	local caption_text = UIUtils.truncateText(title, caption_face, self.cover_width)

	local caption = TextBoxWidget:new {
		text = caption_text,
		face = caption_face,
		width = self.cover_width,
		alignment = "center",
		fgcolor = Blitbuffer.COLOR_DARK_GRAY,
	}

	self.dimen = Geom:new {
		w = self.cover_width,
		h = self.cover_height + HOME_CONFIG.thumb_caption_gap + caption:getSize().h,
	}

	self.ges_events = {
		TapSelect = {
			GestureRange:new {
				ges = "tap",
				range = self.dimen,
			},
		},
	}

	self[1] = VerticalGroup:new {
		align = "center",
		cover_widget,
		VerticalSpan:new { width = HOME_CONFIG.thumb_caption_gap },
		caption,
	}
end

function HomeThumbnailWidget:update()
	self:init()
	UIManager:setDirty(self.show_parent, function()
		return "ui", self.dimen
	end)
end

function HomeThumbnailWidget:onTapSelect()
	if self.menu and self.menu.onMenuSelect then
		self.menu:onMenuSelect(self.entry)
	end
	return true
end

-- ============================================
-- Generic tappable row (search entry, browse link, shelf "See all" header)
-- Static content only (no async cover loading), so a thin wrapper is enough: tapping
-- dispatches straight to the host menu's existing onMenuSelect, reusing the exact same
-- navigation/search/download logic as normal browsing.
-- ============================================
local HomeTapRow = InputContainer:extend {
	entry = nil,
	menu = nil,
	child = nil,
	width = nil,
	height = nil,
}

function HomeTapRow:init()
	self.dimen = Geom:new { w = self.width, h = self.height }
	self.ges_events = {
		TapSelect = {
			GestureRange:new {
				ges = "tap",
				range = self.dimen,
			},
		},
	}
	self[1] = self.child
end

function HomeTapRow:onTapSelect()
	if self.menu and self.menu.onMenuSelect then
		self.menu:onMenuSelect(self.entry)
	end
	return true
end

local OPDSHomeMenu = {}

function OPDSHomeMenu:_debugLog(...)
	Debug.log("Home:", ...)
end

-- Build a full-width tappable text row (search entry, browse link, "See all" header).
local function buildTextRow(menu, entry_item, icon, text, width, opts)
	opts = opts or {}
	local face = Font:getFace("smallinfofont", opts.size or 16)

	local label = icon and (icon .. "  " .. text) or text
	local text_widget = TextWidget:new {
		text = label,
		face = face,
		bold = opts.bold,
		fgcolor = opts.color or Blitbuffer.COLOR_BLACK,
	}

	local row_height = math.max(HOME_CONFIG.row_height, text_widget:getSize().h + Size.padding.default * 2)

	local content = FrameContainer:new {
		width = width,
		height = row_height,
		padding = Size.padding.default,
		margin = 0,
		bordersize = 0,
		background = Blitbuffer.COLOR_WHITE,
		HorizontalGroup:new {
			align = "center",
			text_widget,
		},
	}

	local row = HomeTapRow:new {
		entry = entry_item,
		menu = menu,
		width = width,
		height = row_height,
		child = content,
	}

	return row, row_height
end

-- Build a shelf section: header/"See all" row + one fixed row of cover thumbnails.
-- Appends any lazy-cover thumbnails to items_to_update so the caller can schedule loading.
local function buildShelfSection(menu, shelf, width, thumb_width, thumb_height, items_to_update)
	local group = VerticalGroup:new { align = "left" }

	local see_all_item = { text = shelf.label, url = shelf.source_url }
	local header, header_height = buildTextRow(menu, see_all_item, nil,
		shelf.label .. "  \u{203A}", width, { bold = true, size = 18 })
	table.insert(group, header)
	table.insert(group, VerticalSpan:new { width = 6 })

	local max_thumbs = math.max(1, math.floor((width + HOME_CONFIG.thumb_gap) / (thumb_width + HOME_CONFIG.thumb_gap)))
	local count = math.min(#shelf.items, max_thumbs)

	local row = HorizontalGroup:new { align = "top" }
	local row_max_height = 0
	for i = 1, count do
		local item = shelf.items[i]
		local thumb = HomeThumbnailWidget:new {
			entry = item,
			menu = menu,
			show_parent = menu.show_parent,
			cover_width = thumb_width,
			cover_height = thumb_height,
		}
		table.insert(row, thumb)
		row_max_height = math.max(row_max_height, thumb.dimen.h)

		if item.cover_url and item.lazy_load_cover and not item.cover_bb then
			table.insert(items_to_update, { entry = item, widget = thumb })
		end

		if i < count then
			table.insert(row, HorizontalSpan:new { width = HOME_CONFIG.thumb_gap })
		end
	end
	table.insert(group, row)

	return group, header_height + 6 + row_max_height
end

-- Main entry point, called from OPDSCoverMenu:updateItems when browser.is_home_screen is true.
function OPDSHomeMenu.updateItems(self, select_number)
	if self.halt_image_loading then
		self.halt_image_loading()
		self.halt_image_loading = nil
	end

	self.layout = {}
	self.item_group:clear()
	self._items_to_update = {}

	local old_dimen = self.dimen and self.dimen:copy()

	-- Single-page layout: everything lives inside one scrollable body, so Menu's own
	-- chevron pagination is inert (overflow is handled by scroll, not extra pages).
	self.page = 1
	self.page_num = 1
	self.perpage = 1

	if self.page_info then
		self.page_info:resetLayout()
	end
	if self.return_button then
		self.return_button:resetLayout()
	end

	local available_width = self.inner_dimen.w - (HOME_CONFIG.side_margin * 2)
	local available_height = self.inner_dimen.h
	if not self.is_borderless then
		available_height = available_height - 2
	end
	if not self.no_title and self.title_bar then
		available_height = available_height - self.title_bar.dimen.h
	end
	if self.page_info then
		available_height = available_height - self.page_info:getSize().h
	end

	-- All shelves share one thumbnail size per render pass - CoverLoader renders every
	-- pending image at menu.cover_width/menu.cover_height for the batch, so this must
	-- match what buildShelfSection actually lays out.
	local thumb_height = math.floor(Screen:getHeight() * HOME_CONFIG.cover_height_ratio)
	local thumb_width = math.floor(thumb_height * HOME_CONFIG.book_aspect_ratio)
	self.cover_width = thumb_width
	self.cover_height = thumb_height

	local home_data = self.home_data or { shelves = {}, browse_links = {} }
	local content = VerticalGroup:new { align = "left" }

	if home_data.search_item then
		local search_row = buildTextRow(self, home_data.search_item, Constants.ICONS.SEARCH,
			_("Search this catalog"), available_width, { bold = true, size = 18 })
		table.insert(content, search_row)
		table.insert(content, VerticalSpan:new { width = HOME_CONFIG.section_gap })
	end

	for _, shelf in ipairs(home_data.shelves) do
		local section = buildShelfSection(self, shelf, available_width, thumb_width, thumb_height, self._items_to_update)
		table.insert(content, section)
		table.insert(content, VerticalSpan:new { width = HOME_CONFIG.section_gap })
	end

	if #home_data.browse_links > 0 then
		local browse_header = TextWidget:new {
			text = _("Browse by"),
			face = Font:getFace("smallinfofont", 16),
			bold = true,
			fgcolor = Blitbuffer.COLOR_BLACK,
		}
		table.insert(content, browse_header)
		table.insert(content, VerticalSpan:new { width = 6 })

		for _, link in ipairs(home_data.browse_links) do
			local row = buildTextRow(self, link, nil, link.text, available_width)
			table.insert(content, row)
		end
	end

	local scroll_body = ScrollableContainer:new {
		dimen = Geom:new {
			w = available_width + (HOME_CONFIG.side_margin * 2),
			h = math.max(available_height, 100),
		},
		show_parent = self.show_parent,
		HorizontalGroup:new {
			HorizontalSpan:new { width = HOME_CONFIG.side_margin },
			content,
		},
	}

	table.insert(self.item_group, scroll_body)
	table.insert(self.layout, { scroll_body })

	if self.updatePageInfo then
		self:updatePageInfo(select_number)
	end

	UIManager:setDirty(self.show_parent, function()
		local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
		return "ui", refresh_dimen
	end)

	if #self._items_to_update > 0 then
		self._scheduled_cover_load = function()
			if self._loadVisibleCovers then
				self:_loadVisibleCovers()
			end
		end
		UIManager:scheduleIn(1, self._scheduled_cover_load)
	end
end

function OPDSHomeMenu:_loadVisibleCovers()
	local CoverLoader = require("services.cover_loader")
	local halt = CoverLoader.loadVisibleCovers(self, function(...)
		self:_debugLog(...)
	end)
	if halt then
		self.halt_image_loading = halt
	end
end

function OPDSHomeMenu:onCloseWidget()
	-- Cancel any in-progress cover loading
	if self.halt_image_loading then
		self.halt_image_loading()
		self.halt_image_loading = nil
	end

	-- Home shelf items live off self.home_data, not self.item_table, so free their
	-- cover blitbuffers directly instead of relying on CoverLoader.cleanup's item_table walk.
	local home_data = self.home_data
	if home_data and home_data.shelves then
		for _, shelf in ipairs(home_data.shelves) do
			for _, item in ipairs(shelf.items) do
				if item.cover_bb then
					item.cover_bb:free()
					item.cover_bb = nil
				end
			end
		end
	end
end

return OPDSHomeMenu
