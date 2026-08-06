# archive

This is a cross platform library to create, modify and extract archive files.

## Usage

```
lde add archive --git https://github.com/lde-org/archive
```

## Examples

**Extract a ZIP or TAR archive:**

```lua
local Archive = require("archive")

local ok, err = Archive.new("path/to/file.zip"):extract("output/dir")
if not ok then error(err) end

-- Strip the top-level directory (e.g. "repo-main/src" → "src")
Archive.new("file.tar.gz"):extract("output/dir", { stripComponents = true })
```

**Extraction streams by default (lower peak memory):**

`extract()` decompresses and writes entries one at a time, so peak memory
stays flat (~one file's worth) instead of decoding every file into memory
up front. For zip files this is also a true streaming read: the central
directory is read first, then each entry is seeked to, decompressed, and
written before moving on. Tar/tar.gz archives stream the same way, though
the gzip stream itself is still decompressed in one shot.

Pass `{ stream = false }` to opt out and decode everything into memory up
front — only worth it for tiny archives:

```lua
Archive.new("tiny.zip"):extract("output/dir", { stream = false })
```

**Open an archive from raw contents (no file needed):**

```lua
local Archive = require("archive")

local raw = http.fetch(url) -- or fs.read("file.zip") — any raw bytes
local zip = Archive.new(raw) -- strings with a known magic are treated as contents

-- Read a file straight from memory, without extracting to disk
local init = zip:read("src/init.lua")
```

`Archive.new` treats a string as raw archive contents when it starts with a
known archive magic (zip `PK..`, gzip, or tar `ustar`); anything else is
treated as a file path. `read()` works for raw contents, paths, and
table-backed archives alike, returning `nil` when the entry does not exist.

**Create and save an archive:**

```lua
local Archive = require("archive")

local files = {
  ["hello.txt"]     = "Hello, world!",
  ["src/init.lua"]  = "return {}",
}

-- Format is inferred from the extension: .zip, .tar, or .tar.gz
local ok, err = Archive.new(files):save("output.zip")
if not ok then error(err) end

Archive.new(files):save("output.tar.gz")
```

## Benchmarks

A benchmark harness comparing the streaming (default) and legacy
(`stream = false`) extraction paths lives in `benchmarks/`. Each mode runs
in its own child process so peak RSS is attributable to that mode alone
(VmHWM on Linux, sampled via `ps`/PowerShell elsewhere); per-run CPU time
is measured in-process.

```
lde run benchmarks/bench.lua
```

Output on Linux (10 files × 1 MiB fixture):

```
=== zip ===
mode              time       peak RSS
stream (default) 7.6 ms       12.0 MiB
legacy           9.4 ms       32.7 MiB
stream vs legacy: peak RSS -63% (20.7 MiB)
```
