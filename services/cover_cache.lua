local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local bit = require("bit")
local Debug = require("utils.debug")

local CoverCache = {}

-- DataStorage:getDataDir() can return a path relative to koreader's own working
-- directory (observed on a Kindle sideload: it returns "."). Resolving that against
-- lfs.currentdir() *once*, here at module load, pins the cache to one fixed absolute
-- location for the lifetime of this process. Without this, if koreader's cwd at launch
-- ever differs between runs (launcher-dependent -- KUAL entries, direct exec, etc. don't
-- all guarantee the same cwd), "./cache/..." silently resolves to a *different* real
-- directory each time: files written in a previous session would exist on disk, visibly,
-- while the current session's relative lookups miss them entirely because they resolve
-- against a different base.
local function resolveDataDir()
	local data_dir = DataStorage:getDataDir()
	if data_dir:sub(1, 1) == "/" then
		return data_dir
	end

	local cwd = lfs.currentdir()
	if not cwd then
		return data_dir
	end

	if data_dir == "." then
		return cwd
	end
	return cwd .. "/" .. data_dir
end

local CACHE_DIR = resolveDataDir() .. "/cache/opds_store/covers"
Debug.error("CoverCache:", "cache dir resolved to", CACHE_DIR)

local function ensureDir(path)
	if lfs.attributes(path, "mode") == "directory" then
		return true
	end

	-- DataStorage:getDataDir() is not guaranteed to return an absolute path -- on some
	-- platforms (observed on a Kindle sideload) it returns "." (relative to koreader's
	-- cwd). Forcing a leading "/" onto the first segment unconditionally turned that into
	-- "/./cache/...", a bogus path anchored at the real filesystem root, which is
	-- read-only on Kindle firmware. Preserve relative vs. absolute based on the input.
	local current
	for part in path:gmatch("[^/]+") do
		if not current then
			current = (path:sub(1, 1) == "/") and ("/" .. part) or part
		else
			current = current .. "/" .. part
		end
		if lfs.attributes(current, "mode") ~= "directory" then
			local ok, err = lfs.mkdir(current)
			if not ok then
				Debug.error("CoverCache:", "mkdir failed for", current, ":", err or "unknown error")
				return false
			end
		end
	end
	return true
end

local function hashUrl(url)
	local h1 = 5381
	local h2 = 2166136261

	for i = 1, #url do
		local b = string.byte(url, i)
		h1 = bit.tobit(bit.bxor((h1 * 33), b))
		h2 = bit.tobit((h2 * 16777619) + b)
	end

	return bit.tohex(h1) .. bit.tohex(h2)
end

local function cachePath(url)
	return CACHE_DIR .. "/" .. hashUrl(url) .. ".img"
end

local function readFile(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

local function writeFile(path, content)
	local f, err = io.open(path, "wb")
	if not f then
		Debug.error("CoverCache:", "failed to open for write:", path, ":", err or "unknown error")
		return false
	end
	f:write(content)
	f:close()
	return true
end

local function listCacheFiles()
	local files = {}
	local total = 0

	if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
		return files, total
	end

	for name in lfs.dir(CACHE_DIR) do
		if name ~= "." and name ~= ".." and name:sub(-4) == ".img" then
			local path = CACHE_DIR .. "/" .. name
			local attr = lfs.attributes(path)
			if attr and attr.mode == "file" then
				local size = attr.size or 0
				table.insert(files, {
					path = path,
					size = size,
					mtime = attr.modification or 0,
				})
				total = total + size
			end
		end
	end

	return files, total
end

local function pruneToMaxBytes(max_bytes)
	if not max_bytes or max_bytes <= 0 then
		return
	end

	local files, total = listCacheFiles()
	if total <= max_bytes then
		return
	end

	table.sort(files, function(a, b)
		return a.mtime < b.mtime
	end)

	for _, file in ipairs(files) do
		if total <= max_bytes then
			break
		end

		os.remove(file.path)
		total = total - file.size
	end
end

function CoverCache.get(url, ttl_seconds)
	local path = cachePath(url)
	local attr = lfs.attributes(path)
	if not attr or attr.mode ~= "file" then
		Debug.error("CoverCache:", "no file at", path, "for", url)
		return nil
	end

	local content = readFile(path)
	if not content or content == "" then
		Debug.error("CoverCache:", "file at", path, "unreadable or empty")
		return nil
	end

	local age = os.time() - (attr.modification or 0)
	return {
		content = content,
		stale = ttl_seconds and age > ttl_seconds or false,
		age_seconds = age,
	}
end

function CoverCache.put(url, content, max_bytes)
	if not content or content == "" then
		return false
	end

	if not ensureDir(CACHE_DIR) then
		return false
	end

	local ok = writeFile(cachePath(url), content)
	if ok and max_bytes and max_bytes > 0 then
		pruneToMaxBytes(max_bytes)
	end
	return ok
end

function CoverCache.clear()
	if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
		return
	end

	for name in lfs.dir(CACHE_DIR) do
		if name ~= "." and name ~= ".." and name:sub(-4) == ".img" then
			os.remove(CACHE_DIR .. "/" .. name)
		end
	end
end

return CoverCache
