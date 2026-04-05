--!strict

-- Frosting Plugin entry point.
-- Creates a ScreenGui overlay in CoreGui with a "Create Frosting" button.

local Selection = game:GetService("Selection")
local CoreGui = game:GetService("CoreGui")

local TopFaceExtractor = require(script.TopFaceExtractor)
local PolygonInset = require(script.PolygonInset)
local FrostingBuilder = require(script.FrostingBuilder)

-- Configuration ---------------------------------------------------------

-- Inset amount as a fraction of the mesh's XZ bounding-box diagonal.
local INSET_FRACTION = 0.02
-- Extrude height as a fraction of the mesh's XZ bounding-box diagonal.
local EXTRUDE_FRACTION = 0.06
-- A hole boundary must have at least this fraction of the outer area to be treated as a real hole.
local HOLE_AREA_RATIO_MIN = 0.03

-- Frosting appearance
local FROSTING_COLOR = Color3.fromRGB(255, 105, 180)  -- pink
local FROSTING_MATERIAL = Enum.Material.SmoothPlastic

-- UI --------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "FrostingPluginGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = CoreGui

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.Size = UDim2.new(0, 220, 0, 70)
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

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Size = UDim2.new(1, 0, 0, 16)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.Text = "Select a cookie MeshPart"
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.LayoutOrder = 2
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

local function createFrosting(cookiePart: MeshPart)
	setStatus("Reading mesh…")
	button.Active = false

	local ok, result = pcall(function()
		local extracted = TopFaceExtractor.extract(cookiePart)

		local diag = meshBBoxDiagonalXZ(cookiePart)
		local insetAmount = diag * INSET_FRACTION
		local extrudeHeight = diag * EXTRUDE_FRACTION

		local outerPoly = PolygonInset.ensureCCW(extracted.polygon)
		local outerInset = PolygonInset.inset(outerPoly, insetAmount)

		setStatus("Building mesh…")
		local buildResult

		local outerArea = math.abs(PolygonInset.signedArea(outerPoly))
		local holeOutsets: { { Vector2 } } = {}
		for _, hp in extracted.holePolygons do
			local holeArea = math.abs(PolygonInset.signedArea(hp))
			if holeArea / outerArea >= HOLE_AREA_RATIO_MIN then
				local holePoly = PolygonInset.ensureCCW(hp)
				local holeOutset = PolygonInset.inset(holePoly, -insetAmount)
				table.insert(holeOutsets, holeOutset)
			end
		end

		buildResult = FrostingBuilder.build(
			outerInset,
			holeOutsets,
			extracted.topY,
			extrudeHeight,
			FROSTING_COLOR
		)

		local frostingPart = buildResult.meshPart
		frostingPart.Name = cookiePart.Name .. "_Frosting"
		frostingPart.Color = FROSTING_COLOR
		frostingPart.Material = FROSTING_MATERIAL
		frostingPart.CFrame = cookiePart.CFrame * CFrame.new(buildResult.meshCenterOffset)
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

-- Button handler --------------------------------------------------------

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

-- Cleanup on plugin unload ----------------------------------------------
plugin.Unloading:Connect(function()
	gui:Destroy()
end)
