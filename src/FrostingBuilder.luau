--!strict

-- Generalized frosting mesh builder.
--
-- Accepts an array of FrostingRegion, each with an outer CCW boundary and
-- zero or more hole CCW boundaries.  All regions are combined into a single
-- EditableMesh → MeshPart.
--
-- Geometry per region:
--   Outer side walls  : vertical quads around outer boundary
--   Inner side walls  : vertical quads around each hole (normals face into hole)
--   Top cap           : ear-clipped merged polygon (holes bridged in) at capY
--
-- Separate cap vertices prevent normal averaging with side walls.

local AssetService = game:GetService("AssetService")
local PolygonInset = require(script.Parent.PolygonInset)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type FrostingRegion = {
	outer: { Vector2 },
	holes: { { Vector2 } },
}

export type BuildResult = {
	meshPart: MeshPart,
	editableMesh: EditableMesh,
}

local earClipTriangulate = PolygonInset.earClipTriangulate

--------------------------------------------------------------------------------
-- Bridge merging: merge a CCW hole into a CCW outer polygon
--------------------------------------------------------------------------------

local function mergeHoleIntoPolygon(
	mergedPoly: { Vector2 },
	mergedOrigins: { { source: number, idx: number } },
	holePoly: { Vector2 },
	holeIndex: number
): ({ Vector2 }, { { source: number, idx: number } })
	local nh = #holePoly
	local nm = #mergedPoly

	local bestDist = math.huge
	local bridgeIdx = 1
	local holeStartIdx = 1
	for mi = 1, nm do
		for hi = 1, nh do
			local d = (mergedPoly[mi] - holePoly[hi]).Magnitude
			if d < bestDist then
				bestDist = d
				bridgeIdx = mi
				holeStartIdx = hi
			end
		end
	end

	local newPoly: { Vector2 } = {}
	local newOrigins: { { source: number, idx: number } } = {}

	for i = 1, bridgeIdx do
		table.insert(newPoly, mergedPoly[i])
		table.insert(newOrigins, mergedOrigins[i])
	end

	for k = 0, nh do
		local idx = ((holeStartIdx - 1 - k) % nh) + 1
		table.insert(newPoly, holePoly[idx])
		table.insert(newOrigins, { source = holeIndex, idx = idx })
	end

	table.insert(newPoly, mergedPoly[bridgeIdx])
	table.insert(newOrigins, mergedOrigins[bridgeIdx])

	for i = bridgeIdx + 1, nm do
		table.insert(newPoly, mergedPoly[i])
		table.insert(newOrigins, mergedOrigins[i])
	end

	return newPoly, newOrigins
end

--------------------------------------------------------------------------------
-- Build a single region (outer + holes) into the given EditableMesh
--------------------------------------------------------------------------------

local function buildRegion(
	em: EditableMesh,
	colorId: number,
	region: FrostingRegion,
	topY: number,
	capY: number
)
	local addTri = function(v0: number, v1: number, v2: number)
		local fid = em:AddTriangle(v0, v1, v2)
		em:SetFaceColors(fid, { colorId, colorId, colorId })
	end

	local outerInset = PolygonInset.ensureCCW(region.outer)
	local nOuter = #outerInset

	-- Outer boundary vertices: rim, wall-top, cap (separated for normals)
	local outerRimVids: { number } = {}
	local outerWallTopVids: { number } = {}
	local outerCapVids: { number } = {}
	for _, p in outerInset do
		table.insert(outerRimVids, em:AddVertex(Vector3.new(p.X, topY, p.Y)))
		table.insert(outerWallTopVids, em:AddVertex(Vector3.new(p.X, capY, p.Y)))
		table.insert(outerCapVids, em:AddVertex(Vector3.new(p.X, capY, p.Y)))
	end

	-- Hole boundary vertices
	local holeOutsets = region.holes
	local allHoleRimVids: { { number } } = {}
	local allHoleWallTopVids: { { number } } = {}
	local allHoleCapVids: { { number } } = {}
	for h, holePoly in holeOutsets do
		local rimVids: { number } = {}
		local wallTopVids: { number } = {}
		local capVids: { number } = {}
		for _, p in holePoly do
			table.insert(rimVids, em:AddVertex(Vector3.new(p.X, topY, p.Y)))
			table.insert(wallTopVids, em:AddVertex(Vector3.new(p.X, capY, p.Y)))
			table.insert(capVids, em:AddVertex(Vector3.new(p.X, capY, p.Y)))
		end
		allHoleRimVids[h] = rimVids
		allHoleWallTopVids[h] = wallTopVids
		allHoleCapVids[h] = capVids
	end

	-- Outer side walls
	for i = 1, nOuter do
		local i2 = (i % nOuter) + 1
		addTri(outerRimVids[i2], outerRimVids[i], outerWallTopVids[i])
		addTri(outerRimVids[i2], outerWallTopVids[i], outerWallTopVids[i2])
	end

	-- Inner side walls for each hole
	for h, holePoly in holeOutsets do
		local nHole = #holePoly
		local rimVids = allHoleRimVids[h]
		local wallTopVids = allHoleWallTopVids[h]
		for i = 1, nHole do
			local i2 = (i % nHole) + 1
			addTri(rimVids[i], rimVids[i2], wallTopVids[i2])
			addTri(rimVids[i], wallTopVids[i2], wallTopVids[i])
		end
	end

	-- Top cap triangulation
	if #holeOutsets == 0 then
		local earTris = earClipTriangulate(outerInset)
		for _, tri in earTris do
			addTri(outerCapVids[tri[3]], outerCapVids[tri[2]], outerCapVids[tri[1]])
		end
	else
		local mergedPoly: { Vector2 } = {}
		local mergedOrigins: { { source: number, idx: number } } = {}
		for i, p in outerInset do
			mergedPoly[i] = p
			mergedOrigins[i] = { source = 0, idx = i }
		end

		for h = 1, #holeOutsets do
			mergedPoly, mergedOrigins =
				mergeHoleIntoPolygon(mergedPoly, mergedOrigins, holeOutsets[h], h)
		end

		local earTris = earClipTriangulate(mergedPoly)
		for _, tri in earTris do
			local vids: { number } = {}
			for _, idx in tri do
				local origin = mergedOrigins[idx]
				if origin.source == 0 then
					table.insert(vids, outerCapVids[origin.idx])
				else
					table.insert(vids, allHoleCapVids[origin.source][origin.idx])
				end
			end
			addTri(vids[3], vids[2], vids[1])
		end
	end
end

--------------------------------------------------------------------------------
-- Main build function
--------------------------------------------------------------------------------

local function build(
	regions: { FrostingRegion },
	topY: number,
	extrudeHeight: number,
	color: Color3?
): BuildResult
	local frostingColor = color or Color3.fromRGB(255, 105, 180)
	local em = AssetService:CreateEditableMesh()
	local colorId = em:AddColor(frostingColor, 0)
	local capY = topY + extrudeHeight

	-- Build every region into the same EditableMesh
	for _, region in regions do
		buildRegion(em, colorId, region, topY, capY)
	end

	local meshPart = AssetService:CreateMeshPartAsync(Content.fromObject(em))

	return {
		meshPart = meshPart,
		editableMesh = em,
	}
end

return {
	build = build,
}
