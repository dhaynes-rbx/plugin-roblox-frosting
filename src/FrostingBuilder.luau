--!strict

-- Generalized frosting mesh builder.
--
-- Builds frosting geometry for an outer boundary with zero or more holes.
-- Uses a closest-vertex bridge algorithm to merge holes into the outer
-- polygon, then ear-clips the merged polygon for the top cap.
--
-- Geometry produced:
--   Outer side walls  : vertical quads around outerInset
--   Inner side walls  : vertical quads around each hole outset (normals face into hole)
--   Top cap           : ear-clipped merged polygon at capY
--
-- Separate cap vertices prevent normal averaging with side walls.

local AssetService = game:GetService("AssetService")

local COINCIDENT_EPS = 1e-6

-- 2D Helpers --------------------------------------------------------------

local function cross2D(o: Vector2, a: Vector2, b: Vector2): number
	return (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X)
end

local function coincident(a: Vector2, b: Vector2): boolean
	return (a - b).Magnitude < COINCIDENT_EPS
end

local function earClipTriangulate(poly: { Vector2 }): { { number } }
	local indices: { number } = {}
	for i = 1, #poly do
		table.insert(indices, i)
	end

	local triangles: { { number } } = {}

	while #indices > 3 do
		local earFound = false
		local m = #indices

		for i = 1, m do
			local prev = indices[((i - 2) % m) + 1]
			local cur  = indices[i]
			local nxt  = indices[(i % m) + 1]

			if cross2D(poly[prev], poly[cur], poly[nxt]) <= 0 then
				continue
			end

			local pA, pB, pC = poly[prev], poly[cur], poly[nxt]
			local isEar = true
			for j = 1, m do
				local idx = indices[j]
				if idx == prev or idx == cur or idx == nxt then continue end
				local p = poly[idx]
				if coincident(p, pA) or coincident(p, pB) or coincident(p, pC) then
					continue
				end
				local d1 = cross2D(pA, pB, p)
				local d2 = cross2D(pB, pC, p)
				local d3 = cross2D(pC, pA, p)
				local hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0)
				local hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0)
				if not (hasNeg and hasPos) then
					isEar = false
					break
				end
			end

			if isEar then
				table.insert(triangles, { prev, cur, nxt })
				table.remove(indices, i)
				earFound = true
				break
			end
		end

		if not earFound then
			break
		end
	end

	if #indices == 3 then
		table.insert(triangles, { indices[1], indices[2], indices[3] })
	end

	return triangles
end

-- Bridge merging ----------------------------------------------------------
-- Merges a CCW hole into a CCW merged polygon using a closest-vertex bridge.
-- The hole is traversed CW (reverse) during insertion so the merged polygon
-- remains simple and CCW.

local function mergeHoleIntoPolygon(
	mergedPoly: { Vector2 },
	mergedOrigins: { { source: number, idx: number } },
	holePoly: { Vector2 },
	holeIndex: number
): ({ Vector2 }, { { source: number, idx: number } })
	local nh = #holePoly
	local nm = #mergedPoly

	-- Find closest vertex pair between merged polygon and hole
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

	-- Build new merged polygon:
	--   merged[1..bridgeIdx]  →  hole CW from holeStartIdx  →  merged[bridgeIdx..end]
	local newPoly: { Vector2 } = {}
	local newOrigins: { { source: number, idx: number } } = {}

	for i = 1, bridgeIdx do
		table.insert(newPoly, mergedPoly[i])
		table.insert(newOrigins, mergedOrigins[i])
	end

	-- Hole in CW order (reverse traversal of CCW polygon)
	for k = 0, nh do
		local idx = ((holeStartIdx - 1 - k) % nh) + 1
		table.insert(newPoly, holePoly[idx])
		table.insert(newOrigins, { source = holeIndex, idx = idx })
	end

	-- Bridge back to outer
	table.insert(newPoly, mergedPoly[bridgeIdx])
	table.insert(newOrigins, mergedOrigins[bridgeIdx])

	for i = bridgeIdx + 1, nm do
		table.insert(newPoly, mergedPoly[i])
		table.insert(newOrigins, mergedOrigins[i])
	end

	return newPoly, newOrigins
end

-- Main build function -----------------------------------------------------

export type BuildResult = {
	meshPart: MeshPart,
	meshCenterOffset: Vector3,
	editableMesh: EditableMesh,
}

local function build(
	outerInset: { Vector2 },
	holeOutsets: { { Vector2 } },
	topY: number,
	extrudeHeight: number,
	color: Color3?
): BuildResult
	local frostingColor = color or Color3.fromRGB(255, 105, 180)
	local em = AssetService:CreateEditableMesh()
	local colorId = em:AddColor(frostingColor, 0)
	local capY = topY + extrudeHeight
	local nOuter = #outerInset

	local function addTri(v0: number, v1: number, v2: number)
		local fid = em:AddTriangle(v0, v1, v2)
		em:SetFaceColors(fid, { colorId, colorId, colorId })
	end

	-- Outer boundary vertices: rim (bottom), wall-top, cap (separate for smooth normals)
	local outerRimVids: { number } = {}
	local outerWallTopVids: { number } = {}
	local outerCapVids: { number } = {}
	for _, p in outerInset do
		table.insert(outerRimVids, em:AddVertex(Vector3.new(p.X, topY, p.Y)))
		table.insert(outerWallTopVids, em:AddVertex(Vector3.new(p.X, capY, p.Y)))
		table.insert(outerCapVids, em:AddVertex(Vector3.new(p.X, capY, p.Y)))
	end

	-- Hole boundary vertices
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

	-- Inner side walls for each hole (normals face toward hole center)
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
		-- Merge all holes into the outer polygon via closest-vertex bridges
		local mergedPoly: { Vector2 } = {}
		local mergedOrigins: { { source: number, idx: number } } = {}
		for i, p in outerInset do
			mergedPoly[i] = p
			mergedOrigins[i] = { source = 0, idx = i }
		end

		for h = 1, #holeOutsets do
			mergedPoly, mergedOrigins = mergeHoleIntoPolygon(
				mergedPoly, mergedOrigins, holeOutsets[h], h
			)
		end

		-- Ear-clip the merged polygon and map back to cap vertex IDs
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

	-- AABB center offset (frosting cap flush with cookie top)
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, p in outerInset do
		minX = math.min(minX, p.X)
		maxX = math.max(maxX, p.X)
		minZ = math.min(minZ, p.Y)
		maxZ = math.max(maxZ, p.Y)
	end
	local meshCenterOffset = Vector3.new(
		(minX + maxX) / 2,
		topY - extrudeHeight / 2,
		(minZ + maxZ) / 2
	)

	local meshPart = AssetService:CreateMeshPartAsync(Content.fromObject(em))

	return {
		meshPart = meshPart,
		meshCenterOffset = meshCenterOffset,
		editableMesh = em,
	}
end

return {
	build = build,
}
