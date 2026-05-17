--!strict

-- Frosting Plugin entry point.
-- Creates a ScreenGui overlay in CoreGui with a "Create Frosting" button
-- and a "Generate Test Cookies" button.

local Selection = game:GetService("Selection")
local CoreGui = game:GetService("CoreGui")
local CollectionService = game:GetService("CollectionService")

local TopFaceExtractor = require(script.TopFaceExtractor)
local PolygonOffset = require(script.PolygonOffset)
local FrostingBuilder = require(script.FrostingBuilder)
local TestCookieGenerator = require(script.TestCookieGenerator)

-- Diagnostic helpers ----------------------------------------------------
-- Used by the Phase 1 failure inventory workflow (see docs/frosting-failures.md).
-- Pure functions over 2D polygons; no pipeline side effects.

local function polySignedArea(poly: { Vector2 }): number
	local n = #poly
	local s = 0
	if n < 3 then return 0 end
	local j = n
	for i = 1, n do
		s += (poly[j].X + poly[i].X) * (poly[j].Y - poly[i].Y)
		j = i
	end
	return -0.5 * s
end

local function polyCentroid(poly: { Vector2 }): Vector2
	local n = #poly
	if n == 0 then return Vector2.zero end
	local a = polySignedArea(poly)
	if math.abs(a) < 1e-12 then
		local cx, cy = 0, 0
		for _, p in poly do cx += p.X; cy += p.Y end
		return Vector2.new(cx / n, cy / n)
	end
	local cx, cy = 0, 0
	local j = n
	for i = 1, n do
		local pj, pi = poly[j], poly[i]
		local cross = pj.X * pi.Y - pi.X * pj.Y
		cx += (pj.X + pi.X) * cross
		cy += (pj.Y + pi.Y) * cross
		j = i
	end
	local f = 1 / (6 * a)
	return Vector2.new(cx * f, cy * f)
end

local function polyBBox(poly: { Vector2 }): { minX: number, maxX: number, minZ: number, maxZ: number }
	local minX, minZ = math.huge, math.huge
	local maxX, maxZ = -math.huge, -math.huge
	for _, p in poly do
		if p.X < minX then minX = p.X end
		if p.X > maxX then maxX = p.X end
		if p.Y < minZ then minZ = p.Y end
		if p.Y > maxZ then maxZ = p.Y end
	end
	return { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ }
end

-- Approximation to "narrowness" of a simple polygon: minor axis of its
-- axis-aligned bounding box.  Suitable for flagging maze channels and
-- thin holes; not a true width measurement in general.
local function polyBBoxMinor(poly: { Vector2 }): number
	local b = polyBBox(poly)
	return math.min(b.maxX - b.minX, b.maxZ - b.minZ)
end

-- Minimum interior angle at any vertex of a simple polygon (degrees).
-- Helpful for confirming F4 bisector overshoot (Heart seed).
local function polyMinInteriorAngleDeg(poly: { Vector2 }): number
	local n = #poly
	if n < 3 then return 0 end
	local minAngle = math.huge
	for i = 1, n do
		local prev = poly[((i - 2) % n) + 1]
		local curr = poly[i]
		local nxt = poly[(i % n) + 1]
		local a = prev - curr
		local b = nxt - curr
		local am, bm = a.Magnitude, b.Magnitude
		if am < 1e-12 or bm < 1e-12 then continue end
		local dot = math.clamp((a.X * b.X + a.Y * b.Y) / (am * bm), -1, 1)
		local ang = math.deg(math.acos(dot))
		if ang < minAngle then minAngle = ang end
	end
	return if minAngle == math.huge then 0 else minAngle
end

local function pwhStats(pwh: { outer: { Vector2 }, holes: { { Vector2 } } })
	local outerArea = polySignedArea(pwh.outer)
	local holes = {}
	for hi, h in pwh.holes do
		table.insert(holes, {
			index = hi,
			area = math.abs(polySignedArea(h)),
			centroid = polyCentroid(h),
			bbox = polyBBox(h),
			bboxMinor = polyBBoxMinor(h),
			vertexCount = #h,
		})
	end
	return {
		outerArea = math.abs(outerArea),
		outerSignedArea = outerArea,
		outerCentroid = polyCentroid(pwh.outer),
		outerBBox = polyBBox(pwh.outer),
		outerMinInteriorAngleDeg = polyMinInteriorAngleDeg(pwh.outer),
		outerVertexCount = #pwh.outer,
		holeCount = #pwh.holes,
		holes = holes,
	}
end

-- Stable diagnostic hook consumed by the Phase 1 failure inventory.  Populated
-- inside createFrostingForPart after offsetPWH returns and before FrostingBuilder
-- runs.  Purely observational; no algorithm changes flow through this table.
--
-- Shape:
--   _G.__frosting_pipeline__ = {
--       runs = { <run>, ... },              -- append-only history across builds
--       lastRun = runs[#runs],              -- most recent run
--       clear = function() ... end,         -- reset for a fresh sweep
--   }
--   <run> = {
--       partName, newLayer, prevLayer,
--       diag, insetAmount, extrudeHeight, topY,
--       islands,        -- raw PolygonWithHoles[] from TopFaceExtractor (pre-offset)
--       islandStats,    -- per-island derived metrics (area, centroid, bbox, hole stats)
--       regions,        -- raw FrostingRegion[] from offsetPWH (post-offset, pre-builder)
--       regionStats,    -- per-region derived metrics (same schema as islandStats)
--   }
if not _G.__frosting_pipeline__ then
	_G.__frosting_pipeline__ = {
		runs = {},
		lastRun = nil,
		clear = function()
			_G.__frosting_pipeline__.runs = {}
			_G.__frosting_pipeline__.lastRun = nil
		end,
	}
end

-- Configuration ---------------------------------------------------------

local INSET_AMOUNT = 0.15
local EXTRUDE_FRACTION = 0.02

local FROSTING_MATERIAL = Enum.Material.SmoothPlastic
local FROSTING_TAG = "Frosting"
local FROSTING_LAYER_ATTR = "FrostingLayer"

-- Palette cycled across layers.  Chosen to be bright, highly saturated, and
-- pairwise visually distinguishable against their neighbors.  Index 1 is the
-- first layer placed on a bare cookie.  Layers beyond 10 wrap around.
local FROSTING_PALETTE: { Color3 } = {
	Color3.fromRGB(255, 105, 180), -- 1  hot pink
	Color3.fromRGB(80, 255, 80),   -- 2  lime green
	Color3.fromRGB(40, 140, 255),  -- 3  electric blue
	Color3.fromRGB(255, 215, 0),   -- 4  gold
	Color3.fromRGB(255, 120, 0),   -- 5  tangerine orange
	Color3.fromRGB(170, 70, 255),  -- 6  violet
	Color3.fromRGB(0, 230, 230),   -- 7  aqua
	Color3.fromRGB(255, 50, 50),   -- 8  red
	Color3.fromRGB(200, 255, 50),  -- 9  chartreuse
	Color3.fromRGB(255, 150, 140), -- 10 coral
}

local function colorForLayer(layer: number): Color3
	local n = #FROSTING_PALETTE
	local idx = ((layer - 1) % n) + 1
	return FROSTING_PALETTE[idx]
end

-- Toolbar ---------------------------------------------------------------

local toolbar = plugin:CreateToolbar("Frosting")
local toggleButton = toolbar:CreateButton(
	"ToggleFrosting",
	"Toggle the Frosting plugin panel",
	"rbxassetid://14978120386"
)
toggleButton.ClickableWhenViewportHidden = true

-- UI --------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "FrostingPluginGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Enabled = false
gui.Parent = CoreGui

toggleButton:SetActive(gui.Enabled)

toggleButton.Click:Connect(function()
	gui.Enabled = not gui.Enabled
	toggleButton:SetActive(gui.Enabled)
end)

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.Size = UDim2.new(0, 220, 0, 110)
frame.Position = UDim2.new(0, 12, 0, 12)
frame.BackgroundColor3 = Color3.fromRGB(36, 36, 36)
frame.BorderSizePixel = 0
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local padding = Instance.new("UIPadding")
padding.PaddingLeft = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.PaddingTop = UDim.new(0, 10)
padding.PaddingBottom = UDim.new(0, 10)
padding.Parent = frame

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 6)
layout.Parent = frame

local button = Instance.new("TextButton")
button.Name = "CreateFrostingButton"
button.Size = UDim2.new(1, 0, 0, 28)
button.BackgroundColor3 = Color3.fromRGB(86, 180, 233)
button.TextColor3 = Color3.fromRGB(255, 255, 255)
button.Font = Enum.Font.GothamBold
button.TextSize = 13
button.Text = "Create Frosting"
button.BorderSizePixel = 0
button.LayoutOrder = 1
button.Parent = frame

local btnCorner = Instance.new("UICorner")
btnCorner.CornerRadius = UDim.new(0, 5)
btnCorner.Parent = button

local testButton = Instance.new("TextButton")
testButton.Name = "GenerateTestCookiesButton"
testButton.Size = UDim2.new(1, 0, 0, 28)
testButton.BackgroundColor3 = Color3.fromRGB(233, 163, 86)
testButton.TextColor3 = Color3.fromRGB(255, 255, 255)
testButton.Font = Enum.Font.GothamBold
testButton.TextSize = 13
testButton.Text = "Generate Test Cookies"
testButton.BorderSizePixel = 0
testButton.LayoutOrder = 2
testButton.Parent = frame

local testBtnCorner = Instance.new("UICorner")
testBtnCorner.CornerRadius = UDim.new(0, 5)
testBtnCorner.Parent = testButton

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Size = UDim2.new(1, 0, 0, 16)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.Text = "Select one or more MeshParts"
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.LayoutOrder = 3
statusLabel.Parent = frame

-- Helpers ---------------------------------------------------------------

local function setStatus(msg: string, isError: boolean?)
	statusLabel.Text = msg
	statusLabel.TextColor3 = if isError
		then Color3.fromRGB(255, 100, 100)
		else Color3.fromRGB(180, 230, 180)
end

local function meshBBoxDiagonalXZ(part: MeshPart): number
	local size = part.Size
	return math.sqrt(size.X ^ 2 + size.Z ^ 2)
end

-- Core logic ------------------------------------------------------------

-- Forward-declare so the MCP test hook below can reference it.
local createFrostingForPart

-- Stable hook used by the MCP testing workflow described in
-- .cursor/rules/plugin-testing.mdc.  Bypasses the UI button handler and
-- returns the new frosting MeshPart (or nil if the top is too thin).
-- MCP testing hook for regenerating TestCookies without a UI click
-- (TextButton.MouseButton1Click cannot be programmatically fired from Luau).
_G.__frosting_generate_test_cookies__ = function(): (boolean, any)
	return pcall(function()
		TestCookieGenerator.generateAll()
	end)
end

_G.__frosting_build__ = function(cookiePart: MeshPart): MeshPart?
	local ok, result = createFrostingForPart(cookiePart, "")
	if ok then
		return result :: MeshPart
	end
	return nil
end

function createFrostingForPart(cookiePart: MeshPart, prefix: string): (boolean, any)
	setStatus(prefix .. 'Reading mesh for "' .. cookiePart.Name .. '"…')

	local prevLayer = tonumber(cookiePart:GetAttribute(FROSTING_LAYER_ATTR)) or 0
	local newLayer = prevLayer + 1
	local color = colorForLayer(newLayer)

	local ok, result = pcall(function()
		local extracted = TopFaceExtractor.extract(cookiePart)

		local diag = meshBBoxDiagonalXZ(cookiePart)
		local insetAmount = INSET_AMOUNT
		local extrudeHeight = diag * EXTRUDE_FRACTION

		setStatus(prefix .. "Computing offsets…")

		local allRegions: { FrostingBuilder.FrostingRegion } = {}
		local minRegionArea = insetAmount * insetAmount
		for _, island in extracted.islands do
			local pwhRegions = PolygonOffset.offsetPWH(island, insetAmount)
			for _, r in pwhRegions do
				if math.abs(polySignedArea(r.outer)) >= minRegionArea then
					table.insert(allRegions, r)
				end
			end
		end

		-- Publish diagnostic state BEFORE the no-frosting guard so callers
		-- investigating F6 (region vanished) can still inspect the extracted
		-- islands and the empty-region offset output.
		do
			local islandStats = {}
			for _, island in extracted.islands do
				table.insert(islandStats, pwhStats(island))
			end
			local regionStats = {}
			for _, region in allRegions do
				table.insert(regionStats, pwhStats(region))
			end
			local run = {
				partName = cookiePart.Name,
				prevLayer = prevLayer,
				newLayer = newLayer,
				diag = diag,
				insetAmount = insetAmount,
				extrudeHeight = extrudeHeight,
				topY = extracted.topY,
				islands = extracted.islands,
				islandStats = islandStats,
				regions = allRegions,
				regionStats = regionStats,
			}
			table.insert(_G.__frosting_pipeline__.runs, run)
			_G.__frosting_pipeline__.lastRun = run
		end

		if #allRegions == 0 then
			error("No frosting possible: top is fully covered or too thin")
		end

		setStatus(prefix .. "Building mesh…")
		local buildResult = FrostingBuilder.build(
			allRegions,
			extracted.topY,
			extrudeHeight,
			color
		)

		local frostingPart = buildResult.meshPart
		frostingPart.Name = cookiePart.Name .. "_Frosting"
		frostingPart.Color = color
		frostingPart.Material = FROSTING_MATERIAL
		frostingPart.CFrame = cookiePart.CFrame
		frostingPart.Anchored = true
		frostingPart.Parent = cookiePart.Parent
		frostingPart:SetAttribute(FROSTING_LAYER_ATTR, newLayer)
		CollectionService:AddTag(frostingPart, FROSTING_TAG)

		return frostingPart
	end)

	if ok then
		return true, result
	else
		warn("[FrostingPlugin]", cookiePart.Name, result)
		return false, cookiePart.Name .. ": " .. tostring(result)
	end
end

-- Button handlers -------------------------------------------------------

button.MouseButton1Click:Connect(function()
	local selected = Selection:Get()

	local meshParts: { MeshPart } = {}
	for _, obj in selected do
		if obj:IsA("MeshPart") then
			table.insert(meshParts, obj :: MeshPart)
		end
	end

	if #meshParts == 0 then
		setStatus("No MeshParts selected.", true)
		return
	end

	button.Active = false
	local succeeded, failed = 0, 0
	local errors: { string } = {}
	local newFrostingParts: { Instance } = {}

	for i, part in meshParts do
		local prefix = if #meshParts > 1
			then string.format("[%d/%d] ", i, #meshParts)
			else ""
		local ok, result = createFrostingForPart(part, prefix)
		if ok then
			succeeded += 1
			table.insert(newFrostingParts, result :: Instance)
		else
			failed += 1
			if result then table.insert(errors, result :: string) end
		end
	end

	if #newFrostingParts > 0 then
		Selection:Set(newFrostingParts)
	end

	button.Active = true

	if failed == 0 then
		local noun = if succeeded == 1 then "frosting" else "frostings"
		setStatus(string.format("Done! %d %s created.", succeeded, noun), false)
	else
		setStatus(string.format("%d succeeded, %d failed.", succeeded, failed), true)
		for _, e in errors do
			warn("[FrostingPlugin]", e)
		end
	end
end)

testButton.MouseButton1Click:Connect(function()
	setStatus("Generating test cookies…")
	testButton.Active = false

	local ok, err = pcall(function()
		TestCookieGenerator.generateAll()
	end)

	testButton.Active = true

	if ok then
		setStatus("Test cookies generated!", false)
	else
		setStatus("Error: " .. tostring(err), true)
		warn("[FrostingPlugin]", err)
	end
end)

-- Cleanup on plugin unload ----------------------------------------------
plugin.Unloading:Connect(function()
	gui:Destroy()
end)
