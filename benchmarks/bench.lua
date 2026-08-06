-- Benchmarks the archive library's two extraction paths — streaming (the
-- default: decompress and write one entry at a time) vs legacy (`stream = false`:
-- decode everything into memory, then write).
--
-- Each mode runs in its own child process; the parent samples the child's
-- peak RSS while it runs (VmHWM on Linux, `ps`/PowerShell elsewhere), so the
-- peak is attributable to that mode alone. Per-run CPU time is reported by
-- the child (see extract-child.lua).
--
-- Usage: lde run benchmarks/bench.lua

local Archive = require("archive")
local fs = require("fs")
local path = require("path")
local env = require("env")
local process = require("process")
local ffi = require("ffi")

local RUNS   = 10
local WARMUP = 2

local tmpBase = path.join(env.tmpdir(), "lde-archive-bench")
fs.rmdir(tmpBase)
fs.mkdirAll(tmpBase)

-- Deterministic fixture: 10 files x 1 MiB of pseudo-random text, matching the
-- "~10 files per install" scenario that motivated the streaming path.
math.randomseed(12345)
local function randomBlock(bytes)
	local t = {}
	for i = 1, bytes do
		t[i] = string.char(math.random(97, 122)) -- a-z
	end
	return table.concat(t)
end

local files = {}
for i = 1, 10 do
	math.randomseed(12345 + i)
	local block = randomBlock(4096)
	files[("pkg/file%02d.txt"):format(i)] = string.rep(block, 256)
end

local zipPath = path.join(tmpBase, "fixture.zip")
local tarPath = path.join(tmpBase, "fixture.tar.gz")
Archive.new(files):save(zipPath)
Archive.new(files):save(tarPath)

-- Short sleep for the RSS sampling loop.
local sleep
if ffi.os == "Windows" then
	pcall(ffi.cdef, "void Sleep(unsigned long ms);")
	sleep = function(ms) ffi.C.Sleep(ms) end
else
	pcall(ffi.cdef, "int usleep(unsigned int usec);")
	sleep = function(ms) ffi.C.usleep(ms * 1000) end
end

-- How often to sample the child's RSS. /proc reads on Linux are cheap, so 1ms
-- sampling is fine; macOS and Windows sample via a subprocess, hence longer waits.
---@type integer
local sampleIntervalMs = ffi.os == "Linux" and 1 or (ffi.os == "OSX" and 50 or 250)

-- Sample the peak RSS of a live process so far, in bytes.
---@param pid number
---@return number? # nil when the process is gone or the value can't be read
local function readPeakRSS(pid)
	if ffi.os == "Linux" then
		-- VmHWM is the peak resident set size (high-water mark), in kB.
		local f = io.open("/proc/" .. pid .. "/status")
		if not f then return nil end
		local status = f:read("*a")
		f:close()
		local kb = status:match("VmHWM:%s*(%d+) kB")
		return kb and tonumber(kb) * 1024 or nil
	elseif ffi.os == "OSX" then
		local code, out = process.exec("ps", { "-o", "rss=", "-p", tostring(pid) })
		local kb = code == 0 and out and out:match("(%d+)")
		return kb and tonumber(kb) * 1024 or nil
	else
		-- Windows: PeakWorkingSet64 is the peak working set so far, in bytes.
		local code, out = process.exec("powershell", { "-NoProfile", "-Command",
			"(Get-Process -Id " .. pid .. " -ErrorAction SilentlyContinue).PeakWorkingSet64" })
		local bytes = code == 0 and out and out:match("(%d+)")
		return bytes and tonumber(bytes) or nil
	end
end

---@param values number[]
---@return number
local function median(values)
	local sorted = {}
	for _, v in ipairs(values) do sorted[#sorted + 1] = v end
	table.sort(sorted)
	local mid = math.floor(#sorted / 2)
	if #sorted % 2 == 1 then return sorted[mid + 1] end
	return (sorted[mid] + sorted[mid + 1]) / 2
end

---@param n number
---@return string
local function formatBytes(n)
	if n >= 1024 * 1024 then return string.format("%.1f MiB", n / 1024 / 1024) end
	if n >= 1024 then return string.format("%.1f KiB", n / 1024) end
	return tostring(n) .. " B"
end

---@param mode string
---@param archivePath string
---@param outLabel string
---@return number[] times, number? peak
local function runChild(mode, archivePath, outLabel)
	local outBase  = path.join(tmpBase, "out-" .. outLabel)
	local childScript = path.join(env.cwd(), "benchmarks", "extract-child.lua")
	local child, err = process.spawn(env.execPath(), {
		"run", childScript, mode, archivePath, outBase, tostring(RUNS),
	}, { stdout = "pipe", stderr = "pipe" })
	if not child then
		error("failed to spawn benchmark child: " .. tostring(err))
	end

	-- Sample RSS until the child exits. VmHWM / PeakWorkingSet64 are
	-- high-water marks, so the max over samples is the true peak.
	local peak, code = 0, nil
	while true do
		local rss = readPeakRSS(child.pid)
		if rss and rss > peak then peak = rss end
		code = child:poll()
		if code ~= nil then break end
		sleep(sampleIntervalMs)
	end

	local _, stdout, stderr = child:wait()
	if code ~= 0 then
		error(string.format("benchmark child (%s %s) failed with exit %s: %s",
			outLabel, mode, tostring(code), stderr or ""))
	end

	local times = {}
	for line in stdout:gmatch("[^\n]+") do
		local i, t = line:match("^RUN (%d+) (%d+%.%d+)$")
		if i then times[#times + 1] = tonumber(t) end
	end
	if #times ~= RUNS then
		error(string.format("benchmark child (%s %s) produced %d runs, expected %d",
			outLabel, mode, #times, RUNS))
	end
	return times, peak > 0 and peak or nil
end

---@param label string
---@param archivePath string
local function benchFormat(label, archivePath)
	local results = {}
	for _, mode in ipairs({ "stream", "legacy" }) do
		local times, peak = runChild(mode, archivePath, label .. "-" .. mode)
		results[mode] = { time = median(times), peak = peak }
	end

	print()
	print("=== " .. label .. " ===")
	print(string.format("%-14s %12s %14s", "mode", "time", "peak RSS"))
	for _, mode in ipairs({ "stream", "legacy" }) do
		local r = results[mode]
		print(string.format("%-14s %9.1f ms %14s",
			mode == "stream" and "stream (default)" or "legacy",
			r.time * 1000,
			r.peak and formatBytes(r.peak) or "n/a"))
	end

	local str, legacy = results.stream, results.legacy
	if str.peak and legacy.peak then
		local saved = legacy.peak - str.peak
		local pct = saved > 0 and math.floor(saved / legacy.peak * 100 + 0.5) or 0
		if pct > 0 then
			print(string.format("stream vs legacy: peak RSS -%d%% (%s)", pct, formatBytes(saved)))
		else
			print("stream vs legacy: peak RSS no measurable change")
		end
	else
		print("(peak RSS unavailable on this platform)")
	end
end

local zipStat = fs.stat(zipPath)
local tarStat = fs.stat(tarPath)

---@param s fs.Stat?
---@return number
local function statSize(s)
	return s and tonumber(s.size) or 0
end

print("=== archive extraction benchmark ===")
print(string.format("fixture: 10 files x 1 MiB — zip %s, tar.gz %s — %d runs, %d warmup",
	formatBytes(statSize(zipStat)),
	formatBytes(statSize(tarStat)),
	RUNS, WARMUP))

benchFormat("zip", zipPath)
benchFormat("tar.gz", tarPath)

fs.rmdir(tmpBase)
