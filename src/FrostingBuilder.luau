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
--
-- PolygonOffset.offsetPWH guarantees that each region's holes are:
--   * simple, CCW, mutually non-overlapping
--   * strictly contained in a simple CCW outer
-- so bridge merging only needs to find a non-crossing bridge between outer and
-- each hole in turn; it never has to reason about overlap or containment
-- anomalies.
--------------------------------------------------------------------------------

-- Proper segment-segment intersection test (returns true if interiors cross).
local function segsCross(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2): boolean
	local d1 = p2 - p1
	local d2 = p4 - p3
	local denom = d1.X * d2.Y - d1.Y * d2.X
	if math.abs(denom) < 1e-12 then
		return false
	end
	local d = p3 - p1
	local t = (d.X * d2.Y - d.Y * d2.X) / denom
	local u = (d.X * d1.Y - d.Y * d1.X) / denom
	local EPS = 1e-6
	return t > EPS and t < 1 - EPS and u > EPS and u < 1 - EPS
end

-- Bridge-merge a hole into the merged polygon, tracking vertex IDs directly.
-- `otherHoles` are all remaining unmerged holes whose edges the bridge must
-- also avoid crossing.
-- `reservedOuter` is the set of Vector2 positions already used as a bridge
-- outer-endpoint by a prior hole in the same region.  Reusing an outer
-- endpoint creates a degree-3 junction in the top-face boundary graph that
-- TopFaceExtractor's leftmost-turn chain walk cannot disambiguate; the
-- result is one hole's boundary being silently merged into another (the
-- pre-Phase-2 Maze L1 F2 "dropped right slit" observation).  By picking a
-- distinct outer endpoint per hole we guarantee each slit retains a
-- well-formed boundary loop after re-extraction.
-- Returns (newPoly, newVids, true) on success, or (mergedPoly, mergedVids, false)
-- when no non-crossing bridge exists (caller should retry later).
local function mergeHoleVids(
	mergedPoly: { Vector2 },
	mergedVids: { number },
	holePoly: { Vector2 },
	holeVids: { number },
	otherHoles: { { Vector2 } }?,
	reservedOuter: { Vector2 }?
): ({ Vector2 }, { number }, boolean, Vector2?)
	local nh = #holePoly
	local nm = #mergedPoly
	-- Reserved-outer-endpoint dedup tolerance must match downstream ear-clip's
	-- pinch / coincident thresholds (diag * 1e-5).  A too-tight RESERVED_EPS
	-- would let the same mesh vertex serve as bridge endpoint for two holes,
	-- recreating the degree-3 junction that TopFaceExtractor's chain walk
	-- silently folds into a lost hole boundary.
	local RESERVED_EPS = PolygonInset.computeEps(mergedPoly)

	local candidates: { { mi: number, hi: number, dist: number } } = {}
	for mi = 1, nm do
		for hi = 1, nh do
			table.insert(candidates, { mi = mi, hi = hi, dist = (mergedPoly[mi] - holePoly[hi]).Magnitude })
		end
	end
	table.sort(candidates, function(a, b)
		return a.dist < b.dist
	end)

	local function isReserved(p: Vector2): boolean
		if not reservedOuter then return false end
		for _, r in reservedOuter do
			if (r - p).Magnitude < RESERVED_EPS then return true end
		end
		return false
	end

	local bridgeIdx: number? = nil
	local holeStartIdx: number? = nil
	-- Two passes: first prefer a non-reserved outer endpoint; if none is
	-- viable, fall back to reuse (better a junction than no bridge).
	for pass = 1, 2 do
		for _, cand in candidates do
			local bp = mergedPoly[cand.mi]
			local hp = holePoly[cand.hi]
			if pass == 1 and isReserved(bp) then continue end
			local valid = true
			for i = 1, nm do
				local i2 = (i % nm) + 1
				if i == cand.mi or i2 == cand.mi then continue end
				if segsCross(bp, hp, mergedPoly[i], mergedPoly[i2]) then
					valid = false
					break
				end
			end
			if valid then
				for i = 1, nh do
					local i2 = (i % nh) + 1
					if i == cand.hi or i2 == cand.hi then continue end
					if segsCross(bp, hp, holePoly[i], holePoly[i2]) then
						valid = false
						break
					end
				end
			end
			if valid and otherHoles then
				for _, oh in otherHoles do
					local noh = #oh
					for i = 1, noh do
						local i2 = (i % noh) + 1
						if segsCross(bp, hp, oh[i], oh[i2]) then
							valid = false
							break
						end
					end
					if not valid then break end
				end
			end
			if valid then
				bridgeIdx = cand.mi
				holeStartIdx = cand.hi
				break
			end
		end
		if bridgeIdx then break end
	end

	if not bridgeIdx or not holeStartIdx then
		return mergedPoly, mergedVids, false, nil
	end

	local newP: { Vector2 } = {}
	local newV: { number } = {}

	for i = 1, bridgeIdx do
		table.insert(newP, mergedPoly[i])
		table.insert(newV, mergedVids[i])
	end
	for k = 0, nh do
		local idx = ((holeStartIdx - 1 - k) % nh) + 1
		table.insert(newP, holePoly[idx])
		table.insert(newV, holeVids[idx])
	end
	table.insert(newP, mergedPoly[bridgeIdx])
	table.insert(newV, mergedVids[bridgeIdx])
	for i = bridgeIdx + 1, nm do
		table.insert(newP, mergedPoly[i])
		table.insert(newV, mergedVids[i])
	end

	return newP, newV, true, mergedPoly[bridgeIdx]
end

-- Remove near-duplicate and collinear vertices from merged cap boundary; keeps
-- mergedOrigins aligned so cap triangles still map to the correct cap verts.
local function stripCollinearMerged(
	mergedPoly: { Vector2 },
	mergedOrigins: { { source: number, idx: number } }
): ({ Vector2 }, { { source: number, idx: number } })
	-- Collinear tolerance scales with polygon size so this matches the
	-- pre-weld done by earClipTriangulate on the same polygon.
	local COL_EPS = PolygonInset.computeEps(mergedPoly)
	local cross2D = function(o: Vector2, a: Vector2, b: Vector2): number
		return (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X)
	end

	local workP = table.clone(mergedPoly)
	local workO = table.clone(mergedOrigins)
	local guard = 0
	while #workP >= 3 and guard < #workP + 32 do
		guard += 1
		local m = #workP
		local removeAt: number? = nil
		for j = 1, m do
			local prev = workP[((j - 2) % m) + 1]
			local cur = workP[j]
			local nxt = workP[(j % m) + 1]
			if (cur - prev).Magnitude < COL_EPS or (nxt - cur).Magnitude < COL_EPS then
				removeAt = j
				break
			end
			local cr = cross2D(prev, cur, nxt)
			local scale = math.max((cur - prev).Magnitude * (nxt - cur).Magnitude, COL_EPS)
			if math.abs(cr) <= COL_EPS * scale then
				removeAt = j
				break
			end
		end
		if removeAt then
			table.remove(workP, removeAt)
			table.remove(workO, removeAt)
		else
			break
		end
	end
	return workP, workO
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

	-- offsetPWH guarantees holes are non-overlapping, CCW, strictly contained
	-- in the outer; just CCW-normalize defensively.
	local holeOutsets: { { Vector2 } } = {}
	for _, h in region.holes do
		table.insert(holeOutsets, PolygonInset.ensureCCW(h))
	end

	-- Hole boundary vertices: rim, wall-top, cap (separated for normals)
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

	-- Inner side walls for each hole (uses merged holeOutsets)
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
		-- holeOutsets is already merged; reuse allHoleCapVids for the cap.
		local mergedPoly: { Vector2 } = {}
		local mergedVids: { number } = {}
		for i, p in outerInset do
			mergedPoly[i] = p
			mergedVids[i] = outerCapVids[i]
		end

		local queue: { number } = {}
		for h = 1, #holeOutsets do
			table.insert(queue, h)
		end

		local maxRetries = #queue * #queue
		local retries = 0
		local reservedOuter: { Vector2 } = {}
		while #queue > 0 and retries < maxRetries do
			local h = queue[1]
			table.remove(queue, 1)
			local others: { { Vector2 } } = {}
			for _, oh in queue do
				table.insert(others, holeOutsets[oh])
			end
			local newP, newV, ok, usedOuter = mergeHoleVids(
				mergedPoly, mergedVids, holeOutsets[h], allHoleCapVids[h], others, reservedOuter
			)
			if ok then
				mergedPoly = newP
				mergedVids = newV
				retries = 0
				if usedOuter then table.insert(reservedOuter, usedOuter) end
			else
				table.insert(queue, h)
				retries += 1
			end
		end

		local earTris = earClipTriangulate(mergedPoly, holeOutsets)
		for _, tri in earTris do
			addTri(mergedVids[tri[3]], mergedVids[tri[2]], mergedVids[tri[1]])
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
