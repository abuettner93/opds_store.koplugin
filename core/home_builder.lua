-- Home Builder for OPDS Browser
-- Classifies a freshly-entered server's root nav entries into "shelves" (book covers,
-- rendered as a home-screen section) vs "browse links" (further navigation, no covers).
-- Backed by ShelfCache so repeat visits within the TTL window skip the network entirely.

local UIManager = require("ui/uimanager")

local Constants = require("models.constants")
local BrowserContext = require("core.browser_context")
local ShelfCache = require("services.shelf_cache")

local HomeBuilder = {}

local TTL_SECONDS = Constants.SHELF_CACHE.DEFAULT_TTL_MINUTES * 60

-- Keep only the fields the home screen actually renders / needs for navigation.
-- (Avoids caching heavy fields like raw entry.content HTML to disk.)
local function trimBookItem(item)
	return {
		text = item.text,
		title = item.title,
		author = item.author,
		cover_url = item.cover_url,
		lazy_load_cover = item.lazy_load_cover,
		acquisitions = item.acquisitions,
	}
end

-- Resolve a single root nav candidate into a cached shelf/browse-link classification.
-- @param candidate table {text, url} root nav entry
-- @param context table Browser context (auth, mime types, etc. from BrowserContext.fromBrowser)
-- @param debug_callback function|nil
-- @return table {label, source_url, is_shelf, items}
local function resolveCandidate(candidate, context, debug_callback)
	local cached = ShelfCache.get(candidate.url, TTL_SECONDS)
	if cached and not cached.stale then
		return cached
	end

	-- Lazy require: avoids a load-order cycle with navigation_handler, which requires
	-- this module to route root-entry rendering to the home screen.
	local FeedFetcher = require("core.feed_fetcher")
	local NavigationHandler = require("core.navigation_handler")

	local sub_items = FeedFetcher.genItemTableFromURL(
		candidate.url,
		context.username,
		context.password,
		debug_callback,
		function(catalog, url)
			local items = NavigationHandler.genItemTableFromCatalog(catalog, url, context, debug_callback)
			return items
		end
	) or {}

	local books = {}
	for _, sub_item in ipairs(sub_items) do
		if sub_item.cover_url and sub_item.acquisitions and #sub_item.acquisitions > 0 then
			table.insert(books, trimBookItem(sub_item))
			if #books >= Constants.SHELF_CACHE.ITEMS_PER_SHELF then
				break
			end
		end
	end

	local entry = {
		label = candidate.text,
		source_url = candidate.url,
		is_shelf = #books > 0,
		items = books,
	}

	ShelfCache.put(candidate.url, entry)
	return entry
end

-- Build the home screen data for a freshly-entered server root.
-- Synchronously resolves the first SYNC_CANDIDATES nav entries; stashes the rest on the
-- browser for deferred resolution via HomeBuilder.resolveRemaining, so first paint isn't
-- blocked on N sequential HTTP round-trips against a catalog with many nav entries.
-- @param browser table OPDSBrowser instance (browser.search_url already set by caller)
-- @param root_item_table table Parsed root feed item table
-- @return table {search_item, shelves = {...}, browse_links = {...}}
function HomeBuilder.build(browser, root_item_table)
	local context = BrowserContext.fromBrowser(browser)
	local debug_callback = function(...) if browser._debugLog then browser:_debugLog(...) end end

	local candidates = {}
	for _, item in ipairs(root_item_table) do
		if item.url and (not item.acquisitions or #item.acquisitions == 0) then
			table.insert(candidates, { text = item.text, url = item.url })
			if #candidates >= Constants.SHELF_CACHE.MAX_CANDIDATES then
				break
			end
		end
	end

	local home_data = {
		search_item = browser.search_url and { searchable = true, url = browser.search_url } or nil,
		shelves = {},
		browse_links = {},
	}

	local sync_count = math.min(#candidates, Constants.SHELF_CACHE.SYNC_CANDIDATES)
	for i = 1, sync_count do
		local entry = resolveCandidate(candidates[i], context, debug_callback)
		if entry.is_shelf then
			table.insert(home_data.shelves, entry)
		else
			table.insert(home_data.browse_links, { text = entry.label, url = entry.source_url })
		end
	end

	-- Remaining candidates resolve lazily, after the screen already has its first paint.
	browser._home_pending_candidates = {}
	for i = sync_count + 1, #candidates do
		table.insert(browser._home_pending_candidates, candidates[i])
	end
	browser._home_context = context
	browser._home_debug_callback = debug_callback

	return home_data
end

-- Resolve the next pending candidate (if any), merge it into browser.home_data, and
-- trigger a re-render. Reschedules itself until the pending queue is empty.
-- @param browser table OPDSBrowser instance
function HomeBuilder.resolveRemaining(browser)
	local pending = browser._home_pending_candidates
	if not pending or #pending == 0 then
		return
	end

	local candidate = table.remove(pending, 1)
	local entry = resolveCandidate(candidate, browser._home_context, browser._home_debug_callback)

	if browser.home_data then
		if entry.is_shelf then
			table.insert(browser.home_data.shelves, entry)
		else
			table.insert(browser.home_data.browse_links, { text = entry.label, url = entry.source_url })
		end
	end

	if #pending > 0 then
		UIManager:scheduleIn(0.5, function()
			HomeBuilder.resolveRemaining(browser)
		end)
	elseif browser.home_data and browser.is_home_screen and browser.updateItems then
		-- Render once, now that the full shelf set is known, instead of after every single
		-- candidate. OPDSHomeMenu.updateItems() unconditionally halts and restarts cover
		-- loading on each call (it has to -- it rebuilds every thumbnail widget from
		-- scratch), so re-rendering per-candidate was cancelling in-flight cover fetches
		-- for earlier shelves roughly every 0.5s. Only whichever shelf's covers happened to
		-- be first in the queue when the *last* restart landed ever got far enough to
		-- finish -- which is exactly the "only the first shelf's covers ever show up"
		-- symptom. Rendering once, after the queue drains, gives the resulting batch an
		-- uninterrupted run at the full item list.
		browser:updateItems()
	end
end

return HomeBuilder
