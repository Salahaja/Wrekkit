--[[ make_textures.lua - procedural art generator for ChronicleInGame

Runs on DESKTOP Lua 5.4 (not in the game). Emits uncompressed 32-bit BGRA
top-down TGA files into ../textures/ -- the only raster format the 1.12
client reliably loads from an addon folder. Every image is power-of-two.

    lua tools/make_textures.lua          (run from the addon root)

Shapes are supersampled 4x4 for anti-aliasing. Most textures are authored
white/greyscale so the addon can tint them at runtime with SetVertexColor;
that keeps one texture serving every class colour and accent.
]]

local SS = 4 -- supersample factor per axis

----------------------------------------------------------------------
-- TGA writer
----------------------------------------------------------------------

-- shade(x, y, w, h) -> r, g, b, a   each 0..1
local function write_tga(path, w, h, shade)
  local out = {}
  local n = 0

  local function put(s) n = n + 1; out[n] = s end

  -- 18-byte header: no ID, no colour map, type 2 (uncompressed true-colour),
  -- 32bpp, descriptor 0x28 = 8 alpha bits + top-left origin.
  put(string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  put(string.char(w % 256, math.floor(w / 256), h % 256, math.floor(h / 256)))
  put(string.char(32, 0x28))

  local inv = 1 / (SS * SS)
  for y = 0, h - 1 do
    local row = {}
    for x = 0, w - 1 do
      -- supersample the shader over a SSxSS grid inside this pixel
      local r, g, b, a = 0, 0, 0, 0
      for sy = 0, SS - 1 do
        for sx = 0, SS - 1 do
          local px = x + (sx + 0.5) / SS
          local py = y + (sy + 0.5) / SS
          local sr, sg, sb, sa = shade(px, py, w, h)
          sa = sa or 1
          -- premultiply so partial coverage darkens rather than fringes
          r = r + (sr or 0) * sa
          g = g + (sg or 0) * sa
          b = b + (sb or 0) * sa
          a = a + sa
        end
      end
      a = a * inv
      if a > 0.0001 then
        -- un-premultiply back to straight alpha for the client
        local k = inv / a
        r, g, b = r * k, g * k, b * k
      else
        r, g, b = 0, 0, 0
      end

      local function byte(v)
        v = math.floor(v * 255 + 0.5)
        if v < 0 then v = 0 elseif v > 255 then v = 255 end
        return v
      end
      row[x + 1] = string.char(byte(b), byte(g), byte(r), byte(a)) -- BGRA
    end
    put(table.concat(row))
  end

  local f = assert(io.open(path, "wb"))
  f:write(table.concat(out))
  f:close()
  print(string.format("  %-28s %dx%d", path:match("[^/\\]+$"), w, h))
end

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function smoothstep(edge0, edge1, x)
  local t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
  return t * t * (3 - 2 * t)
end

-- signed distance to a rounded rectangle centred in a w*h box
local function sd_round_rect(px, py, w, h, inset, radius)
  local cx, cy = w * 0.5, h * 0.5
  local hx, hy = cx - inset - radius, cy - inset - radius
  local dx = math.abs(px - cx) - hx
  local dy = math.abs(py - cy) - hy
  local ax, ay = math.max(dx, 0), math.max(dy, 0)
  return math.sqrt(ax * ax + ay * ay) + math.min(math.max(dx, dy), 0) - radius
end

-- Chronicle palette (linear 0..1)
local AMBER = { 0.878, 0.635, 0.173 }
local AMBER_HI = { 1.000, 0.816, 0.400 }

----------------------------------------------------------------------
-- textures
----------------------------------------------------------------------

local OUT = "textures/"

local gen = {}

-- Flat white. The workhorse: every solid fill, divider, and grid line is
-- this tinted at runtime. Sampling a real texture beats SetTexture(r,g,b,a)
-- because the same object can then cross-fade and take vertex gradients.
gen["white"] = function()
  write_tga(OUT .. "white.tga", 8, 8, function() return 1, 1, 1, 1 end)
end

-- Horizontal rank-bar fill: bright along the top third, falling off toward
-- the bottom, so a flat coloured bar reads as lit rather than printed.
gen["bar-fill"] = function()
  write_tga(OUT .. "bar-fill.tga", 64, 32, function(x, y, w, h)
    local t = y / h
    local sheen = 1.06 - 0.42 * smoothstep(0.0, 0.85, t)
    -- 1px darker seat along the very bottom edge
    if t > 0.94 then sheen = sheen * 0.78 end
    return sheen, sheen, sheen, 1
  end)
end

-- Vertical fade used for the area under the timeline chart: opaque at the
-- top of the column, fading out toward the baseline.
gen["chart-area"] = function()
  write_tga(OUT .. "chart-area.tga", 8, 64, function(x, y, w, h)
    local t = y / (h - 1)
    local a = 0.62 * (1 - t) * (1 - t) + 0.06
    return 1, 1, 1, a
  end)
end

-- Card background: near-black with a faint top-down lift, plus an ordered
-- dither so large flat panels don't band on the 16-bit output some players
-- still run.
gen["panel-bg"] = function()
  local bayer = {
    { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 },
  }
  write_tga(OUT .. "panel-bg.tga", 128, 128, function(x, y, w, h)
    local t = y / h
    local v = 0.098 - 0.026 * smoothstep(0, 1, t)
    local bx = math.floor(x) % 4 + 1
    local by = math.floor(y) % 4 + 1
    v = v + (bayer[by][bx] / 16 - 0.5) * (1.6 / 255)
    return v, v * 1.02, v * 1.09, 1
  end)
end

-- Anti-aliased rounded corner mask. Drawn once as a top-left corner; the
-- addon flips it with SetTexCoord for the other three.
gen["corner"] = function()
  local R = 16
  write_tga(OUT .. "corner.tga", R, R, function(x, y)
    local dx, dy = R - x, R - y
    local d = math.sqrt(dx * dx + dy * dy)
    local a = 1 - smoothstep(R - 1.25, R + 0.25, d)
    return 1, 1, 1, a
  end)
end

-- Soft radial glow for selection states and the chart's death markers.
gen["glow"] = function()
  write_tga(OUT .. "glow.tga", 64, 64, function(x, y, w, h)
    local dx = (x - w * 0.5) / (w * 0.5)
    local dy = (y - h * 0.5) / (h * 0.5)
    local d = math.sqrt(dx * dx + dy * dy)
    local a = 1 - smoothstep(0, 1, d)
    return 1, 1, 1, a * a * 0.9
  end)
end

-- Title-bar sheen: a wide amber-tinted highlight that fades to nothing at
-- both ends, laid over the window header.
gen["header-sheen"] = function()
  write_tga(OUT .. "header-sheen.tga", 256, 32, function(x, y, w, h)
    local tx = x / w
    local ty = y / h
    local across = math.sin(tx * math.pi) ^ 1.5
    local down = 1 - smoothstep(0.1, 1.0, ty)
    local a = across * down * 0.5
    return AMBER[1], AMBER[2], AMBER[3], a
  end)
end

-- Emblem: an amber ring with a rising line-chart glyph inside it. Used for
-- the minimap button and the window's title mark.
local function emblem(px, py, w, h, ringWidth)
  local cx, cy = w * 0.5, h * 0.5
  local R = w * 0.42
  local d = math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)

  -- ring
  local ring = smoothstep(R - ringWidth - 1, R - ringWidth, d)
      * (1 - smoothstep(R - 1, R, d))

  -- interior disc, very dark so the glyph reads
  local disc = 1 - smoothstep(R - ringWidth - 1, R - ringWidth, d)

  -- polyline glyph: four segments climbing left-to-right
  local pts = {
    { 0.24, 0.68 }, { 0.42, 0.52 }, { 0.56, 0.60 }, { 0.78, 0.32 },
  }
  local line = 0
  local halfW = w * 0.036
  for i = 1, #pts - 1 do
    local ax, ay = pts[i][1] * w, pts[i][2] * h
    local bx, by = pts[i + 1][1] * w, pts[i + 1][2] * h
    local vx, vy = bx - ax, by - ay
    local len2 = vx * vx + vy * vy
    local t = clamp(((px - ax) * vx + (py - ay) * vy) / len2, 0, 1)
    local qx, qy = ax + vx * t, ay + vy * t
    local dist = math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
    line = math.max(line, 1 - smoothstep(halfW - 0.6, halfW + 0.6, dist))
  end

  local a = math.max(ring, disc * 0.92)
  local r, g, b
  if line > 0.01 and disc > 0.5 then
    -- glyph sits on top of the dark disc
    r = AMBER_HI[1] * line + 0.07 * (1 - line)
    g = AMBER_HI[2] * line + 0.07 * (1 - line)
    b = AMBER_HI[3] * line + 0.08 * (1 - line)
  elseif ring > 0.01 then
    r, g, b = AMBER[1], AMBER[2], AMBER[3]
  else
    r, g, b = 0.07, 0.07, 0.08
  end
  return r, g, b, a
end

gen["emblem"] = function()
  write_tga(OUT .. "emblem.tga", 64, 64, function(x, y, w, h)
    return emblem(x, y, w, h, w * 0.10)
  end)
end

-- Minimap button face. Slightly heavier ring so it survives being drawn at
-- ~20px next to the other minimap clutter.
gen["minimap"] = function()
  write_tga(OUT .. "minimap.tga", 64, 64, function(x, y, w, h)
    return emblem(x, y, w, h, w * 0.13)
  end)
end

-- Globe: the open-world recording toggle. Authored white so one texture can
-- be shown lit (amber) or dimmed, rather than shipping two states.
gen["globe"] = function()
  write_tga(OUT .. "globe.tga", 32, 32, function(x, y, w, h)
    local cx, cy = w * 0.5, h * 0.5
    local R = w * 0.40
    local half = w * 0.030          -- half stroke width
    local dx, dy = x - cx, y - cy
    local dist = math.sqrt(dx * dx + dy * dy)

    local function stroke(d)
      return 1 - smoothstep(half - 0.5, half + 0.5, math.abs(d))
    end

    -- Outer ring.
    local a = stroke(dist - R)

    -- Everything else is clipped to the disc.
    local inside = 1 - smoothstep(R - 0.5, R + 0.5, dist)
    if inside > 0.01 then
      -- Equator and two latitudes.
      a = math.max(a, stroke(dy) * inside)
      a = math.max(a, stroke(math.abs(dy) - R * 0.50) * inside)

      -- Meridians: the vertical one, plus an ellipse either side. For a
      -- given row the ellipse sits at x = cx +/- a*sqrt(1 - (dy/R)^2), so
      -- the horizontal distance to it is exact rather than approximated.
      a = math.max(a, stroke(dx) * inside)

      local t = 1 - (dy / R) * (dy / R)
      if t > 0 then
        local half_w = R * 0.52 * math.sqrt(t)
        a = math.max(a, stroke(math.abs(dx) - half_w) * inside)
      end
    end

    return 1, 1, 1, a
  end)
end

-- Reset: a circular arrow. An arc with a gap, plus a triangular head on the
-- tangent at the gap edge so the direction of travel reads at 14px.
gen["reset"] = function()
  local function inTriangle(px, py, ax, ay, bx, by, cx2, cy2)
    local function side(x1, y1, x2, y2)
      return (px - x2) * (y1 - y2) - (x1 - x2) * (py - y2)
    end
    local d1 = side(ax, ay, bx, by)
    local d2 = side(bx, by, cx2, cy2)
    local d3 = side(cx2, cy2, ax, ay)
    local hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    local hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (hasNeg and hasPos)
  end

  write_tga(OUT .. "reset.tga", 32, 32, function(x, y, w, h)
    local cx, cy = w * 0.5, h * 0.5
    local R = w * 0.34
    local half = w * 0.055
    local dx, dy = x - cx, y - cy
    local dist = math.sqrt(dx * dx + dy * dy)

    -- Arc, with a wedge removed in the upper right.
    local a = 1 - smoothstep(half - 0.5, half + 0.5, math.abs(dist - R))
    local ang = math.deg(math.atan(dy, dx))
    if ang < 0 then ang = ang + 360 end
    if ang > 275 or ang < 20 then a = 0 end

    -- Arrowhead riding the tangent where the arc stops.
    local hd = math.rad(18)
    local px = cx + math.cos(hd) * R
    local py = cy + math.sin(hd) * R
    local tx, ty = -math.sin(hd), math.cos(hd)      -- tangent
    local nx, ny = math.cos(hd), math.sin(hd)       -- outward normal
    local len, wid = w * 0.20, w * 0.13

    local tipx, tipy = px + tx * len, py + ty * len
    local b1x, b1y = px + nx * wid, py + ny * wid
    local b2x, b2y = px - nx * wid, py - ny * wid
    if inTriangle(x, y, tipx, tipy, b1x, b1y, b2x, b2y) then a = 1 end

    return 1, 1, 1, a
  end)
end

-- Group: the "ignore people outside your party/raid" toggle. Two filled
-- figures, the rear one notched by a dilated copy of the front so they read
-- as two people rather than one blob at 14px.
gen["group"] = function()
  write_tga(OUT .. "group.tga", 32, 32, function(x, y, w, h)
    local function figure(cx, headY, r, bodyY, rx, ry, bottom, pad)
      local dh = math.sqrt((x - cx) ^ 2 + (y - headY) ^ 2)
      local head = 1 - smoothstep(r + pad - 0.5, r + pad + 0.5, dh)

      local ex = (x - cx) / (rx + pad)
      local ey = (y - bodyY) / (ry + pad)
      local de = math.sqrt(ex * ex + ey * ey)
      local body = (1 - smoothstep(0.96, 1.04, de))
          * (1 - smoothstep(bottom - 0.5, bottom + 0.5, y))

      return math.max(head, body)
    end

    local back = figure(w * 0.645, h * 0.325, w * 0.100, h * 0.70, w * 0.150, h * 0.23, h * 0.78, 0)
    local front = figure(w * 0.400, h * 0.375, w * 0.125, h * 0.78, w * 0.185, h * 0.26, h * 0.86, 0)
    local cut = figure(w * 0.400, h * 0.375, w * 0.125, h * 0.78, w * 0.185, h * 0.26, h * 0.86, 1.5)

    return 1, 1, 1, math.max(back * (1 - cut), front)
  end)
end

-- Padlock: marks an encounter as kept, so pruning skips it. Filled body with
-- a stroked shackle -- at 12px a hollow body loses to the row behind it.
gen["lock"] = function()
  write_tga(OUT .. "lock.tga", 32, 32, function(x, y, w, h)
    local cx = w * 0.5
    local shackleY = h * 0.44

    -- Body: rounded rectangle across the lower half.
    local bodyTop, bodyBottom = h * 0.44, h * 0.84
    local bodyHalfW = w * 0.26
    local bodyHalfH = (bodyBottom - bodyTop) * 0.5
    local bodyCY = (bodyTop + bodyBottom) * 0.5
    local dx = math.abs(x - cx) - (bodyHalfW - 3)
    local dy = math.abs(y - bodyCY) - (bodyHalfH - 3)
    local ax, ay = math.max(dx, 0), math.max(dy, 0)
    local d = math.sqrt(ax * ax + ay * ay) + math.min(math.max(dx, dy), 0) - 3
    local body = 1 - smoothstep(-0.5, 0.5, d)

    -- Shackle: the upper half of a ring sitting on top of the body.
    local sr = w * 0.155
    local half = w * 0.055
    local sd = math.sqrt((x - cx) ^ 2 + (y - shackleY) ^ 2)
    local shackle = 1 - smoothstep(half - 0.5, half + 0.5, math.abs(sd - sr))
    if y > shackleY then shackle = 0 end

    -- Keyhole punched out of the body.
    local kd = math.sqrt((x - cx) ^ 2 + (y - (bodyCY - h * 0.02)) ^ 2)
    local hole = 1 - smoothstep(w * 0.045, w * 0.045 + 1, kd)
    local slitX = 1 - smoothstep(w * 0.028, w * 0.028 + 1, math.abs(x - cx))
    local slitY = (y > bodyCY) and (1 - smoothstep(bodyBottom - h * 0.12,
      bodyBottom - h * 0.12 + 1, y)) or 0
    hole = math.max(hole, slitX * slitY)

    return 1, 1, 1, math.max(body * (1 - hole), shackle)
  end)
end

-- Cog: opens settings. Teeth are a radial modulation of the outer radius
-- rather than drawn shapes, which keeps them evenly spaced at any count and
-- anti-aliases for free along with the rest of the edge.
gen["cog"] = function()
  local TEETH = 8
  write_tga(OUT .. "cog.tga", 32, 32, function(x, y, w, h)
    local cx, cy = w * 0.5, h * 0.5
    local dx, dy = x - cx, y - cy
    local dist = math.sqrt(dx * dx + dy * dy)
    local ang = math.atan(dy, dx)

    local base = w * 0.30          -- body radius
    local tooth = w * 0.085        -- how far the teeth stand proud
    local hole = w * 0.125         -- the hub

    -- Square-ish wave, softened so the tooth flanks are not jagged.
    local k = smoothstep(-0.30, 0.30, math.cos(ang * TEETH))
    local outer = base + tooth * k

    local a = (1 - smoothstep(outer - 0.6, outer + 0.6, dist))
        * smoothstep(hole - 0.6, hole + 0.6, dist)

    return 1, 1, 1, a
  end)
end

-- Five-point star: "picked", the players someone chose to follow. Coverage
-- is an exact inside test; write_tga's 4x4 supersampling does the edges.
gen["pick"] = function()
  local vx, vy = {}, {}
  write_tga(OUT .. "pick.tga", 32, 32, function(x, y, w, h)
    if not vx[1] then
      -- Outer and inner radii alternate; the first vertex points straight
      -- up, and the centre sits a touch low so the star looks centred.
      local cx, cy = w * 0.5, h * 0.54
      local outer = w * 0.46
      local inner = outer * 0.42
      for k = 0, 9 do
        local ang = -math.pi / 2 + k * math.pi / 5
        local rad = (k % 2 == 0) and outer or inner
        vx[k + 1] = cx + rad * math.cos(ang)
        vy[k + 1] = cy + rad * math.sin(ang)
      end
    end
    -- Even-odd ray cast to the right.
    local inside = false
    local j = 10
    for i = 1, 10 do
      if ((vy[i] > y) ~= (vy[j] > y)) and
         (x < (vx[j] - vx[i]) * (y - vy[i]) / (vy[j] - vy[i]) + vx[i]) then
        inside = not inside
      end
      j = i
    end
    return 1, 1, 1, inside and 1 or 0
  end)
end

-- 1px hairline border as a 9-slice-able rounded frame outline.
gen["frame-border"] = function()
  write_tga(OUT .. "frame-border.tga", 64, 64, function(x, y, w, h)
    local d = sd_round_rect(x, y, w, h, 0.5, 7)
    local a = (1 - smoothstep(0.0, 1.0, math.abs(d))) -- 1px stroke on d == 0
    return 1, 1, 1, a
  end)
end

----------------------------------------------------------------------

print("Wrekkit :: generating textures")
local names = {}
for k in pairs(gen) do names[#names + 1] = k end
table.sort(names)
for _, k in ipairs(names) do gen[k]() end
print("done -- " .. #names .. " textures written to " .. OUT)
