-- Child process for benchmarks/bench.lua. Extracts the given archive with the
-- given mode ("default" | "stream") for `runs` iterations, printing one
-- machine-readable line per run with the CPU time (os.clock). The parent
-- samples this process's RSS while it runs, so the peak is attributable to
-- this mode alone.
--
-- Usage: lde run benchmarks/extract-child.lua <mode> <archive> <outBase> <runs>

local Archive = require("archive")
local fs = require("fs")
local path = require("path")

local mode    = arg[1] -- "stream" (default) | "legacy" (opts.stream = false)
local archive = arg[2]
local outBase = arg[3]
local runs    = tonumber(arg[4])

fs.rmdir(outBase)
fs.mkdirAll(outBase)

local function extract(outDir)
	local opts = mode == "legacy" and { stream = false } or nil
	local ok, err = Archive.new(archive):extract(outDir, opts)
	if not ok then
		print("ERROR " .. tostring(err))
		os.exit(1)
	end
end

-- Warmup: let the JIT compile the hot paths before timing.
for _ = 1, 2 do
	extract(path.join(outBase, "warmup"))
end

for i = 1, runs do
	local outDir = path.join(outBase, "run" .. i)
	fs.rmdir(outDir)

	local t0 = os.clock()
	extract(outDir)
	local t1 = os.clock()

	print(string.format("RUN %d %.6f", i, t1 - t0))
end
