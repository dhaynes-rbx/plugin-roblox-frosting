--!strict

-- Frosting Plugin entry point.
-- Creates a ScreenGui overlay in CoreGui with a "Create Frosting" button
-- and a "Generate Test Cookies" button.

local Selection = game:GetService("Selection")
local CoreGui = game:GetService("CoreGui")

local TopFaceExtractor = require(script.TopFaceExtractor)
local PolygonInset = require(script.PolygonInset)
local PolygonOffset = require(script.PolygonOffset)
local PolygonClip = require(script.PolygonClip)
local FrostingBuilder = require(script.FrostingBuilder)
local TestCookieGenerator = require(script.TestCookieGenerator)

-- Configuration ---------------------------------------------------------

local INSET_FRACTION = 0.02
local EXTRUDE_FRACTION = 0.06
local HOLE_AREA_RATIO_MIN = 0.002

local FROSTING_COLOR = Color3.fromRGB(255, 105, 180)
local FROSTING_MATERIAL = Enum.Material.SmoothPlastic

-- UI --------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "FrostingPluginGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = CoreGui

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
statusLabel.Text = "Select a cookie MeshPart"
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

-- Frosting pipeline -----------------------------------------------------

local function computeFrostingRegions(
	island: TopFaceExtractor.Island,
	insetAmount: number
): { FrostingBuilder.FrostingRegion }
	local regions: { FrostingBuilder.FrostingRegion } = {}

	-- Inset the outer boundary (may produce multiple polygons)
	local outerPoly = PolygonInset.ensureCCW(island.outer)
	local outerInsetPolys = PolygonOffset.offset(outerPoly, insetAmount)

	if #outerInsetPolys == 0 then
		return regions
	end

	-- Compute hole outsets
	local outerArea = math.abs(PolygonInset.signedArea(outerPoly))
	local allHoleOutsetPolys: { { Vector2 } } = {}
	for _, hp in island.holes do
		local holeArea = math.abs(PolygonInset.signedArea(hp))
		if holeArea / outerArea < HOLE_AREA_RATIO_MIN then
			continue
		end
		local holePoly = PolygonInset.ensureCCW(hp)
		local outsetPolys = PolygonOffset.offset(holePoly, -insetAmount)
		for _, op in outsetPolys do
			table.insert(allHoleOutsetPolys, op)
		end
	end

	-- For each outer inset polygon, clip hole outsets to it
	for _, outerInsetPoly in outerInsetPolys do
		local clippedHoles: { { Vector2 } } = {}
		for _, holeOutsetPoly in allHoleOutsetPolys do
			local clipped = PolygonClip.intersection(holeOutsetPoly, outerInsetPoly)
			for _, cp in clipped do
				if math.abs(PolygonInset.signedArea(cp)) > 1e-6 then
					table.insert(clippedHoles, PolygonInset.ensureCCW(cp))
				end
			end
		end
		table.insert(regions, {
			outer = outerInsetPoly,
			holes = clippedHoles,
		})
	end

	return regions
end

-- Core logic ------------------------------------------------------------

local function createFrosting(cookiePart: MeshPart)
	setStatus("Reading mesh…")
	button.Active = false

	local ok, result = pcall(function()
		local extracted = TopFaceExtractor.extract(cookiePart)

		local diag = meshBBoxDiagonalXZ(cookiePart)
		local insetAmount = diag * INSET_FRACTION
		local extrudeHeight = diag * EXTRUDE_FRACTION

		setStatus("Computing offsets…")

		local allRegions: { FrostingBuilder.FrostingRegion } = {}
		for _, island in extracted.islands do
			local islandRegions = computeFrostingRegions(island, insetAmount)
			for _, r in islandRegions do
				table.insert(allRegions, r)
			end
		end

		if #allRegions == 0 then
			error("No valid frosting regions (cookie may be too thin for frosting)")
		end

		setStatus("Building mesh…")
		local buildResult = FrostingBuilder.build(
			allRegions,
			extracted.topY,
			extrudeHeight,
			FROSTING_COLOR
		)

		local frostingPart = buildResult.meshPart
		frostingPart.Name = cookiePart.Name .. "_Frosting"
		frostingPart.Color = FROSTING_COLOR
		frostingPart.Material = FROSTING_MATERIAL
		frostingPart.CFrame = cookiePart.CFrame
		frostingPart.Anchored = true
		frostingPart.Parent = cookiePart.Parent

		return frostingPart
	end)

	button.Active = true

	if ok then
		setStatus("Done! Frosting created.", false)
	else
		setStatus("Error: " .. tostring(result), true)
		warn("[FrostingPlugin]", result)
	end
end

-- Button handlers -------------------------------------------------------

button.MouseButton1Click:Connect(function()
	local selected = Selection:Get()

	if #selected == 0 then
		setStatus("Nothing selected.", true)
		return
	end
	if #selected > 1 then
		setStatus("Select exactly one MeshPart.", true)
		return
	end

	local part = selected[1]
	if not part:IsA("MeshPart") then
		setStatus("Selection must be a MeshPart.", true)
		return
	end

	createFrosting(part :: MeshPart)
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
