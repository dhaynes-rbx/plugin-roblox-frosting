--!strict

-- Polygon-with-holes classifier.
--
-- Takes a flat list of simple CCW polygons and groups them into PWH regions
-- via even/odd containment depth.  Used by TopFaceExtractor (to classify
-- boundary chains on the top face) and by PolygonOffset.offsetPWH (to
-- classify faces extracted from a planar arrangement).
--
-- Contract:
--   Input  : simple polygons, any orientation (caller need not CCW-normalize).
--   Output : zero or more { outer, holes } regions where `outer` is CCW and
--            each hole is CCW (caller inverts for CW holes if needed).
--
-- Classification rule:
--   depth(P) = number of other input polygons that contain a sample vertex of P.
--   depth even → outer of an island
--   depth odd  → hole of its deepest-enclosing outer ancestor

local PolygonInset = require(script.Parent.PolygonInset)

export type PolygonWithHoles = {
	outer: { Vector2 },
	holes: { { Vector2 } },
}

local function pointInPolygon(point: Vector2, poly: { Vector2 }): boolean
	local n = #poly
	local inside = false
	local px, py = point.X, point.Y
	local j = n
	for i = 1, n do
		local xi, yi = poly[i].X, poly[i].Y
		local xj, yj = poly[j].X, poly[j].Y
		if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
			inside = not inside
		end
		j = i
	end
	return inside
end

-- Find an interior sample point of a simple polygon.  Uses the midpoint of
-- the first edge, offset slightly inward along the edge-normal, which always
-- lies strictly inside for a CCW simple polygon and avoids the boundary-
-- aliasing issue that vertex-based sampling causes when polygons share
-- vertices (e.g. faces of a planar arrangement).
local EPS = 1e-9
local function interiorSample(poly: { Vector2 }): Vector2
	local n = #poly
	for i = 1, n do
		local a = poly[i]
		local b = poly[(i % n) + 1]
		local edge = b - a
		if edge.Magnitude < EPS then
			continue
		end
		local mid = (a + b) * 0.5
		local inward = Vector2.new(-edge.Y, edge.X).Unit
		for step = 1, 8 do
			local pt = mid + inward * (1e-5 * 4 ^ (step - 1))
			if pointInPolygon(pt, poly) then
				return pt
			end
		end
	end
	local cx, cy = 0, 0
	for _, p in poly do
		cx += p.X
		cy += p.Y
	end
	return Vector2.new(cx / n, cy / n)
end

local function classify(polys: { { Vector2 } }): { PolygonWithHoles }
	local n = #polys
	if n == 0 then
		return {}
	end

	local ccw: { { Vector2 } } = {}
	local areas: { number } = {}
	local samples: { Vector2 } = {}
	for i = 1, n do
		ccw[i] = PolygonInset.ensureCCW(polys[i])
		areas[i] = math.abs(PolygonInset.signedArea(ccw[i]))
		samples[i] = interiorSample(ccw[i])
	end

	local containedBy: { { number } } = {}
	for i = 1, n do
		containedBy[i] = {}
	end

	for i = 1, n do
		local samplePt = samples[i]
		for j = 1, n do
			if i == j then
				continue
			end
			if pointInPolygon(samplePt, ccw[j]) then
				table.insert(containedBy[i], j)
			end
		end
	end

	local regions: { PolygonWithHoles } = {}
	local regionByIdx: { [number]: number } = {} -- outer poly index → region index

	for i = 1, n do
		if #containedBy[i] % 2 == 0 then
			table.insert(regions, { outer = ccw[i], holes = {} })
			regionByIdx[i] = #regions
		end
	end

	for i = 1, n do
		local depth = #containedBy[i]
		if depth % 2 ~= 1 then
			continue
		end
		-- Find smallest-area ancestor at depth-1 (= immediate enclosing outer)
		local bestParent: number? = nil
		local bestArea = math.huge
		for _, parentIdx in containedBy[i] do
			if #containedBy[parentIdx] == depth - 1 then
				if areas[parentIdx] < bestArea then
					bestArea = areas[parentIdx]
					bestParent = parentIdx
				end
			end
		end
		if bestParent and regionByIdx[bestParent] then
			table.insert(regions[regionByIdx[bestParent]].holes, ccw[i])
		end
	end

	return regions
end

return {
	classify = classify,
	pointInPolygon = pointInPolygon,
	interiorSample = interiorSample,
}
