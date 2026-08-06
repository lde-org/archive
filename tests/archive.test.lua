local test = require("lde-test")
local Archive = require("archive")
local fs = require("fs")
local env = require("env")
local path = require("path")

local tmpBase = path.join(env.tmpdir(), "lde-archive-tests")
fs.rmdir(tmpBase)
fs.mkdir(tmpBase)

local function tmp(name)
	return path.join(tmpBase, name)
end

--
-- Archive.new
--

test.it("Archive.new with string returns Archive", function()
	local a = Archive.new("/some/path.tar.gz")
	test.truthy(a)
end)

test.it("Archive.new with table returns Archive", function()
	local a = Archive.new({ ["hello.txt"] = "hello" })
	test.truthy(a)
end)

test.it("extract fails when source is a table", function()
	local a = Archive.new({ ["hello.txt"] = "hello" })
	local ok, err = a:extract(tmp("out-table"))
	test.falsy(ok)
	test.truthy(err)
end)

test.it("save fails when source is a string", function()
	local a = Archive.new("/some/path.tar.gz")
	local ok, err = a:save(tmp("out.zip"))
	test.falsy(ok)
	test.truthy(err)
end)

test.it("save fails for unknown extension", function()
	local a = Archive.new({ ["hello.txt"] = "hello" })
	local ok, err = a:save(tmp("out.rar"))
	test.falsy(ok)
	test.truthy(err)
end)

test.it("save encodes to .zip and files are extractable", function()
	local zipPath = tmp("saved.zip")
	local outDir = tmp("out-saved-zip")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "zip content" })
	local ok = a:save(zipPath)
	test.truthy(ok)
	test.truthy(fs.exists(zipPath))

	local b = Archive.new(zipPath)
	local ok2 = b:extract(outDir)
	test.truthy(ok2)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "zip content")
end)

test.it("save encodes to .tar.gz and files are extractable", function()
	local tarPath = tmp("saved.tar.gz")
	local outDir = tmp("out-saved-tar")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "tar content" })
	local ok = a:save(tarPath)
	test.truthy(ok)
	test.truthy(fs.exists(tarPath))

	local b = Archive.new(tarPath)
	local ok2 = b:extract(outDir)
	test.truthy(ok2)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "tar content")
end)

test.it("extracts a .tar archive", function()
	local tarPath = tmp("test.tar")
	local outDir = tmp("out-tar")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "tar content" })
	local ok = a:save(tarPath)
	test.truthy(ok)

	local b = Archive.new(tarPath)
	local ok2 = b:extract(outDir)
	test.truthy(ok2)
	test.truthy(fs.exists(path.join(outDir, "hello.txt")))
end)

test.it("extracts a .zip archive", function()
	local zipPath = tmp("test2.zip")
	local outDir = tmp("out-zip2")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "zip content" })
	local ok = a:save(zipPath)
	test.truthy(ok)

	local b = Archive.new(zipPath)
	local ok2 = b:extract(outDir)
	test.truthy(ok2)
	test.truthy(fs.exists(path.join(outDir, "hello.txt")))
end)

test.it("stripComponents strips top-level dir from zip", function()
	local zipPath = tmp("strip.zip")
	local outDir = tmp("out-strip-zip")
	fs.mkdir(outDir)

	local a = Archive.new({ ["topdir/hello.txt"] = "stripped" })
	a:save(zipPath)

	local b = Archive.new(zipPath)
	b:extract(outDir, { stripComponents = true })
	test.equal(fs.read(path.join(outDir, "hello.txt")), "stripped")
end)

-- regression: zips with no explicit directory entries (e.g. .src.rock files)
-- must still extract deeply nested files by creating parent dirs recursively
test.it("extracts zip with deeply nested files and no explicit dir entries", function()
	local zipPath = tmp("nested.zip")
	local outDir  = tmp("out-nested")
	fs.mkdir(outDir)

	-- save creates file entries only, no dir entries — matches .src.rock behavior
	local a = Archive.new({ ["a/b/c/deep.lua"] = "deep content" })
	a:save(zipPath)

	local b = Archive.new(zipPath)
	local ok = b:extract(outDir)
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "a/b/c/deep.lua")), "deep content")
end)

test.it("stripComponents strips top-level dir from tar.gz", function()
	local tarPath = tmp("strip.tar.gz")
	local outDir = tmp("out-strip-tar")
	fs.mkdir(outDir)

	local a = Archive.new({ ["topdir/hello.txt"] = "stripped" })
	a:save(tarPath)

	local b = Archive.new(tarPath)
	b:extract(outDir, { stripComponents = true })
	test.equal(fs.read(path.join(outDir, "hello.txt")), "stripped")
end)

-- tar names longer than 100 chars must use the prefix field,
-- otherwise the name is truncated and extraction produces wrong results
test.it("tar roundtrip with filename longer than 100 characters", function()
	local tarPath = tmp("longname.tar")
	local outDir  = tmp("out-longname-tar")
	fs.mkdir(outDir)

	local longDir  = string.rep("a", 80)
	local fileName = string.rep("b", 30) .. ".txt"
	local fullPath = longDir .. "/" .. fileName -- > 100 chars
	test.truthy(#fullPath > 100)

	local a = Archive.new({ [fullPath] = "long tar content" })
	a:save(tarPath)

	local b = Archive.new(tarPath)
	local ok = b:extract(outDir)
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, fullPath)), "long tar content")
end)

test.it("tar.gz roundtrip with filename longer than 100 characters", function()
	local tarPath = tmp("longname.tar.gz")
	local outDir  = tmp("out-longname-targz")
	fs.mkdir(outDir)

	local longDir  = string.rep("a", 80)
	local fileName = string.rep("b", 30) .. ".txt"
	local fullPath = longDir .. "/" .. fileName -- > 100 chars
	test.truthy(#fullPath > 100)

	local a = Archive.new({ [fullPath] = "long tar.gz content" })
	a:save(tarPath)

	local b = Archive.new(tarPath)
	local ok = b:extract(outDir)
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, fullPath)), "long tar.gz content")
end)

-- regression: extract real tar.gz files created by system tar with names > 100 chars
-- verifies that the prefix field in ustar headers is correctly read and reassembled
test.it("extracts real tar.gz with filename longer than 100 characters", function()
	local tarPath = "tests/data/longname-real.tar.gz"
	local outDir  = tmp("out-real-targz")
	fs.mkdir(outDir)

	local longDir  = string.rep("a", 80)
	local fileName = string.rep("b", 30) .. ".txt"
	local fullPath = longDir .. "/" .. fileName

	local b        = Archive.new(tarPath)
	local ok       = b:extract(outDir)
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, fullPath)), "long path content from real tar\n")
	test.equal(fs.read(path.join(outDir, "short.txt")), "short content\n")
end)

test.it("extracts real .tar with filename longer than 100 characters", function()
	local tarPath = "tests/data/longname-real.tar"
	local outDir  = tmp("out-real-tar")
	fs.mkdir(outDir)

	local longDir  = string.rep("a", 80)
	local fileName = string.rep("b", 30) .. ".txt"
	local fullPath = longDir .. "/" .. fileName

	local b        = Archive.new(tarPath)
	local ok       = b:extract(outDir)
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, fullPath)), "long path content from real tar\n")
	test.equal(fs.read(path.join(outDir, "short.txt")), "short content\n")
end)

-- regression: a filename that exactly fills the 100-byte name field (no nul
-- terminator) must not bleed into the adjacent mode field in the tar header
test.it("tar roundtrip with exactly 100 character filename", function()
	local tarPath = tmp("exact100.tar")
	local outDir  = tmp("out-exact100")
	fs.mkdir(outDir)

	local dirName  = string.rep("d", 56)
	local baseName = string.rep("f", 39) .. ".txt"
	local fullPath = dirName .. "/" .. baseName -- exactly 100 chars
	test.equal(#fullPath, 100)

	local a = Archive.new({ [fullPath] = "exact 100 char name" })
	a:save(tarPath)

	local b = Archive.new(tarPath)
	local ok = b:extract(outDir)
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, fullPath)), "exact 100 char name")
end)

--
-- Regression: extraction must preserve POSIX exec bits. Real src rocks ship
-- executable scripts (e.g. cqueues' mk/luapath) in nested tar.gz/zips; losing
-- the mode breaks their makefiles. Fixtures: tests/data/mode-real.{tar.gz,zip}.
--

---@param p string
---@return number?  -- permission bits (lower 9), or nil if stat failed
local function perms(p)
	local stat = fs.stat(p)
	return stat and stat.mode and (stat.mode % 512) or nil
end

test.it("extracts real tar.gz and preserves exec bits", function()
	local outDir = tmp("out-mode-tar")
	fs.mkdir(outDir)

	local ok = Archive.new("tests/data/mode-real.tar.gz"):extract(outDir)
	test.truthy(ok)

	test.equal(perms(path.join(outDir, "tool.sh")), tonumber("755", 8))
	test.equal(perms(path.join(outDir, "readme.txt")), tonumber("644", 8))
	test.equal(perms(path.join(outDir, "run")), tonumber("700", 8))
end)

test.it("extracts real zip and preserves exec bits", function()
	local outDir = tmp("out-mode-zip")
	fs.mkdir(outDir)

	local ok = Archive.new("tests/data/mode-real.zip"):extract(outDir)
	test.truthy(ok)

	test.equal(perms(path.join(outDir, "tool.sh")), tonumber("755", 8))
	test.equal(perms(path.join(outDir, "readme.txt")), tonumber("644", 8))
	test.equal(perms(path.join(outDir, "run")), tonumber("700", 8))
end)

--
-- Raw content archives: Archive.new(bytes) instead of Archive.new(path).
-- Strings that start with a known archive magic are treated as contents, so
-- they are decoded from memory and never hit the filesystem.
--

test.it("reads files from raw zip bytes without touching the fs", function()
	local zipPath = tmp("raw-read.zip")
	Archive.new({ ["f.lua"] = "local x = 1\n", ["lib/util.lua"] = "return 2\n" }):save(zipPath)
	local raw = fs.read(zipPath)
	fs.delete(zipPath) -- if Archive.new treated the bytes as a path, read() would fail here

	local a = Archive.new(raw)
	test.equal(a:read("f.lua"), "local x = 1\n")
	test.equal(a:read("lib/util.lua"), "return 2\n")
	test.falsy(a:read("nope.lua"))
end)

test.it("extracts raw zip bytes to disk", function()
	local zipPath = tmp("raw-extract.zip")
	Archive.new({ ["hello.txt"] = "raw zip content" }):save(zipPath)
	local raw = fs.read(zipPath)
	fs.delete(zipPath)

	local outDir = tmp("out-raw-zip")
	fs.mkdir(outDir)
	local ok = Archive.new(raw):extract(outDir)
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "raw zip content")
end)

test.it("reads files from raw tar.gz bytes", function()
	local tarPath = tmp("raw-read.tar.gz")
	Archive.new({ ["f.lua"] = "local y = 2\n" }):save(tarPath)
	local raw = fs.read(tarPath)
	fs.delete(tarPath)

	test.equal(Archive.new(raw):read("f.lua"), "local y = 2\n")
end)

test.it("reads files from raw tar bytes", function()
	local tarPath = tmp("raw-read.tar")
	Archive.new({ ["f.lua"] = "tar content" }):save(tarPath)
	local raw = fs.read(tarPath)
	fs.delete(tarPath)

	test.equal(Archive.new(raw):read("f.lua"), "tar content")
end)

test.it("extracts raw tar.gz bytes to disk", function()
	local tarPath = tmp("raw-extract.tar.gz")
	Archive.new({ ["hello.txt"] = "raw tar content" }):save(tarPath)
	local raw = fs.read(tarPath)
	fs.delete(tarPath)

	local outDir = tmp("out-raw-tar")
	fs.mkdir(outDir)
	local ok = Archive.new(raw):extract(outDir)
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "raw tar content")
end)

test.it("handles raw empty zip contents", function()
	local zipPath = tmp("raw-empty.zip")
	Archive.new({}):save(zipPath)
	local raw = fs.read(zipPath)
	fs.delete(zipPath)
	test.equal(raw:sub(1, 2), "PK")

	local outDir = tmp("out-raw-empty")
	fs.mkdir(outDir)
	test.truthy(Archive.new(raw):extract(outDir))
	test.falsy(Archive.new(raw):read("x"))
end)

test.it("read() on a table-backed archive is a direct lookup", function()
	local a = Archive.new({ ["hello.txt"] = "hello" })
	test.equal(a:read("hello.txt"), "hello")
	test.falsy(a:read("missing.txt"))
end)

test.it("read() from a path-backed archive", function()
	local zipPath = tmp("path-read.zip")
	Archive.new({ ["f.lua"] = "from path" }):save(zipPath)
	test.equal(Archive.new(zipPath):read("f.lua"), "from path")
end)

test.it("save fails when constructed from raw content", function()
	local zipPath = tmp("raw-save.zip")
	Archive.new({ ["hello.txt"] = "hi" }):save(zipPath)
	local raw = fs.read(zipPath)
	local ok, err = Archive.new(raw):save(tmp("out.zip"))
	test.falsy(ok)
	test.truthy(err)
end)

--
-- Legacy extraction (opts.stream = false): the opt-out path decodes every
-- file into memory up front, then writes. Streaming is the default now, so
-- the tests above exercise the streaming path; these keep the legacy path
-- covered and the output must be identical.
--

test.it("extracts a .zip archive with stream = false", function()
	local zipPath = tmp("legacy.zip")
	local outDir = tmp("out-legacy-zip")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "legacy zip content" })
	local ok = a:save(zipPath)
	test.truthy(ok)

	local b = Archive.new(zipPath)
	local ok2 = b:extract(outDir, { stream = false })
	test.truthy(ok2)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "legacy zip content")
end)

test.it("extract honors an explicit stream = true", function()
	local zipPath = tmp("explicit-stream.zip")
	local outDir = tmp("out-explicit-stream")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "explicit stream content" })
	a:save(zipPath)

	local b = Archive.new(zipPath)
	local ok = b:extract(outDir, { stream = true })
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "explicit stream content")
end)

test.it("extracts zip with deeply nested files and no explicit dir entries with stream = false", function()
	local zipPath = tmp("legacy-nested.zip")
	local outDir  = tmp("out-legacy-nested")
	fs.mkdir(outDir)

	local a = Archive.new({ ["a/b/c/deep.lua"] = "deep legacy content" })
	a:save(zipPath)

	local b = Archive.new(zipPath)
	local ok = b:extract(outDir, { stream = false })
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "a/b/c/deep.lua")), "deep legacy content")
end)

test.it("strips top-level dir from zip with stream = false", function()
	local zipPath = tmp("legacy-strip.zip")
	local outDir = tmp("out-legacy-strip-zip")
	fs.mkdir(outDir)

	local a = Archive.new({ ["topdir/hello.txt"] = "stripped legacy" })
	a:save(zipPath)

	local b = Archive.new(zipPath)
	local ok = b:extract(outDir, { stream = false, stripComponents = true })
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "stripped legacy")
end)

test.it("extracts raw zip bytes to disk with stream = false", function()
	local zipPath = tmp("legacy-raw.zip")
	Archive.new({ ["hello.txt"] = "raw legacy content" }):save(zipPath)
	local raw = fs.read(zipPath)
	fs.delete(zipPath)

	local outDir = tmp("out-legacy-raw-zip")
	fs.mkdir(outDir)
	local ok = Archive.new(raw):extract(outDir, { stream = false })
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "raw legacy content")
end)

test.it("handles raw empty zip contents with stream = false", function()
	local zipPath = tmp("legacy-raw-empty.zip")
	Archive.new({}):save(zipPath)
	local raw = fs.read(zipPath)
	fs.delete(zipPath)

	local outDir = tmp("out-legacy-raw-empty")
	fs.mkdir(outDir)
	test.truthy(Archive.new(raw):extract(outDir, { stream = false }))
end)

test.it("extracts a .tar archive with stream = false", function()
	local tarPath = tmp("legacy.tar")
	local outDir = tmp("out-legacy-tar")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "legacy tar content" })
	local ok = a:save(tarPath)
	test.truthy(ok)

	local b = Archive.new(tarPath)
	local ok2 = b:extract(outDir, { stream = false })
	test.truthy(ok2)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "legacy tar content")
end)

test.it("extracts a .tar.gz archive with stream = false", function()
	local tarPath = tmp("legacy.tar.gz")
	local outDir = tmp("out-legacy-targz")
	fs.mkdir(outDir)

	local a = Archive.new({ ["hello.txt"] = "legacy targz content" })
	local ok = a:save(tarPath)
	test.truthy(ok)

	local b = Archive.new(tarPath)
	local ok2 = b:extract(outDir, { stream = false })
	test.truthy(ok2)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "legacy targz content")
end)

test.it("strips top-level dir from tar.gz with stream = false", function()
	local tarPath = tmp("legacy-strip.tar.gz")
	local outDir = tmp("out-legacy-strip-tar")
	fs.mkdir(outDir)

	local a = Archive.new({ ["topdir/hello.txt"] = "stripped legacy tar" })
	a:save(tarPath)

	local b = Archive.new(tarPath)
	local ok = b:extract(outDir, { stream = false, stripComponents = true })
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "stripped legacy tar")
end)

test.it("extracts raw tar.gz bytes with stream = false", function()
	local tarPath = tmp("legacy-raw.tar.gz")
	Archive.new({ ["hello.txt"] = "raw legacy tar content" }):save(tarPath)
	local raw = fs.read(tarPath)
	fs.delete(tarPath)

	local outDir = tmp("out-legacy-raw-tar")
	fs.mkdir(outDir)
	local ok = Archive.new(raw):extract(outDir, { stream = false })
	test.truthy(ok)
	test.equal(fs.read(path.join(outDir, "hello.txt")), "raw legacy tar content")
end)

test.it("preserves exec bits for real zip with stream = false", function()
	local outDir = tmp("out-legacy-mode-zip")
	fs.mkdir(outDir)

	local ok = Archive.new("tests/data/mode-real.zip"):extract(outDir, { stream = false })
	test.truthy(ok)

	test.equal(perms(path.join(outDir, "tool.sh")), tonumber("755", 8))
	test.equal(perms(path.join(outDir, "readme.txt")), tonumber("644", 8))
	test.equal(perms(path.join(outDir, "run")), tonumber("700", 8))
end)

test.it("preserves exec bits for real tar.gz with stream = false", function()
	local outDir = tmp("out-legacy-mode-tar")
	fs.mkdir(outDir)

	local ok = Archive.new("tests/data/mode-real.tar.gz"):extract(outDir, { stream = false })
	test.truthy(ok)

	test.equal(perms(path.join(outDir, "tool.sh")), tonumber("755", 8))
	test.equal(perms(path.join(outDir, "readme.txt")), tonumber("644", 8))
	test.equal(perms(path.join(outDir, "run")), tonumber("700", 8))
end)

-- regression: tar.gz whose payload compresses far past the old 10x size guess
-- (e.g. repeated text) must still extract — the gzip footer's ISIZE field
-- gives the exact uncompressed size
local function makeCompressible(payload)
	local block = string.rep("the quick brown fox jumps over the lazy dog. ", 64)
	local t = {}
	for _ = 1, math.ceil(payload / #block) do
		t[#t + 1] = block
	end
	return table.concat(t):sub(1, payload)
end

test.it("tar.gz roundtrip with highly compressible payload (streaming path)", function()
	local tarPath = tmp("big-compressible.tar.gz")
	local outDir  = tmp("out-big-compressible")
	fs.mkdir(outDir)

	local content = makeCompressible(2 * 1024 * 1024) -- 2 MiB, compresses ~200x
	test.truthy(#content > 1000000)

	local ok = Archive.new({ ["big.txt"] = content }):save(tarPath)
	test.truthy(ok)

	local b = Archive.new(tarPath)
	local ok2 = b:extract(outDir)
	test.truthy(ok2)
	test.equal(fs.read(path.join(outDir, "big.txt")), content)
end)

test.it("tar.gz roundtrip with highly compressible payload (legacy path)", function()
	local tarPath = tmp("big-compressible-legacy.tar.gz")
	local outDir  = tmp("out-big-compressible-legacy")
	fs.mkdir(outDir)

	local content = makeCompressible(2 * 1024 * 1024)

	local ok = Archive.new({ ["big.txt"] = content }):save(tarPath)
	test.truthy(ok)

	local b = Archive.new(tarPath)
	local ok2 = b:extract(outDir, { stream = false })
	test.truthy(ok2)
	test.equal(fs.read(path.join(outDir, "big.txt")), content)
end)
