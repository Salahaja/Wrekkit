--[[ tga2png.lua - preview helper

The 1.12 client eats TGA but nothing else does, so this converts the
generated textures to PNG purely so they can be eyeballed outside the game.
Not shipped logic; no bearing on the addon at runtime.

    lua tools/tga2png.lua                (converts textures/*.tga)

PNGs are written with stored (uncompressed) deflate blocks, which needs no
zlib -- the files are chunky but they are throwaway previews.
]]

local band, rshift
if bit32 then
  band, rshift = bit32.band, bit32.rshift
else
  band = function(a, b)
    local r, m = 0, 1
    while m <= a and m <= b do
      if a % (m + m) >= m and b % (m + m) >= m then r = r + m end
      m = m + m
    end
    return r
  end
  rshift = function(a, n) return math.floor(a / 2 ^ n) end
end

----------------------------------------------------------------------
-- checksums
----------------------------------------------------------------------

local crc_table
local function crc32(s, crc)
  if not crc_table then
    crc_table = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if c % 2 == 1 then
          c = 0xEDB88320 ~ math.floor(c / 2)
        else
          c = math.floor(c / 2)
        end
      end
      crc_table[i] = c
    end
  end
  crc = crc or 0xFFFFFFFF
  for i = 1, #s do
    local b = s:byte(i)
    crc = crc_table[(crc ~ b) & 0xFF] ~ (crc >> 8)
  end
  return crc
end

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

local function be32(n)
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256)
end

local function chunk(tag, data)
  local body = tag .. data
  return be32(#data) .. body .. be32(crc32(body) ~ 0xFFFFFFFF)
end

----------------------------------------------------------------------
-- TGA in
----------------------------------------------------------------------

local function read_tga(path)
  local f = assert(io.open(path, "rb"))
  local raw = f:read("a")
  f:close()

  local idLen = raw:byte(1)
  local imgType = raw:byte(3)
  assert(imgType == 2, path .. ": expected uncompressed true-colour (type 2)")
  local w = raw:byte(13) + raw:byte(14) * 256
  local h = raw:byte(15) + raw:byte(16) * 256
  local depth = raw:byte(17)
  assert(depth == 32, path .. ": expected 32bpp")
  local topDown = band(raw:byte(18), 0x20) ~= 0

  local px = {}
  local off = 18 + idLen
  for y = 0, h - 1 do
    local srcY = topDown and y or (h - 1 - y)
    local row = {}
    for x = 0, w - 1 do
      local i = off + (srcY * w + x) * 4
      local b, g, r, a = raw:byte(i + 1), raw:byte(i + 2), raw:byte(i + 3), raw:byte(i + 4)
      -- Most of these textures are white-on-transparent, meant to be tinted
      -- at runtime against a dark panel. Previewed with real alpha they read
      -- as a blank square, so composite over the addon's own panel colour --
      -- that is what they will actually look like in game.
      local bg = 22
      local k = a / 255
      r = math.floor(r * k + bg * (1 - k) + 0.5)
      g = math.floor(g * k + bg * (1 - k) + 0.5)
      b = math.floor(b * k + bg * (1 - k) + 0.5)
      row[x + 1] = string.char(r, g, b, 255)
    end
    px[y + 1] = table.concat(row)
  end
  return w, h, px
end

----------------------------------------------------------------------
-- PNG out
----------------------------------------------------------------------

local function write_png(path, w, h, rows)
  -- filter byte 0 (None) in front of every scanline
  local scan = {}
  for y = 1, h do scan[y] = "\0" .. rows[y] end
  local rawData = table.concat(scan)

  -- zlib stream using stored deflate blocks (max 65535 bytes each)
  local blocks = { "\120\001" } -- CMF/FLG for deflate, no preset dict
  local pos = 1
  while pos <= #rawData do
    local n = math.min(65535, #rawData - pos + 1)
    local final = (pos + n > #rawData) and 1 or 0
    blocks[#blocks + 1] = string.char(final)
        .. string.char(n % 256, math.floor(n / 256))
        .. string.char((255 - n % 256), (255 - math.floor(n / 256)))
        .. rawData:sub(pos, pos + n - 1)
    pos = pos + n
  end
  blocks[#blocks + 1] = be32(adler32(rawData))

  local ihdr = be32(w) .. be32(h) .. string.char(8, 6, 0, 0, 0) -- 8-bit RGBA
  local png = "\137PNG\r\n\26\n"
      .. chunk("IHDR", ihdr)
      .. chunk("IDAT", table.concat(blocks))
      .. chunk("IEND", "")

  local f = assert(io.open(path, "wb"))
  f:write(png)
  f:close()
end

----------------------------------------------------------------------

local outDir = ... or "tools/preview/"
os.execute('mkdir "' .. outDir:gsub("/", "\\") .. '" 2>nul')

local names = {
  "white", "bar-fill", "chart-area", "panel-bg", "corner",
  "glow", "header-sheen", "emblem", "minimap", "frame-border",
  "globe", "reset", "group", "lock", "cog",
}

for _, n in ipairs(names) do
  local src = "textures/" .. n .. ".tga"
  local fh = io.open(src, "rb")
  if fh then
    fh:close()
    local w, h, rows = read_tga(src)
    write_png(outDir .. n .. ".png", w, h, rows)
    print(string.format("  %-18s -> %s.png (%dx%d)", n .. ".tga", n, w, h))
  end
end
print("previews written to " .. outDir)
