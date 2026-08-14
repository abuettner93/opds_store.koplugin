-- Shelf Cache for OPDS Store home screen
-- Disk-backed cache of classified root nav entries (shelf-of-books vs plain browse link)
-- Mirrors services/cover_cache.lua, but stores structured item metadata instead of image bytes.

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local bit = require("bit")

local ShelfCache = {}

local CACHE_FILE = DataStorage:getDataDir() .. "/cache/opds_store/shelf_cache.lua"
local ROOT_KEY = "shelves"

local storage

local function getStorage()
	if not storage then
		storage = LuaSettings:open(CACHE_FILE)
	end
	return storage
end

local function hashUrl(url)
	-- See services/cover_cache.lua's hashUrl for why h2 uses a small multiplier kept in
	-- 32-bit range every step, instead of FNV-1a's real prime/offset-basis constants: the
	-- FNV multiply overflows a double's exact 2^53 integer range once the accumulator
	-- reaches full 32-bit magnitude, and the resulting precision loss isn't stable across
	-- LuaJIT's interpreted vs. JIT-compiled paths -- confirmed live on a Kindle, where the
	-- same URL hashed differently across calls.
	local h1 = 5381
	local h2 = 52711

	for i = 1, #url do
		local b = string.byte(url, i)
		h1 = bit.tobit(bit.bxor((h1 * 33), b))
		h2 = bit.tobit(bit.bxor((h2 * 33) + i, b))
	end

	return bit.tohex(h1) .. bit.tohex(h2)
end

--- Get a cached shelf classification/entry for a source URL
-- @param url string Source URL the entry was fetched from
-- @param ttl_seconds number|nil TTL in seconds; nil/0 = never stale
-- @return table|nil {label, source_url, is_shelf, items, fetched_at, stale} or nil if not cached
function ShelfCache.get(url, ttl_seconds)
	local shelves = getStorage():readSetting(ROOT_KEY, {})
	local entry = shelves[hashUrl(url)]
	if not entry then
		return nil
	end

	local age = os.time() - (entry.fetched_at or 0)
	entry.stale = ttl_seconds and ttl_seconds > 0 and age > ttl_seconds or false
	entry.age_seconds = age
	return entry
end

--- Store a shelf classification/entry for a source URL
-- @param url string Source URL the entry was fetched from
-- @param entry table {label, source_url, is_shelf, items}
function ShelfCache.put(url, entry)
	local store = getStorage()
	local shelves = store:readSetting(ROOT_KEY, {})

	entry.fetched_at = os.time()
	shelves[hashUrl(url)] = entry

	store:saveSetting(ROOT_KEY, shelves)
	store:flush()
end

--- Clear all cached shelf data
function ShelfCache.clear()
	local store = getStorage()
	store:saveSetting(ROOT_KEY, {})
	store:flush()
end

return ShelfCache
