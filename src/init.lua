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
---@field eattr      number
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
---@field prefix   string

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

---@class Archive.ZipEntryInfo
---@field name string
---@field dir boolean
---@field method number
---@field compSize number
---@field uncompSize number
---@field mode number?
---@field offset number

--- Walk a zip archive's central directory, returning entry descriptors in
--- archive order. Keeps only metadata in memory; entry data is read lazily.
---@param data string
---@return Archive.ZipEntryInfo[]
local function zipCDEntries(data)
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
		entries[#entries + 1] = {
			name       = name,
			dir        = name:sub(-1) == "/",
			method     = e.method,
			compSize   = e.compSize,
			uncompSize = e.uncompSize,
			mode       = bit.rshift(e.eattr, 16), -- high 16 bits carry the unix mode
			offset     = e.offset,
		}
		cd = cd + ffi.sizeof("ZipCD") + e.nameLen + e.extraLen + e.commentLen
	end
	return entries
end

--- Parse a zip archive into a flat table of `{ [name] = Entry }`.
---@param data string
---@return table<string, Archive.Entry>
local function zipEntries(data)
	local dptr    = ffi.cast("const uint8_t *", data)
	local entries = {}
	for _, info in ipairs(zipCDEntries(data)) do
		if info.dir then
			entries[info.name] = { dir = true }
		else
			---@type ZipLocal
			local lh  = ffi.cast("ZipLocal *", dptr + info.offset)
			local raw = ffi.string(dptr + info.offset + ffi.sizeof("ZipLocal") + lh.nameLen + lh.extraLen, info.compSize)
			entries[info.name] = {
				content = info.method == 0 and raw or deflate.deflateDecompress(raw, info.uncompSize),
				mode    = info.mode,
			}
		end
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

--- Iterate a tar archive's entries lazily, in archive order. Yields
--- `(name, size, mode, isDir, dataOffset)` for file entries and
--- `(name, nil, mode, true, nil)` for directories. Handles GNU long names
--- (typeflag 'L'). File contents are left in the buffer — callers read them
--- from `dataOffset` and discard them, so only one file is ever materialized
--- at a time.
---@param data string
---@return fun(): string?, number?, number?, boolean?, number??
local function tarIter(data)
	local dptr     = ffi.cast("const uint8_t *", data)
	local pos      = 0
	local longName = nil
	return function()
		while pos + tarHeaderSize <= #data do
			---@type TarHeader
			local h = ffi.cast("TarHeader *", dptr + pos)
			if h.name[0] == 0 then return nil end
			local size    = tonumber(ffi.string(h.size, 11), 8) or 0
			local dataOff = pos + tarHeaderSize
			pos = pos + tarHeaderSize + math.ceil(size / 512) * 512
			if h.typeflag == string.byte("L") then
				longName = ffi.string(dptr + dataOff, size):match("^([^%z]*)")
			else
				local prefix = ffi.string(h.prefix, 155):match("^([^%z]*)")
				local name = ffi.string(h.name, 100):match("^([^%z]*)")
				if #prefix > 0 then name = prefix .. "/" .. name end
				if longName then name = longName end
				longName = nil
				if h.typeflag == string.byte("5") or name:sub(-1) == "/" then
					return name, nil, tonumber(ffi.string(h.mode, 8), 8), true, nil
				elseif h.typeflag == string.byte("0") or h.typeflag == 0 then
					return name, size, tonumber(ffi.string(h.mode, 8), 8), false, dataOff
				end
			end
		end
		return nil
	end
end

--- Parse a tar archive into a flat table of `{ [name] = Entry }`.
---@param data string
---@return table<string, Archive.Entry>
local function tarEntries(data)
	local dptr    = ffi.cast("const uint8_t *", data)
	local entries = {}
	for name, size, mode, isDir, dataOff in tarIter(data) do
		if isDir then
			entries[name] = { dir = true }
		else
			entries[name] = {
				content = ffi.string(dptr + dataOff, size),
				mode    = mode,
			}
		end
	end
	return entries
end

-- ── decode ────────────────────────────────────────────────────────────────────

---@alias Archive.Format "zip" | "tar" | "targz"

--- Detect the archive format from its magic bytes.
---@param data string
---@return Archive.Format
local function sniff(data)
	local a, b, c, d = data:byte(1, 4)
	if a == 0x50 and b == 0x4B and ((c == 0x03 and d == 0x04) or (c == 0x05 and d == 0x06)) then
		return "zip"
	end
	if a == 0x1F and b == 0x8B then return "targz" end
	return "tar"
end

--- Decompress gzip-wrapped tar data; passthrough for plain tar.
---@param data string
---@return string
local function tarData(data)
	local a, b = data:byte(1, 2)
	if a == 0x1F and b == 0x8B then
		-- The gzip footer stores the uncompressed size (ISIZE, mod 2^32). Prefer
		-- it over guessing from the compressed size, which fails for highly
		-- compressible payloads (tar.gz of text compresses well past 10x).
		local maxSize = math.max(#data * 10, 1024 * 1024)
		if #data >= 18 then
			local b1, b2, b3, b4 = data:byte(-4, -1)
			local isize = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
			if isize > 0 then maxSize = isize end
		end
		return deflate.gzipDecompress(data, maxSize)
	end
	return data
end

--- Detect the format from magic bytes and decode into a flat entry table.
---@param data string
---@return table<string, Archive.Entry>
local function decode(data)
	if sniff(data) == "zip" then return zipEntries(data) end
	return tarEntries(tarData(data))
end

-- ── streaming extract ─────────────────────────────────────────────────────────

--- Detect the format of an archive file on disk from its first bytes.
---@param src string
---@return Archive.Format
local function sniffFile(src)
	local f = io.open(src, "rb")
	if not f then return "tar" end -- let the read fail with a clearer error later
	local head = f:read(4) or ""
	f:close()
	return sniff(head)
end

--- Extract the entries of an in-memory tar (already decompressed) to disk,
--- one file at a time.
---@param data string
---@param toPath string
---@param strip boolean
local function tarExtractString(data, toPath, strip)
	local dptr = ffi.cast("const uint8_t *", data)
	for name, size, mode, isDir, dataOff in tarIter(data) do
		if strip then name = name:match("^[^/]*/(.+)") or name end
		if isDir then
			fs.mkdirAll(path.join(toPath, name))
		else
			writeFile(toPath, name, ffi.string(dptr + dataOff, size), mode)
		end
	end
end

--- Extract the entries of an in-memory zip archive to disk, one file at a time.
---@param data string
---@param toPath string
---@param strip boolean
local function zipExtractString(data, toPath, strip)
	local dptr = ffi.cast("const uint8_t *", data)
	for _, info in ipairs(zipCDEntries(data)) do
		local name = info.name
		if strip then name = name:match("^[^/]*/(.+)") or name end
		if info.dir then
			fs.mkdirAll(path.join(toPath, name))
		else
			---@type ZipLocal
			local lh  = ffi.cast("ZipLocal *", dptr + info.offset)
			local raw = ffi.string(dptr + info.offset + ffi.sizeof("ZipLocal") + lh.nameLen + lh.extraLen, info.compSize)
			writeFile(toPath, name,
				info.method == 0 and raw or deflate.deflateDecompress(raw, info.uncompSize),
				info.mode)
		end
	end
end

--- Extract the entries of a zip file on disk to disk, one file at a time.
--- Reads the central directory (metadata only) up front, then seeks to each
--- entry's data and writes it before moving on, so peak memory stays flat
--- instead of holding the whole archive and every file at once.
---@param src string
---@param toPath string
---@param strip boolean
local function zipExtractFile(src, toPath, strip)
	local f = assert(io.open(src, "rb"), "cannot open: " .. src)
	local ok, err = pcall(function()
		-- The EOCD sits at the end of the file; a comment of up to 64 KiB may follow it.
		local size    = f:seek("end")
		local tailLen = math.min(size, 22 + 65535)
		f:seek("set", size - tailLen)
		local tail = assert(f:read(tailLen), "ZIP: truncated file")

		local tptr    = ffi.cast("const uint8_t *", tail)
		local eocdOff = tailLen - 22
		while eocdOff >= 0 and ffi.cast("ZipEOCD *", tptr + eocdOff).sig ~= 0x06054b50 do
			eocdOff = eocdOff - 1
		end
		assert(eocdOff >= 0, "ZIP: EOCD not found")
		---@type ZipEOCD
		local eocd = ffi.cast("ZipEOCD *", tptr + eocdOff)

		f:seek("set", eocd.cdOffset)
		local cd    = assert(f:read(eocd.cdSize), "ZIP: truncated central directory")
		local cdptr = ffi.cast("const uint8_t *", cd)
		local cdPos = 0
		for _ = 1, eocd.total do
			---@type ZipCD
			local e = ffi.cast("ZipCD *", cdptr + cdPos)
			assert(e.sig == 0x02014b50, "ZIP: bad CD entry")
			local name = ffi.string(cdptr + cdPos + ffi.sizeof("ZipCD"), e.nameLen)
			local offset, compSize, uncompSize, method, mode =
				e.offset, e.compSize, e.uncompSize, e.method, bit.rshift(e.eattr, 16)
			cdPos = cdPos + ffi.sizeof("ZipCD") + e.nameLen + e.extraLen + e.commentLen

			if strip then name = name:match("^[^/]*/(.+)") or name end
			if name:sub(-1) == "/" then
				fs.mkdirAll(path.join(toPath, name))
			else
				-- Skip the local header (name/extra lengths) to reach the data.
				f:seek("set", offset)
				local lhRaw = assert(f:read(ffi.sizeof("ZipLocal")), "ZIP: truncated local header")
				---@type ZipLocal
				local lh    = ffi.cast("ZipLocal *", ffi.cast("const uint8_t *", lhRaw))
				f:seek("set", offset + ffi.sizeof("ZipLocal") + lh.nameLen + lh.extraLen)
				local raw = assert(f:read(compSize), "ZIP: truncated entry data")
				writeFile(toPath, name,
					method == 0 and raw or deflate.deflateDecompress(raw, uncompSize),
					mode)
			end
		end
	end)
	f:close()
	if not ok then error(err, 0) end
end

--- Extract an in-memory archive to disk, one entry at a time.
---@param data string
---@param toPath string
---@param strip boolean
local function extractStream(data, toPath, strip)
	if sniff(data) == "zip" then
		zipExtractString(data, toPath, strip)
	else
		tarExtractString(tarData(data), toPath, strip)
	end
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
---@field stream boolean? # Stream entries one at a time (default true)

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
--- Extraction streams by default: entries are decompressed and written one at
--- a time, keeping peak memory flat (~one file's worth) instead of decoding
--- every file into memory up front. Pass `opts.stream = false` to opt out
--- (decodes everything up front; only worth it for tiny archives).
---@param toPath string
---@param opts   Archive.ExtractOptions?
---@return boolean ok
---@return string? err
function Archive:extract(toPath, opts)
	if type(self._source) == "table" then
		return false, "extract() is only valid for file-backed archives"
	end

	local ok, err = pcall(function()
		local strip = opts and opts.stripComponents or false
		fs.mkdir(toPath)

		if opts and opts.stream == false then
			-- Opted out of streaming: decode everything into memory, then write.
			local entries, derr = self:_decode()
			if not entries then error(derr) end
			for name, entry in pairs(entries) do
				if strip then name = name:match("^[^/]*/(.+)") or name end
				if entry.dir then
					fs.mkdirAll(path.join(toPath, name))
				else
					writeFile(toPath, name, entry.content, entry.mode)
				end
			end
			return
		end

		-- Streaming fast path (default): decompress and write one entry at a time.
		if self._data then
			extractStream(self._data, toPath, strip)
		else
			local src = self._source
			if type(src) ~= "string" then
				error("archive is not backed by file data")
			end
			if sniffFile(src) == "zip" then
				zipExtractFile(src, toPath, strip)
			else
				local data = fs.read(src)
				if not data then error("cannot open: " .. src) end
				tarExtractString(tarData(data), toPath, strip)
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
