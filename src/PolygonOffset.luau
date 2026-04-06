--!strict

-- Robust polygon offset with self-intersection resolution.
--
-- 1. Compute raw bisector offset (same vertex-movement as PolygonInset)
-- 2. Detect all edge-edge self-intersections in the raw offset
-- 3. Split edges at intersection points → directed planar graph
-- 4. Extract minimal faces via leftmost-turn (CW-from-reverse) walking
-- 5. Keep only CCW faces whose interior lies inside the original polygon
--
-- Returns zero or more simple CCW polygons representing valid offset regions.

local PolygonInset = require(script.Parent.PolygonInset)

local EPS = 1e-9
local SEG_MARGIN = 1e-6
local MITER_LIMIT = 2.0 -- max ratio of bisector distance to offset distance
local AREA_EPS = 1e-8
local NODE_SNAP = 1e5 -- 5 decimal places for node deduplication

--------------------------------------------------------------------------------
-- 2-D helpers
--------------------------------------------------------------------------------

local function dirAngle(d: Vector2): number
	return math.atan2(d.Y, d.X)
end

local function normalizeAngle(a: number): number
	while a > math.pi do
		a -= 2 * math.pi
	end
	while a <= -math.pi do
		a += 2 * math.pi
	end
	return a
end

--- Point-in-polygon via ray casting.
local function pointInPolygon(point: Vector2, poly: { Vector2 }): boolean
	local n = #poly
	local inside = false
	local j = n
	for i = 1, n do
		local pi = poly[i]
		local pj = poly[j]
		if (pi.Y > point.Y) ~= (pj.Y > point.Y) then
			local xHit = pi.X + (point.Y - pi.Y) / (pj.Y - pi.Y) * (pj.X - pi.X)
			if point.X < xHit then
				inside = not inside
			end
		end
		j = i
	end
	return inside
end

--- Segment-segment intersection (interior only, excludes endpoints).
local function segSegIntersect(
	p1: Vector2,
	p2: Vector2,
	p3: Vector2,
	p4: Vector2
): (number?, number?, Vector2?)
	local d1 = p2 - p1
	local d2 = p4 - p3
	local denom = d1.X * d2.Y - d1.Y * d2.X
	if math.abs(denom) < EPS then
		return nil, nil, nil
	end
	local dp = p3 - p1
	local t = (dp.X * d2.Y - dp.Y * d2.X) / denom
	local u = (dp.X * d1.Y - dp.Y * d1.X) / denom
	if t > SEG_MARGIN and t < 1 - SEG_MARGIN and u > SEG_MARGIN and u < 1 - SEG_MARGIN then
		return t, u, p1 + d1 * t
	end
	return nil, nil, nil
end

--- Sample a point that is inside a simple polygon.
local function sampleInteriorPoint(poly: { Vector2 }): Vector2
	local n = #poly
	local cx, cy = 0, 0
	for _, p in poly do
		cx += p.X
		cy += p.Y
	end
	local centroid = Vector2.new(cx / n, cy / n)
	if pointInPolygon(centroid, poly) then
		return centroid
	end
	for i = 1, n do
		local a = poly[i]
		local b = poly[(i % n) + 1]
		local mid = (a + b) * 0.5
		local edge = b - a
		if edge.Magnitude > EPS then
			local inward = Vector2.new(-edge.Y, edge.X).Unit * 1e-4
			local pt = mid + inward
			if pointInPolygon(pt, poly) then
				return pt
			end
			pt = mid - inward
			if pointInPolygon(pt, poly) then
				return pt
			end
		end
	end
	return centroid
end

--------------------------------------------------------------------------------
-- Raw bisector offset
--------------------------------------------------------------------------------

local function rawOffset(poly: { Vector2 }, distance: number): { Vector2 }
	local ccw = PolygonInset.ensureCCW(poly)
	local n = #ccw
	local result: { Vector2 } = {}

	for i = 1, n do
		local prev = ccw[((i - 2) % n) + 1]
		local curr = ccw[i]
		local nxt = ccw[(i % n) + 1]

		local ePrev = curr - prev
		local eNext = nxt - curr
		if ePrev.Magnitude < EPS then
			ePrev = eNext
		end
		if eNext.Magnitude < EPS then
			eNext = ePrev
		end
		if ePrev.Magnitude < EPS then
			table.insert(result, curr)
			continue
		end
		ePrev = ePrev.Unit
		eNext = eNext.Unit

		local nPrev = Vector2.new(-ePrev.Y, ePrev.X)
		local nNext = Vector2.new(-eNext.Y, eNext.X)

		local bisector = nPrev + nNext
		local bisectorLen = bisector.Magnitude
		if bisectorLen < 1e-6 then
			table.insert(result, curr + nPrev * distance)
			continue
		end
		bisector = bisector / bisectorLen

		local dot = bisector:Dot(nPrev)
		if dot < 1e-6 or (1 / dot) > MITER_LIMIT then
			local cross = ePrev.X * eNext.Y - ePrev.Y * eNext.X
			if cross < 0 then
				-- Concave sharp vertex: bevel replaces spike into notch
				table.insert(result, curr + nPrev * distance)
				table.insert(result, curr + nNext * distance)
			else
				-- Convex sharp vertex: clamp miter length
				table.insert(result, curr + bisector * (distance * MITER_LIMIT))
			end
		else
			table.insert(result, curr + bisector * (distance / dot))
		end
	end

	return result
end

--------------------------------------------------------------------------------
-- Self-intersection resolution via planar-graph face extraction
--------------------------------------------------------------------------------

local function offset(originalPoly: { Vector2 }, distance: number): { { Vector2 } }
	local ccwOrig = PolygonInset.ensureCCW(originalPoly)
	local raw = rawOffset(ccwOrig, distance)
	local n = #raw

	if n < 3 then
		return {}
	end

	-- 1. Find all self-intersections -------------------------------------------
	type Isect = {
		edgeA: number,
		edgeB: number,
		tA: number,
		tB: number,
		point: Vector2,
	}
	local isects: { Isect } = {}

	for i = 1, n do
		local i2 = (i % n) + 1
		for j = i + 2, n do
			if i == 1 and j == n then
				continue
			end
			local j2 = (j % n) + 1
			local t, u, pt = segSegIntersect(raw[i], raw[i2], raw[j], raw[j2])
			if t and u and pt then
				table.insert(isects, {
					edgeA = i,
					edgeB = j,
					tA = t,
					tB = u,
					point = pt,
				})
			end
		end
	end

	-- No self-intersections: validate and return
	if #isects == 0 then
		local area = PolygonInset.signedArea(raw)
		if area > AREA_EPS then
			if distance <= 0 then
				return { raw }
			end
			local origArea = math.abs(PolygonInset.signedArea(ccwOrig))
			if area <= origArea + AREA_EPS then
				return { raw }
			end
		end
		return {}
	end

	-- 2. Split edges at intersections, build planar graph ----------------------
	local edgeSplits: { { { t: number, point: Vector2 } } } = {}
	for i = 1, n do
		edgeSplits[i] = {}
	end
	for _, ix in isects do
		table.insert(edgeSplits[ix.edgeA], { t = ix.tA, point = ix.point })
		table.insert(edgeSplits[ix.edgeB], { t = ix.tB, point = ix.point })
	end
	for i = 1, n do
		table.sort(edgeSplits[i], function(a, b)
			return a.t < b.t
		end)
	end

	-- Node management (deduplicated by snapped position)
	local nodes: { Vector2 } = {}
	local nodeIdx: { [string]: number } = {}

	local function nkey(p: Vector2): string
		return math.round(p.X * NODE_SNAP) .. "," .. math.round(p.Y * NODE_SNAP)
	end

	local function addNode(p: Vector2): number
		local k = nkey(p)
		if nodeIdx[k] then
			return nodeIdx[k]
		end
		table.insert(nodes, p)
		nodeIdx[k] = #nodes
		return #nodes
	end

	for i = 1, n do
		addNode(raw[i])
	end
	for _, ix in isects do
		addNode(ix.point)
	end

	-- Directed edges (forward from the polygon + reverse for DCEL completeness)
	type DirEdge = { from: number, to: number }
	local dirEdges: { DirEdge } = {}
	local outgoing: { { number } } = {}
	for i = 1, #nodes do
		outgoing[i] = {}
	end

	local function addDirEdge(from: number, to: number)
		if from == to then
			return
		end
		local eIdx = #dirEdges + 1
		table.insert(dirEdges, { from = from, to = to })
		table.insert(outgoing[from], eIdx)
	end

	for i = 1, n do
		local i2 = (i % n) + 1
		local from = addNode(raw[i])
		for _, sp in edgeSplits[i] do
			local to = addNode(sp.point)
			addDirEdge(from, to)
			addDirEdge(to, from) -- reverse
			from = to
		end
		local to = addNode(raw[i2])
		addDirEdge(from, to)
		addDirEdge(to, from) -- reverse
	end

	-- Sort outgoing edges by angle at each node
	for ni = 1, #nodes do
		table.sort(outgoing[ni], function(a, b)
			local da = nodes[dirEdges[a].to] - nodes[ni]
			local db = nodes[dirEdges[b].to] - nodes[ni]
			return dirAngle(da) < dirAngle(db)
		end)
	end

	-- 3. DCEL face extraction via leftmost turn (first edge CW from reverse) ---
	local function findNext(eIdx: number): number?
		local e = dirEdges[eIdx]
		local v = e.to
		local outs = outgoing[v]
		if #outs == 0 then
			return nil
		end
		if #outs == 1 then
			return outs[1]
		end

		local inDir = nodes[v] - nodes[e.from]
		local revAngle = normalizeAngle(dirAngle(inDir) + math.pi)

		local best: number = outs[#outs]
		for k = #outs, 1, -1 do
			local cand = outs[k]
			local candAngle = dirAngle(nodes[dirEdges[cand].to] - nodes[v])
			if candAngle < revAngle - 1e-9 then
				best = cand
				break
			end
		end
		return best
	end

	local edgeUsed: { [number]: boolean } = {}
	local cycles: { { number } } = {}

	for startEIdx = 1, #dirEdges do
		if edgeUsed[startEIdx] then
			continue
		end

		local cycle: { number } = {}
		local curEIdx: number = startEIdx
		local valid = true
		local maxSteps = #dirEdges + 1

		for _ = 1, maxSteps do
			if edgeUsed[curEIdx] then
				if curEIdx == startEIdx then
					break
				end
				valid = false
				break
			end
			edgeUsed[curEIdx] = true
			table.insert(cycle, dirEdges[curEIdx].from)

			local nxt = findNext(curEIdx)
			if not nxt then
				valid = false
				break
			end
			curEIdx = nxt
		end

		if valid and #cycle >= 3 then
			table.insert(cycles, cycle)
		end
	end

	-- 4. Filter: positive area + interior inside original polygon ---------------
	local origArea = math.abs(PolygonInset.signedArea(ccwOrig))
	local result: { { Vector2 } } = {}

	for _, cycle in cycles do
		local poly: { Vector2 } = {}
		for _, ni in cycle do
			table.insert(poly, nodes[ni])
		end

		local area = PolygonInset.signedArea(poly)
		if area <= AREA_EPS then
			continue
		end

		-- Reject tiny fragments at sharp tips (smaller than a 2×distance square)
		local minArea = distance * distance * 4
		if area < minArea then
			continue
		end

		-- Reject inset cycles whose area exceeds the original (inverted tiny regions)
		if distance > 0 and area > origArea + AREA_EPS then
			continue
		end

		if distance > 0 then
			local sample = sampleInteriorPoint(poly)
			if not pointInPolygon(sample, ccwOrig) then
				continue
			end
		end

		table.insert(result, poly)
	end

	return result
end

return {
	offset = offset,
	rawOffset = rawOffset,
	pointInPolygon = pointInPolygon,
	segSegIntersect = segSegIntersect,
}
