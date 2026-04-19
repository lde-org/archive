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
