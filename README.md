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
