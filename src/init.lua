---@diagnostic disable: assign-type-mismatch

local ffi     = require("ffi")
local bit     = require("bit")
local buf     = require("string.buffer")
local deflate = require("deflate-sys")
local fs      = require("fs")
local path    = require("path")

ffi.cdef [[
  typedef struct __attribute__((packed)) {
    uint32_t sig; uint16_t ver, flags, method, mtime, mdate;
    uint32_t crc, compSize, uncompSize;
    uint16_t nameLen, extraLen;
  } ZipLocal;

  typedef struct __attribute__((packed)) {
    uint32_t sig; uint16_t verMade, verNeed, flags, method, mtime, mdate;
    uint32_t crc, compSize, uncompSize;
    uint16_t nameLen, extraLen, commentLen, disk, iattr;
    uint32_t eattr, offset;
  } ZipCD;

  typedef struct __attribute__((packed)) {
    uint32_t sig; uint16_t disk, diskCd, count, total;
    uint32_t cdSize, cdOffset;
    uint16_t commentLen;
  } ZipEOCD;

  typedef struct __attribute__((packed)) {
    char name[100], mode[8], uid[8], gid[8], size[12], mtime[12],
         checksum[8], typeflag, linkname[100], magic[6], version[2],
         uname[32], gname[32], devmajor[8], devminor[8], prefix[155], pad[12];
  } TarHeader;
]]

ffi.cdef [[
  int chmod(const char *path, unsigned int mode);
]]


---@class ZipLocal: ffi.cdata*
---@field sig       number
---@field ver       number
---@field flags     number
---@field method    number
---@field crc       number
---@field compSize  number
---@field uncompSize number
---@field nameLen   number
---@field extraLen  number

---@class ZipCD: ffi.cdata*
---@field sig        number
---@field crc        number
---@field compSize   number
---@field uncompSize number
---@field nameLen    number
---@field extraLen   number
---@field commentLen number
---@field method     number
---@field offset     number

---@class ZipEOCD: ffi.cdata*
---@field sig      number
---@field count    number
---@field total    number
---@field cdSize   number
---@field cdOffset number

---@class TarHeader: ffi.cdata*
---@field name     string
---@field mode     string
---@field size     string
---@field mtime    string
---@field checksum string
---@field typeflag number
---@field magic    string
---@field version  string

---@type fun(...): ZipLocal
local ZipLocalT     = ffi.typeof("ZipLocal")
---@type fun(...): ZipCD
local ZipCDT        = ffi.typeof("ZipCD")
---@type fun(...): ZipEOCD
local ZipEOCDT      = ffi.typeof("ZipEOCD")
---@type fun(): TarHeader
local TarHeaderT    = ffi.typeof("TarHeader")

local tarHeaderSize = ffi.sizeof("TarHeader")

--- Apply a POSIX permission mask to an extracted file. Exec bits matter for
--- scripts shipped inside src rocks (e.g. cqueues' mk/luapath). No-op on
--- Windows and for masks that carry no permission bits.
---@param out string
---@param mode number?
local function applyMode(out, mode)
	if jit.os == "Windows" then return end
	local mask = tonumber(mode)
	if not mask or mask <= 0 then return end
	local perms = mask % 512 -- keep rwxrwxrwx
	if perms ~= 0 then
		ffi.C.chmod(out, perms)
	end
end

---@param base    string
---@param name    string
---@param content string
---@param mode    number?
local function writeFile(base, name, content, mode)
	local out = path.join(base, name)
	fs.mkdirAll(path.dirname(out))
	fs.write(out, content)
	applyMode(out, mode)
end

-- ── ZIP entries ───────────────────────────────────────────────────────────────

---@class Archive.Entry
---@field content string? # Decompressed file bytes (nil for directory entries)
---@field mode number?    # POSIX permission bits (zip external attrs / tar mode)
---@field dir boolean?    # True for directory entries

--- Parse a zip archive into a flat table of `{ [name] = Entry }`.
---@param data string
---@return table<string, Archive.Entry>
local function zipEntries(data)
	local dptr    = ffi.cast("const uint8_t *", data)
	local eocdOff = #data - 22
	while eocdOff >= 0 and ffi.cast("ZipEOCD *", dptr + eocdOff).sig ~= 0x06054b50 do
		eocdOff = eocdOff - 1
	end
	assert(eocdOff >= 0, "ZIP: EOCD not found")
	---@type ZipEOCD
	local eocd = ffi.cast("ZipEOCD *", dptr + eocdOff)
	local cd   = ffi.cast("const uint8_t *", dptr + eocd.cdOffset)

	local entries = {}
	for _ = 1, eocd.total do
		---@type ZipCD
		local e = ffi.cast("ZipCD *", cd)
		assert(e.sig == 0x02014b50, "ZIP: bad CD entry")
		local name = ffi.string(cd + ffi.sizeof("ZipCD"), e.nameLen)
		if name:sub(-1) == "/" then
			entries[name] = { dir = true }
		else
			---@type ZipLocal
			local lh  = ffi.cast("ZipLocal *", dptr + e.offset)
			local raw = ffi.string(dptr + e.offset + ffi.sizeof("ZipLocal") + lh.nameLen + lh.extraLen, e.compSize)
			entries[name] = {
				content = e.method == 0 and raw or deflate.deflateDecompress(raw, e.uncompSize),
				mode    = bit.rshift(e.eattr, 16), -- high 16 bits carry the unix mode
			}
		end
		cd = cd + ffi.sizeof("ZipCD") + e.nameLen + e.extraLen + e.commentLen
	end
	return entries
end

-- ── ZIP save ──────────────────────────────────────────────────────────────────

---@param files  table<string, string>
---@param toPath string
local function zipSave(files, toPath)
	local out           = buf.new()
	local cdBuf         = buf.new()
	local offset, count = 0, 0

	for name, content in pairs(files) do
		local comp = deflate.deflateCompress(content, 6)
		local crc  = deflate.crc32(content)

		local lh   = ZipLocalT(0x04034b50, 20, 0, 8, 0, 0, crc, #comp, #content, #name, 0)
		out:putcdata(lh, ffi.sizeof(lh)); out:put(name, comp)

		local cd = ZipCDT(0x02014b50, 20, 20, 0, 8, 0, 0, crc, #comp, #content, #name, 0, 0, 0, 0, 0, offset)
		cdBuf:putcdata(cd, ffi.sizeof(cd)); cdBuf:put(name)

		offset = offset + ffi.sizeof(lh) + #name + #comp
		count  = count + 1
	end

	local cdStr = cdBuf:tostring()
	local eocd  = ZipEOCDT(0x06054b50, 0, 0, count, count, #cdStr, offset, 0)
	out:put(cdStr); out:putcdata(eocd, ffi.sizeof(eocd))
	return fs.write(toPath, out:tostring())
end

-- ── TAR entries ───────────────────────────────────────────────────────────────

--- Parse a tar archive into a flat table of `{ [name] = Entry }`.
---@param data string
---@return table<string, Archive.Entry>
local function tarEntries(data)
	local dptr     = ffi.cast("const uint8_t *", data)
	local pos      = 0
	local longName = nil
	local entries  = {}
	while pos + tarHeaderSize <= #data do
		---@type TarHeader
		local h = ffi.cast("TarHeader *", dptr + pos)
		if h.name[0] == 0 then break end
		local size = tonumber(ffi.string(h.size, 11), 8) or 0
		pos = pos + tarHeaderSize
		if h.typeflag == string.byte("L") then
			longName = ffi.string(dptr + pos, size):match("^([^%z]*)")
		else
			local prefix = ffi.string(h.prefix, 155):match("^([^%z]*)")
			local name = ffi.string(h.name, 100):match("^([^%z]*)")
			if #prefix > 0 then name = prefix .. "/" .. name end
			if longName then name = longName end
			if h.typeflag == string.byte("5") or name:sub(-1) == "/" then
				entries[name] = { dir = true }
			elseif h.typeflag == string.byte("0") or h.typeflag == 0 then
				entries[name] = {
					content = ffi.string(dptr + pos, size),
					mode    = tonumber(ffi.string(h.mode, 8), 8),
				}
			end
			longName = nil
		end
		pos = pos + math.ceil(size / 512) * 512
	end
	return entries
end

-- ── decode ────────────────────────────────────────────────────────────────────

--- Detect the format from magic bytes and decode into a flat entry table.
---@param data string
---@return table<string, Archive.Entry>
local function decode(data)
	local a, b, c, d = data:byte(1, 4)
	if a == 0x50 and b == 0x4B and ((c == 0x03 and d == 0x04) or (c == 0x05 and d == 0x06)) then
		return zipEntries(data)
	end
	local raw = a == 0x1F and b == 0x8B
		and deflate.gzipDecompress(data, math.max(#data * 10, 1024 * 1024))
		or data
	return tarEntries(raw)
end

-- ── TAR save ─────────────────────────────────────────────────────────────────

---@param files  table<string, string>
---@param toPath string
local function tarSave(files, toPath)
	local out = buf.new()
	for name, content in pairs(files) do
		---@type TarHeader
		local h = TarHeaderT()
		if #name <= 100 then
			ffi.copy(h.name, name, #name)
		else
			local split = nil
			for i = math.min(155, #name), 1, -1 do
				if name:byte(i) == string.byte("/") then
					if i - 1 <= 155 and #name - i <= 100 then
						split = i
						break
					end
				end
			end
			if split then
				ffi.copy(h.prefix, name:sub(1, split - 1), split - 1)
				ffi.copy(h.name, name:sub(split + 1), #name - split)
			else
				ffi.copy(h.name, name, math.min(#name, 100))
			end
		end
		ffi.copy(h.mode, "0000644\0", 8)
		ffi.copy(h.size, string.format("%011o", #content), 11)
		ffi.copy(h.mtime, "00000000000", 11)
		ffi.copy(h.magic, "ustar", 5)
		ffi.copy(h.version, "00", 2)
		h.typeflag = string.byte("0")
		local sum  = 8 * 32
		local hp   = ffi.cast("const uint8_t *", h)
		for i = 0, tarHeaderSize - 1 do sum = sum + hp[i] end
		ffi.copy(h.checksum, string.format("%06o\0 ", sum), 8)
		out:putcdata(h, tarHeaderSize)
		out:put(content)
		local pad = (512 - (#content % 512)) % 512
		if pad > 0 then out:put(string.rep("\0", pad)) end
	end
	out:put(string.rep("\0", 1024))
	local tarData = out:tostring()
	local final   = toPath:match("%.tar%.gz$") and deflate.gzipCompress(tarData) or tarData
	return fs.write(toPath, final)
end

-- ── Archive ───────────────────────────────────────────────────────────────────

---@class Archive
---@field _source string | table<string, string>? # Path to decode, or `{ [path] = content }` to encode
---@field _data string? # Raw archive bytes when constructed from content
local Archive = {}
Archive.__index = Archive

---@class Archive.ExtractOptions
---@field stripComponents boolean?

--- Heuristic: does the string look like raw archive bytes rather than a path?
--- Matches zip local headers / empty-zip EOCDs ("PK.."), gzip streams, and
--- tar headers (the "ustar" magic at offset 257).
---@param s string
---@return boolean
local function looksLikeContent(s)
	if #s < 4 then return false end
	local a, b, c, d = s:byte(1, 4)
	if a == 0x50 and b == 0x4B and ((c == 0x03 and d == 0x04) or (c == 0x05 and d == 0x06)) then
		return true
	end
	if a == 0x1F and b == 0x8B then return true end
	return #s >= 262 and s:sub(258, 262) == "ustar"
end

--- Create a new Archive.
--- Pass a file path string to decode, a raw archive byte string to decode in
--- memory, or a table of `{ [path] = content }` to encode. Strings that begin
--- with a known archive magic (zip, gzip, or tar) are treated as raw contents;
--- anything else is treated as a path.
---@param source string | table<string, string>
---@return Archive
function Archive.new(source)
	local self = setmetatable({}, Archive)
	if type(source) == "string" and looksLikeContent(source) then
		self._data = source
	else
		self._source = source
	end
	return self
end

--- Decode the archive's data (raw bytes, or read from the backing file)
--- into a flat table of `{ [name] = Entry }`.
---@return table<string, Archive.Entry>?
---@return string? err
function Archive:_decode()
	local data
	if self._data then
		data = self._data
	else
		local src = self._source
		if type(src) == "string" then
			data = fs.read(src)
			if not data then return nil, "cannot open: " .. src end
		else
			return nil, "archive is not backed by file data"
		end
	end
	local ok, res = pcall(decode, data)
	if not ok then return nil, tostring(res) end
	return res
end

--- Extract the archive to the given output directory.
---@param toPath string
---@param opts   Archive.ExtractOptions?
---@return boolean ok
---@return string? err
function Archive:extract(toPath, opts)
	if type(self._source) == "table" then
		return false, "extract() is only valid for file-backed archives"
	end

	local ok, err = pcall(function()
		local entries, derr = self:_decode()
		if not entries then error(derr) end

		local strip = opts and opts.stripComponents or false
		fs.mkdir(toPath)
		for name, entry in pairs(entries) do
			if strip then name = name:match("^[^/]*/(.+)") or name end
			if entry.dir then
				fs.mkdirAll(path.join(toPath, name))
			else
				writeFile(toPath, name, entry.content, entry.mode)
			end
		end
	end)

	if not ok then return false, err end
	return true
end

--- Read a single file's contents by name without extracting to disk.
--- For table-backed archives this is a direct lookup.
---@param name string
---@return string? content
---@return string? err
function Archive:read(name)
	if type(self._source) == "table" then
		local content = self._source[name]
		return type(content) == "string" and content or nil
	end

	local entries, err = self:_decode()
	if not entries then return nil, err end
	local entry = entries[name]
	if not entry or entry.dir then return nil end
	return entry.content
end

--- Save the in-memory file table to an archive.
--- Infers format from extension: `.zip`, `.tar`, or `.tar.gz`.
---@param toPath string
---@return boolean ok
---@return string? err
function Archive:save(toPath)
	local src = self._source
	if type(src) ~= "table" then return false, "save() is only valid for table-backed archives" end
	local isZip = toPath:match("%.zip$")
	local isTar = toPath:match("%.tar")
	if not isZip and not isTar then
		return false, "cannot determine archive format from path (expected .zip or .tar.gz)"
	end
	local ok, err = pcall(function()
		if isZip then zipSave(src, toPath) else tarSave(src, toPath) end
	end)
	if not ok then return false, err end
	return true
end

return Archive
