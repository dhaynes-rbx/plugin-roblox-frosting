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
local PolygonNesting = require(script.Parent.PolygonNesting)

export type PolygonWithHoles = PolygonNesting.PolygonWithHoles

local EPS = 1e-9
local SEG_MARGIN = 1e-6
-- Convex-miter clamp only.  Reflex vertices use a larger clamp (REFLEX_MITER)
-- because the true reflex offset point (meet of parallel-offset edges) lies
-- deep inside the polygon and a 2x convex clamp would wrongly chop reflex
-- pockets, leaving geometrically spurious "extra material" that extracts as
-- a separate region (Phase 1: SharpChevron L0 F5/F10, Star L6 F10).
local MITER_LIMIT = 2.0
local REFLEX_MITER = 50.0

-- Unified tolerance model: every length-scale threshold below is derived from
-- the polygon's own bbox diagonal so that small stacked caps (ScaleSweep 0.5×
-- after several layers) dedup at the same RELATIVE grid as large cookies.
-- See src/PolygonInset.luau for the matching BASE_EPS_RATIO so that node
-- dedup, pre-weld, pinch-split, and T-junction checks all agree on distance.
local BASE_EPS_RATIO = 1e-5
local MIN_EPS = 1e-9

local function bboxDiag(poly: { Vector2 }): number
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	for _, p in poly do
		if p.X < minX then minX = p.X end
		if p.X > maxX then maxX = p.X end
		if p.Y < minY then minY = p.Y end
		if p.Y > maxY then maxY = p.Y end
	end
	local dx, dy = maxX - minX, maxY - minY
	return math.sqrt(dx * dx + dy * dy)
end

local function computeEps(poly: { Vector2 }): number
	return math.max(bboxDiag(poly) * BASE_EPS_RATIO, MIN_EPS)
end

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

--- Perpendicular distance from `p` to the segment (a, b), plus the clamped
--- parameter t along (a, b) at the closest point.  Used for vertex-on-edge
--- detection (T-junction recovery in arrangementSubtract).
local function pointSegmentDistance(p: Vector2, a: Vector2, b: Vector2): (number, number)
	local ab = b - a
	local lenSq = ab.X * ab.X + ab.Y * ab.Y
	if lenSq < EPS then
		return (p - a).Magnitude, 0
	end
	local t = ((p - a):Dot(ab)) / lenSq
	t = math.clamp(t, 0, 1)
	local closest = a + ab * t
	return (p - closest).Magnitude, t
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
	-- Scale the inward nudge with the polygon's own size so sampling works
	-- for both tiny stacked caps and large cookies.
	local nudge = computeEps(poly) * 10
	for i = 1, n do
		local a = poly[i]
		local b = poly[(i % n) + 1]
		local mid = (a + b) * 0.5
		local edge = b - a
		if edge.Magnitude > EPS then
			local inward = Vector2.new(-edge.Y, edge.X).Unit * nudge
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
		local cross = ePrev.X * eNext.Y - ePrev.Y * eNext.X
		local reflex = cross < 0
		if reflex then
			-- Reflex: always use a single bisector-miter point at the intersection
			-- of the two parallel-offset edges.  Bevelling here would chord
			-- across a reflex pocket far inside the true offset curve, leaving
			-- a sliver of material that extracts as a spurious region (Phase 1:
			-- SharpChevron L0 F5/F10).  Clamp only to REFLEX_MITER for numerical
			-- safety at near-degenerate sharp reflexes.
			if dot < 1e-6 or (1 / dot) > REFLEX_MITER then
				table.insert(result, curr + bisector * (distance * REFLEX_MITER))
			else
				table.insert(result, curr + bisector * (distance / dot))
			end
		elseif dot < 1e-6 or (1 / dot) > MITER_LIMIT then
			-- Convex spike sharper than MITER_LIMIT: BEVEL with two points each
			-- at perpendicular `distance` from its adjacent edge.  Using a
			-- single bisector-clamped point produces a geometrically invalid
			-- corner whose offset edges don't meet at a true parallel-offset
			-- intersection, leading to over-growth when the polygon is on the
			-- verge of splitting (Phase 1: Star L6->L7 5-region explosion).
			table.insert(result, curr + nPrev * distance)
			table.insert(result, curr + nNext * distance)
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

	-- Per-call tolerance.  The raw offset can produce vertices separated by
	-- O(EPS) for near-parallel reflex pairs; we need node dedup and AREA_EPS
	-- both to work at that scale regardless of the original cookie size.
	local callEps = computeEps(ccwOrig)
	local NODE_SNAP = 1 / callEps
	local AREA_EPS = callEps * callEps

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

	-- 4. Filter: positive area + full geometric containment in original --------
	--
	-- For an INWARD offset (distance > 0) the entire output polygon must lie
	-- inside the original.  We therefore reject any cycle that
	--   (a) has non-positive signed area,
	--   (b) has area below the minimum-fragment threshold,
	--   (c) has area greater than the original (spurious inverted rings),
	--   (d) has an interior sample outside the original, OR
	--   (e) has any vertex outside the original.
	--
	-- Check (e) catches the case where a narrow wall collapses: the two
	-- parallel-offset edges cross, producing an inverted cycle whose centroid
	-- lands inside the original but whose extreme vertices poke OUTSIDE the
	-- original boundary (Phase 1: U-Shape L6 F3 bbox overshoot).  An
	-- interior-only sample is not enough to flag this; vertex-level containment
	-- is.
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

		if distance > 0 then
			local minArea = distance * distance * 4
			if area < minArea then
				continue
			end
		end

		if distance > 0 and area > origArea + AREA_EPS then
			continue
		end

		if distance > 0 then
			local sample = sampleInteriorPoint(poly)
			if not pointInPolygon(sample, ccwOrig) then
				continue
			end
			-- Vertex-level containment: for an inward offset, every vertex of
			-- the cycle should lie inside the original polygon.  Boundary slop
			-- is absorbed by NODE_SNAP; a vertex that lies strictly outside the
			-- original boundary is geometrically invalid.
			local allIn = true
			for _, v in poly do
				if not pointInPolygon(v, ccwOrig) then
					allIn = false
					break
				end
			end
			if not allIn then
				continue
			end
		end

		table.insert(result, poly)
	end

	-- Fallback: when the standard DCEL produces no results but there are
	-- self-intersections, the polygon likely has thin features that invert
	-- without creating proper crossings (inverted edges share endpoints
	-- instead of crossing).  Fix by computing the intersection of the raw
	-- offset with the original polygon: build a combined planar graph from
	-- both edge sets, extract faces, and keep faces inside both polygons.
	if #result == 0 and #isects > 0 and distance > 0 then
		local allNodes: { Vector2 } = {}
		local allNodeIdx: { [string]: number } = {}
		local function nkey2(p: Vector2): string
			return math.round(p.X * NODE_SNAP) .. "," .. math.round(p.Y * NODE_SNAP)
		end
		local function addNode2(p: Vector2): number
			local k = nkey2(p)
			if allNodeIdx[k] then return allNodeIdx[k] end
			table.insert(allNodes, p)
			allNodeIdx[k] = #allNodes
			return #allNodes
		end

		-- Collect edges from both polygons
		type PolyEdge = { p1: Vector2, p2: Vector2 }
		local polyEdges: { PolyEdge } = {}
		for i = 1, #raw do
			table.insert(polyEdges, { p1 = raw[i], p2 = raw[(i % #raw) + 1] })
		end
		for i = 1, #ccwOrig do
			table.insert(polyEdges, { p1 = ccwOrig[i], p2 = ccwOrig[(i % #ccwOrig) + 1] })
		end

		-- Find all intersections between edges
		type SplitInfo = { { t: number, point: Vector2 } }
		local eSplits: { SplitInfo } = {}
		for i = 1, #polyEdges do eSplits[i] = {} end

		for i = 1, #polyEdges - 1 do
			for j = i + 1, #polyEdges do
				-- Skip adjacent edges within the same polygon
				local sameOrig = (i > #raw) == (j > #raw)
				if sameOrig then
					local len = if i <= #raw then #raw else #ccwOrig
					local base = if i <= #raw then 0 else #raw
					local ei = i - base
					local ej = j - base
					if ej - ei == 1 then continue end
					if ei == 1 and ej == len then continue end
				end

				local t, u, pt = segSegIntersect(
					polyEdges[i].p1, polyEdges[i].p2,
					polyEdges[j].p1, polyEdges[j].p2
				)
				if t and u and pt then
					table.insert(eSplits[i], { t = t, point = pt })
					table.insert(eSplits[j], { t = u, point = pt })
				end
			end
		end

		for i = 1, #polyEdges do
			table.sort(eSplits[i], function(a, b) return a.t < b.t end)
		end

		-- Add all vertices and intersection points as nodes
		for _, pe in polyEdges do addNode2(pe.p1) end
		for _, sp in eSplits do
			for _, s in sp do addNode2(s.point) end
		end

		-- Build directed edge graph
		type DirEdge2 = { from: number, to: number }
		local de2: { DirEdge2 } = {}
		local out2: { { number } } = {}
		for i = 1, #allNodes do out2[i] = {} end

		local function addDE2(from: number, to: number)
			if from == to then return end
			table.insert(de2, { from = from, to = to })
			table.insert(out2[from], #de2)
		end

		for ei, pe in polyEdges do
			local from = addNode2(pe.p1)
			for _, sp in eSplits[ei] do
				local to = addNode2(sp.point)
				addDE2(from, to); addDE2(to, from)
				from = to
			end
			local to = addNode2(pe.p2)
			addDE2(from, to); addDE2(to, from)
		end

		-- Sort outgoing edges by angle
		for ni = 1, #allNodes do
			table.sort(out2[ni], function(a, b)
				local da = allNodes[de2[a].to] - allNodes[ni]
				local db = allNodes[de2[b].to] - allNodes[ni]
				return dirAngle(da) < dirAngle(db)
			end)
		end

		-- Leftmost-turn face extraction
		local function findNext2(eIdx: number): number?
			local e = de2[eIdx]
			local v = e.to
			local outs = out2[v]
			if #outs == 0 then return nil end
			if #outs == 1 then return outs[1] end
			local inDir = allNodes[v] - allNodes[e.from]
			local revAngle = normalizeAngle(dirAngle(inDir) + math.pi)
			local best: number = outs[#outs]
			for k = #outs, 1, -1 do
				local cand = outs[k]
				local candAngle = dirAngle(allNodes[de2[cand].to] - allNodes[v])
				if candAngle < revAngle - 1e-9 then
					best = cand; break
				end
			end
			return best
		end

		local used2: { [number]: boolean } = {}
		local cycles2: { { number } } = {}
		for startE = 1, #de2 do
			if used2[startE] then continue end
			local cyc: { number } = {}
			local cur = startE
			local ok2 = true
			for _ = 1, #de2 + 1 do
				if used2[cur] then
					if cur == startE then break end
					ok2 = false; break
				end
				used2[cur] = true
				table.insert(cyc, de2[cur].from)
				local nxt = findNext2(cur)
				if not nxt then ok2 = false; break end
				cur = nxt
			end
			if ok2 and #cyc >= 3 then table.insert(cycles2, cyc) end
		end

		-- Keep faces that are properly inset: inside the original, with
		-- enough area, and compact enough to represent genuine inset
		-- regions (not thin channel strips from collapsed teeth).
		-- The area/perimeter ratio filters thin strips: a strip of width w
		-- has ratio ≈ w/2, while compact shapes have ratio ≈ min_dim/4+.
		for _, cyc in cycles2 do
			local poly: { Vector2 } = {}
			for _, ni in cyc do table.insert(poly, allNodes[ni]) end
			local area = PolygonInset.signedArea(poly)
			if area <= AREA_EPS then continue end
			if area > origArea + AREA_EPS then continue end
			local minArea = distance * distance * 4
			if area < minArea then continue end
			local sample = sampleInteriorPoint(poly)
			if not pointInPolygon(sample, ccwOrig) then continue end
			local perimeter = 0.0
			local np = #poly
			for i = 1, np do
				perimeter += (poly[(i % np) + 1] - poly[i]).Magnitude
			end
			if perimeter > 0 and area / perimeter < distance then continue end
			-- Collapse small bumps created by original-boundary edges in the
			-- DCEL.  A bump vertex is one whose perpendicular distance to the
			-- line connecting its neighbors is less than the inset distance.
			local changed = true
			while changed do
				changed = false
				local cleaned: { Vector2 } = {}
				local m = #poly
				for i = 1, m do
					local prev = poly[((i - 2) % m) + 1]
					local cur = poly[i]
					local nxt = poly[(i % m) + 1]
					local baseLen = (nxt - prev).Magnitude
					if baseLen > AREA_EPS then
						local cross = math.abs(
							(cur.X - prev.X) * (nxt.Y - prev.Y)
							- (nxt.X - prev.X) * (cur.Y - prev.Y)
						)
						local height = cross / baseLen
						if height < distance then
							changed = true
							continue
						end
					end
					table.insert(cleaned, cur)
				end
				if #cleaned >= 3 then
					poly = cleaned
				else
					break
				end
			end
			table.insert(result, poly)
		end
	end

	return result
end

--------------------------------------------------------------------------------
-- Arrangement-based subtraction: outer ∖ (∪ holes) as polygon-with-holes
--
-- Given an already-simple CCW outer polygon and a list of simple CCW hole
-- polygons (possibly overlapping each other, possibly partially outside the
-- outer), compute the difference as a list of PolygonWithHoles regions.
--
-- The algorithm reuses the DCEL face extraction machinery above:
--   1. Collect every edge of outer + every hole as a labeled edge.
--   2. Split edges at all mutual intersections.
--   3. Build a planar graph with bidirectional edges.
--   4. Extract minimal CCW faces via leftmost-turn.
--   5. Keep faces whose sample point is inside `outerInset` AND outside every
--      hole in `holeOutsets`.  This is the exact characterization of
--      (outer ∖ ∪holes) since faces are bounded only by input edges.
--   6. Classify kept faces by even/odd containment nesting using PolygonNesting
--      to recover {outer, holes} regions.
--------------------------------------------------------------------------------

local function arrangementSubtract(
	outerInset: { Vector2 },
	holeOutsets: { { Vector2 } }
): { PolygonNesting.PolygonWithHoles }
	-- Per-call tolerance (see `offset` above).
	local callEps = computeEps(outerInset)
	local NODE_SNAP = 1 / callEps
	local AREA_EPS = callEps * callEps

	type Loop = { pts: { Vector2 } }
	local loops: { Loop } = { { pts = outerInset } }
	for _, h in holeOutsets do
		table.insert(loops, { pts = h })
	end

	type EdgeRef = { loopIdx: number, edgeIdx: number }
	local edgeRefs: { EdgeRef } = {}
	for li, loop in loops do
		for ei = 1, #loop.pts do
			table.insert(edgeRefs, { loopIdx = li, edgeIdx = ei })
		end
	end

	-- 1-2. Find all edge-edge intersections (skip adjacent edges within same loop)
	type Isect = {
		refA: number,
		refB: number,
		tA: number,
		tB: number,
		point: Vector2,
	}
	local isects: { Isect } = {}

	for aIdx = 1, #edgeRefs - 1 do
		local a = edgeRefs[aIdx]
		local aLoop = loops[a.loopIdx]
		local aN = #aLoop.pts
		local aP1 = aLoop.pts[a.edgeIdx]
		local aP2 = aLoop.pts[(a.edgeIdx % aN) + 1]

		for bIdx = aIdx + 1, #edgeRefs do
			local b = edgeRefs[bIdx]

			-- Skip adjacent edges within the same loop
			if a.loopIdx == b.loopIdx then
				if b.edgeIdx - a.edgeIdx == 1 then
					continue
				end
				if a.edgeIdx == 1 and b.edgeIdx == aN then
					continue
				end
			end

			local bLoop = loops[b.loopIdx]
			local bN = #bLoop.pts
			local bP1 = bLoop.pts[b.edgeIdx]
			local bP2 = bLoop.pts[(b.edgeIdx % bN) + 1]

			local t, u, pt = segSegIntersect(aP1, aP2, bP1, bP2)
			if t and u and pt then
				table.insert(isects, {
					refA = aIdx,
					refB = bIdx,
					tA = t,
					tB = u,
					point = pt,
				})
			end
		end
	end

	-- T-junction recovery: a vertex of loop A may lie exactly on the interior of
	-- an edge of loop B without producing a segSegIntersect hit (t=0 falls outside
	-- the open interval).  Add an explicit intersection at each such vertex so
	-- the planar graph is topologically sound.  Phase 1 flagged this as the
	-- root cause of Maze L1 hole loss after mesh round-trip: slightly-jittered
	-- slit vertices landed on adjacent slit edges and the arrangement left them
	-- unsplit, which in turn caused the face-classification fast path to
	-- misclassify the central cell.
	-- T-junction tolerance: must be at least as loose as the downstream
	-- earClipTriangulate/resolveTJunctions tolerance (also 2*eps) so the
	-- arrangement and the ear-clip agree on which T-contacts are real.
	local T_TOL = callEps * 2
	for aIdx, a in edgeRefs do
		local aLoop = loops[a.loopIdx]
		local aN = #aLoop.pts
		local aP1 = aLoop.pts[a.edgeIdx]
		local aP2 = aLoop.pts[(a.edgeIdx % aN) + 1]
		for _, bRef in edgeRefs do
			-- For each loop OTHER than a, test each of its vertices against this edge.
			if bRef.loopIdx == a.loopIdx then continue end
			local bLoop = loops[bRef.loopIdx]
			local vIdx = bRef.edgeIdx
			local v = bLoop.pts[vIdx]
			local d, t = pointSegmentDistance(v, aP1, aP2)
			if d < T_TOL and t > SEG_MARGIN and t < 1 - SEG_MARGIN then
				-- Record as intersection on `a` only; the vertex `v` is already a
				-- node of loop B so no split is needed on the B side.  We synthesise
				-- a paired split on B at t=0 of its next edge so the node IDs match.
				-- (We push it directly through as an "external" isect with a
				-- zero-length split on the other side.)
				table.insert(isects, {
					refA = aIdx,
					refB = 0, -- sentinel: no b-side split needed
					tA = t,
					tB = 0,
					point = v,
				})
			end
		end
	end

	-- Fast path: no crossings.  With disjoint loops, each hole is either fully
	-- inside the outer, fully outside, or fully-containing it.  Testing
	-- containment via vertex 0 (a point on the outer boundary) is
	-- topologically sound in this regime because a strictly-contained hole
	-- cannot contain the outer's boundary.
	if #isects == 0 then
		for _, h in holeOutsets do
			if pointInPolygon(outerInset[1], h) then
				return {}
			end
		end
		local pwh: PolygonNesting.PolygonWithHoles = {
			outer = PolygonInset.ensureCCW(outerInset),
			holes = {},
		}
		for hi, h in holeOutsets do
			local sample = sampleInteriorPoint(h)
			if not pointInPolygon(sample, outerInset) then
				continue
			end
			local insideAnother = false
			for hj, oh in holeOutsets do
				if hi == hj then
					continue
				end
				if pointInPolygon(sample, oh) then
					insideAnother = true
					break
				end
			end
			if not insideAnother then
				table.insert(pwh.holes, PolygonInset.ensureCCW(h))
			end
		end
		return { pwh }
	end

	-- 3. Planar graph with node dedup
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

	for _, loop in loops do
		for _, p in loop.pts do
			addNode(p)
		end
	end
	for _, ix in isects do
		addNode(ix.point)
	end

	local edgeSplits: { { { t: number, point: Vector2 } } } = {}
	for i = 1, #edgeRefs do
		edgeSplits[i] = {}
	end
	for _, ix in isects do
		table.insert(edgeSplits[ix.refA], { t = ix.tA, point = ix.point })
		if ix.refB ~= 0 then
			table.insert(edgeSplits[ix.refB], { t = ix.tB, point = ix.point })
		end
	end
	for i = 1, #edgeRefs do
		table.sort(edgeSplits[i], function(a, b)
			return a.t < b.t
		end)
	end

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
		table.insert(dirEdges, { from = from, to = to })
		table.insert(outgoing[from], #dirEdges)
	end

	for aIdx, ref in edgeRefs do
		local loop = loops[ref.loopIdx]
		local n = #loop.pts
		local p1 = loop.pts[ref.edgeIdx]
		local p2 = loop.pts[(ref.edgeIdx % n) + 1]
		local from = addNode(p1)
		for _, sp in edgeSplits[aIdx] do
			local to = addNode(sp.point)
			addDirEdge(from, to)
			addDirEdge(to, from)
			from = to
		end
		local to = addNode(p2)
		addDirEdge(from, to)
		addDirEdge(to, from)
	end

	for ni = 1, #nodes do
		table.sort(outgoing[ni], function(a, b)
			local da = nodes[dirEdges[a].to] - nodes[ni]
			local db = nodes[dirEdges[b].to] - nodes[ni]
			return dirAngle(da) < dirAngle(db)
		end)
	end

	-- 4. Leftmost-turn face extraction
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

	-- 5. Classify each cycle as KEEP / DROP by sampling a point on the LEFT of
	--    one of its directed edges — that point lies inside the face whose
	--    boundary component this cycle traces.  A face is KEEP iff its
	--    interior point lies inside outerInset AND outside every holeOutset.
	--
	-- leftmost-turn gives one cycle per face boundary component, with the
	-- face on the LEFT of every edge.  So:
	--   CCW cycle (positive area) = outer boundary of a face (bounded)
	--   CW  cycle (negative area) = inner boundary of a face with holes,
	--                               OR the outer boundary of the unbounded
	--                               outside face (traversed CW as viewed from
	--                               outside).
	--
	-- We collect ALL KEEP cycles and then nest-classify them.
	-- Build the polygon from cycle, find its longest edge, step LEFT of it.
	-- Left-of-edge lies inside the face this cycle bounds (leftmost-turn gives
	-- face on the left), and a tiny step from the midpoint of the LONGEST edge
	-- is safely inside (sharp corners of short edges can land outside).
	local function leftSamplePoint(cycle: { number }): Vector2?
		local n = #cycle
		-- Find longest edge
		local bestLen = 0.0
		local bestI = 0
		for i = 1, n do
			local a = nodes[cycle[i]]
			local b = nodes[cycle[(i % n) + 1]]
			local len = (b - a).Magnitude
			if len > bestLen then
				bestLen = len
				bestI = i
			end
		end
		if bestI == 0 then
			return nil
		end
		local a = nodes[cycle[bestI]]
		local b = nodes[cycle[(bestI % n) + 1]]
		local edge = b - a
		local len = edge.Magnitude
		local left = Vector2.new(-edge.Y, edge.X) / len
		local mid = (a + b) * 0.5
		-- Step by a small fraction of the edge length (bounded by per-call
		-- eps so large polygons don't sample on top of their boundary).
		local stepLen = math.min(len * 0.01, callEps * 10)
		return mid + left * stepLen
	end

	local keepCyclesCCW: { { Vector2 } } = {}
	local keepCyclesCW: { { Vector2 } } = {} -- holes of KEEP faces, stored as CCW (reversed)

	for _, cycle in cycles do
		local poly: { Vector2 } = {}
		for _, ni in cycle do
			table.insert(poly, nodes[ni])
		end
		local area = PolygonInset.signedArea(poly)
		if math.abs(area) <= AREA_EPS then
			continue
		end

		local sample = leftSamplePoint(cycle)
		if not sample then
			continue
		end

		-- KEEP test: face interior (on left of each edge) is inside
		-- outerInset AND outside all holeOutsets.
		if not pointInPolygon(sample, outerInset) then
			continue
		end
		local inAnyHole = false
		for _, h in holeOutsets do
			if pointInPolygon(sample, h) then
				inAnyHole = true
				break
			end
		end
		if inAnyHole then
			continue
		end

		if area > 0 then
			table.insert(keepCyclesCCW, poly)
		else
			-- CW cycle of a KEEP face = inner boundary (hole of that face)
			local rev: { Vector2 } = {}
			for i = #poly, 1, -1 do
				table.insert(rev, poly[i])
			end
			table.insert(keepCyclesCW, rev)
		end
	end

	-- 6. Pair CCW outers with CW-derived holes by containment.
	--    Each hole-turned-CCW is the inner boundary of exactly one KEEP outer.
	local result: { PolygonNesting.PolygonWithHoles } = {}
	for _, outer in keepCyclesCCW do
		table.insert(result, { outer = outer, holes = {} })
	end

	for _, hole in keepCyclesCW do
		local sample = PolygonNesting.interiorSample(hole)
		local bestIdx: number? = nil
		local bestArea = math.huge
		for ri, region in result do
			if pointInPolygon(sample, region.outer) then
				local a = math.abs(PolygonInset.signedArea(region.outer))
				if a < bestArea then
					bestArea = a
					bestIdx = ri
				end
			end
		end
		if bestIdx then
			-- Hole was extracted as CW → we reversed to CCW.  Keep as CCW so
			-- downstream classify/triangulation treats it uniformly.
			table.insert(result[bestIdx].holes, hole)
		end
	end

	return result
end


--------------------------------------------------------------------------------
-- Polygon-with-holes inward offset (Clipper-style erosion)
--
-- Treat the input as a polygon with holes.  An inward offset by `distance`:
--   1. Insets the outer boundary (possibly splitting it into disjoint pieces)
--   2. Grows each hole (possibly merging, possibly engulfing the outer)
-- The result is zero or more disjoint PolygonWithHoles regions.
--
-- Pipeline:
--   outerInsets     = offset(outer, +distance)           -- simple CCW polys
--   allHoleOutsets  = ⋃ offset(hole, -distance) per hole -- simple CCW polys
--   for each outerInset:  arrangementSubtract(outerInset, allHoleOutsets)
--
-- This replaces the old per-loop offset / W-A union / intersection-clip
-- pipeline.  Because each step is either a single-loop offset (robust via
-- DCEL) or an arrangement-based subtraction (also DCEL-based), there is no
-- polygon-union dependency and no accumulation of merge errors.
--------------------------------------------------------------------------------

local HOLE_FRAGMENT_AREA_RATIO = 5e-3

--- Remove zero-width slit appendages left after splitting at bridge points.
--- When a polygon is split at a shared vertex, one sub-polygon may retain a
--- "slit" — a pair of collinear edges going out to the former bridge point
--- and back.  This function removes such slit-tip vertices (where adjacent
--- edges are anti-parallel) and consecutive duplicate vertices.
local function cleanSlitVertices(poly: { Vector2 }, eps: number): { Vector2 }
	local changed = true
	while changed do
		changed = false
		local n = #poly
		if n < 4 then
			break
		end
		local cleaned: { Vector2 } = {}
		for i = 1, n do
			local prev = poly[((i - 2) % n) + 1]
			local curr = poly[i]
			local nxt = poly[(i % n) + 1]
			if (curr - nxt).Magnitude < eps then
				changed = true
				continue
			end
			local d1 = curr - prev
			local d2 = nxt - curr
			local len1 = d1.Magnitude
			local len2 = d2.Magnitude
			if len1 < eps then
				table.insert(cleaned, curr)
				continue
			end
			local cross = d1.X * d2.Y - d1.Y * d2.X
			local dot = d1.X * d2.X + d1.Y * d2.Y
			if math.abs(cross) / (len1 * len2) < 0.01 and dot < 0 then
				changed = true
				continue
			end
			table.insert(cleaned, curr)
		end
		if #cleaned >= 3 then
			poly = cleaned
		else
			break
		end
	end
	return poly
end

--- Split a merged-hole boundary into individual hole loops at bridge pinch
--- points.  FrostingBuilder connects holes via zero-width bridges that
--- create near-coincident vertex pairs in the boundary.  This function
--- finds such pairs and splits the polygon at each, keeping only
--- sub-polygons with ≥ `minLoopVerts` vertices (individual hole loops).
--- Smaller sub-polygons (bridge junction artifacts) are discarded.
--- After splitting, slit appendages (from the bridge edges) are cleaned.
local function splitBridgedHole(
	poly: { Vector2 },
	threshold: number,
	minLoopVerts: number
): { { Vector2 } }
	local n = #poly
	if n < minLoopVerts * 2 then
		return { poly }
	end

	local bestDist = math.huge
	local bestI, bestJ = 0, 0
	for i = 1, n do
		for j = i + 2, n do
			if i == 1 and j == n then
				continue
			end
			local d = (poly[i] - poly[j]).Magnitude
			if d < threshold and d < bestDist then
				local fwd = j - i + 1
				local bwd = n - j + i + 1
				local small = math.min(fwd, bwd)
				if small >= minLoopVerts then
					bestDist = d
					bestI, bestJ = i, j
				end
			end
		end
	end

	if bestI == 0 then
		return { poly }
	end

	local sub1: { Vector2 } = {}
	for k = bestI, bestJ do
		table.insert(sub1, poly[k])
	end
	local sub2: { Vector2 } = {}
	for k = bestJ, n do
		table.insert(sub2, poly[k])
	end
	for k = 1, bestI do
		table.insert(sub2, poly[k])
	end

	local result: { { Vector2 } } = {}
	for _, subPoly in { sub1, sub2 } do
		local cleaned = cleanSlitVertices(subPoly, threshold)
		if #cleaned >= minLoopVerts then
			for _, p in splitBridgedHole(cleaned, threshold, minLoopVerts) do
				table.insert(result, p)
			end
		end
	end
	return if #result > 0 then result else { poly }
end

--- Collapse small diamond-shaped concavities at self-touching pinch points.
--- When the raw offset of a merged-hole boundary creates coincident vertices,
--- small loops (diamonds) form at each touch point.  This function removes
--- the intermediate vertices of loops with ≤ `maxLoopVerts` vertices and
--- merges the coincident pinch pair into a single vertex, eliminating the
--- concavity while preserving the polygon's overall topology.  Larger
--- self-touching loops (which connect hex hole sections to the center hole)
--- are left intact — the ear-clipper's own pinch-split handles those during
--- triangulation, correctly separating individual hole loops.
local function collapsePinchLoops(
	poly: { Vector2 },
	threshold: number,
	maxLoopVerts: number
): { Vector2 }
	local n = #poly
	if n < 6 then
		return poly
	end

	local removeSet: { [number]: boolean } = {}

	for i = 1, n do
		if removeSet[i] then
			continue
		end
		for j = i + 2, n do
			if removeSet[j] then
				continue
			end
			if i == 1 and j == n then
				continue
			end
			if (poly[i] - poly[j]).Magnitude >= threshold then
				continue
			end

			local fwdSize = j - i + 1
			local bwdSize = n - j + i + 1

			if fwdSize <= maxLoopVerts and fwdSize <= bwdSize then
				for k = i + 1, j do
					removeSet[k] = true
				end
			elseif bwdSize <= maxLoopVerts and bwdSize < fwdSize then
				for k = j + 1, n do
					removeSet[k] = true
				end
				for k = 1, i do
					removeSet[k] = true
				end
			end
		end
	end

	if next(removeSet) == nil then
		return poly
	end

	local result: { Vector2 } = {}
	for i = 1, n do
		if not removeSet[i] then
			table.insert(result, poly[i])
		end
	end

	local cleaned: { Vector2 } = {}
	for i = 1, #result do
		local prev = result[((i - 2) % #result) + 1]
		if (result[i] - prev).Magnitude > threshold then
			table.insert(cleaned, result[i])
		end
	end

	return if #cleaned >= 3 then cleaned else poly
end

local function offsetPWH(
	pwh: { outer: { Vector2 }, holes: { { Vector2 } } },
	distance: number
): { PolygonNesting.PolygonWithHoles }
	local outerCcw = PolygonInset.ensureCCW(pwh.outer)
	local callEps = computeEps(outerCcw)
	local AREA_EPS = callEps * callEps
	local outerInsets = offset(outerCcw, distance)
	if #outerInsets == 0 then
		return {}
	end

	-- Decompose merged-hole boundaries into individual loops before
	-- offsetting.  FrostingBuilder bridges holes together, so
	-- TopFaceExtractor returns a single polygon tracing all holes via
	-- narrow slits.  Splitting at the bridge endpoints (near-coincident
	-- non-adjacent vertices) recovers individual hole loops, each offset
	-- independently.  When individual hole outsets overlap (as in
	-- Honeycomb), we keep them as separate holes rather than computing
	-- their union, so frosting fills the gaps near the outer boundary.
	local individualHoles: { { Vector2 } } = {}
	for _, h in pwh.holes do
		local hCcw = PolygonInset.ensureCCW(h)
		local bridgeThreshold = math.abs(distance) * 0.2
		local parts = splitBridgedHole(hCcw, bridgeThreshold, 6)
		for _, part in parts do
			local cleaned = cleanSlitVertices(part, bridgeThreshold)
			if #cleaned >= 3 then
				table.insert(individualHoles, cleaned)
			end
		end
	end

	local allHoleOutsets: { { Vector2 } } = {}
	for _, h in individualHoles do
		for _, o in offset(h, -distance) do
			table.insert(allHoleOutsets, o)
		end
	end

	-- Collapse bridge-expansion strips in hole outsets.  When a merged-hole
	-- boundary has a zero-width bridge (self-touching vertex), offsetting
	-- expands the bridge to 2*distance width, creating an unwanted corridor
	-- strip.  Detect by finding collinear vertices (a vertex on the line
	-- between its neighbors, indicating it was the original bridge point),
	-- then snap the corresponding return-path vertices back toward the
	-- bridge line so the strip nearly closes (epsilon-width).
	for hIdx, holeOutset in allHoleOutsets do
		local n = #holeOutset
		if n <= 4 then continue end
		local BRIDGE_EPS = math.max(callEps * 10, math.abs(distance) * 0.01)
		local changed = false
		local poly = table.clone(holeOutset)
		for i = 1, n do
			local prev = poly[((i - 2) % n) + 1]
			local curr = poly[i]
			local nxt = poly[(i % n) + 1]
			local d1 = curr - prev
			local d2 = nxt - curr
			local len1 = d1.Magnitude
			local len2 = d2.Magnitude
			if len1 < BRIDGE_EPS or len2 < BRIDGE_EPS then continue end
			local cross = d1.X * d2.Y - d1.Y * d2.X
			local dot = d1.X * d2.X + d1.Y * d2.Y
			if math.abs(cross) / (len1 * len2) > 0.01 or dot <= 0 then continue end
			-- curr is collinear with prev and nxt (same direction) → bridge point.
			-- The bridge line runs along d1's direction through curr.
			-- Find return-path vertices displaced ~2*distance perpendicular.
			local dir = d1.Unit
			local perp = Vector2.new(-dir.Y, dir.X)
			local bridgePerp = perp:Dot(curr)
			local targetDist = math.abs(distance) * 2
			for j = 1, n do
				if j == i or j == ((i - 2) % n) + 1 or j == (i % n) + 1 then continue end
				local vj = poly[j]
				local perpJ = perp:Dot(vj)
				local gap = math.abs(perpJ - bridgePerp)
				if gap > targetDist * 0.5 and gap < targetDist * 1.5 then
					local shift = bridgePerp - perpJ + math.sign(perpJ - bridgePerp) * BRIDGE_EPS
					poly[j] = vj + perp * shift
					changed = true
				end
			end
		end
		if changed then
			allHoleOutsets[hIdx] = poly
		end
	end

	local result: { PolygonNesting.PolygonWithHoles } = {}
	if #allHoleOutsets == 0 then
		for _, o in outerInsets do
			table.insert(result, { outer = PolygonInset.ensureCCW(o), holes = {} })
		end
	else
		for _, outerInset in outerInsets do
			for _, region in arrangementSubtract(outerInset, allHoleOutsets) do
				table.insert(result, region)
			end
		end
	end

	-- Drop degenerate hole fragments produced by DCEL snap noise
	for _, region in result do
		local outerArea = math.abs(PolygonInset.signedArea(region.outer))
		if outerArea <= AREA_EPS then
			continue
		end
		local filtered: { { Vector2 } } = {}
		for _, h in region.holes do
			local ha = math.abs(PolygonInset.signedArea(h))
			if ha / outerArea >= HOLE_FRAGMENT_AREA_RATIO then
				table.insert(filtered, h)
			end
		end
		region.holes = filtered
	end

	return result
end

return {
	offset = offset,
	offsetPWH = offsetPWH,
	rawOffset = rawOffset,
	pointInPolygon = pointInPolygon,
	segSegIntersect = segSegIntersect,
}
