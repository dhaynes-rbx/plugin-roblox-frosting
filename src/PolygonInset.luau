--!strict

-- 2D polygon inset using the edge bisector method.
--
-- For each vertex, we offset it inward along the bisector of the two
-- adjacent inward edge normals by a distance that maintains a perpendicular
-- inset of `d` from both neighboring edges.
--
-- Winding assumption: the input polygon is in CCW order when viewed from
-- above (+Y). The inward direction is therefore to the left of each edge
-- direction vector.

local MIN_BISECTOR_DOT = 0.05

-- Unified tolerance model.  Every length-scale threshold in this module is
-- expressed as a fixed multiple of a base epsilon derived from the polygon's
-- own bbox diagonal.  Rationale: the old code used five uncoordinated literal
-- epsilons (COINCIDENT_EPS=1e-6, T_EPS=1e-5, PINCH_EPS0=1e-6, PINCH=1e-6,
-- PINCH_EPS=1e-4, BRIDGE_EPS=1e-6) that could disagree at the same distance,
-- producing slivers at teeth/hole junctions when iterated across frosting
-- layers whose polygons shrink layer-over-layer.
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

-- 2-D cross product of (a→b) relative to origin o.
local function cross2D(o: Vector2, a: Vector2, b: Vector2): number
	return (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X)
end

-- Returns the signed area of a 2D polygon (positive = CCW).
local function signedArea(poly: { Vector2 }): number
	local n = #poly
	local area = 0
	for i = 1, n do
		local a = poly[i]
		local b = poly[(i % n) + 1]
		area += (a.X * b.Y) - (b.X * a.Y)
	end
	return area * 0.5
end

-- Ray-casting point-in-polygon test.
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

-- Strict segment-segment intersection test (excludes endpoints).
-- The 1e-6 margins on t/u are dimensionless parameter-space and intentionally
-- kept absolute across polygon sizes (Phase 2 unification rationale).
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
	return t > 1e-6 and t < 1 - 1e-6 and u > 1e-6 and u < 1 - 1e-6
end

-- Collinear-overlap test: returns true if segment a1-a2 is collinear with
-- segment b1-b2 AND their interiors overlap on a non-degenerate interval.
--
-- Needed because the stock ear-clip test (convex vertex + no other polygon
-- vertex inside the ear triangle) accepts ears whose new diagonal coincides
-- with an existing non-adjacent edge of the remaining polygon.  That corrupts
-- the "reduced polygon" (adding a duplicated / reversed edge), after which
-- later iterations happily carve triangles that extend outside the original
-- shape.  Observed on the Comb L2 case: a bottom-edge ear between gap-base
-- vertices produced a diagonal coincident with three existing gap-base edges
-- and ultimately yielded 8 over-large triangles with ~6× the true area.
local function collinearOverlap(
	a1: Vector2,
	a2: Vector2,
	b1: Vector2,
	b2: Vector2
): boolean
	local dA = a2 - a1
	local dB = b2 - b1
	local lenA = dA.Magnitude
	if lenA < 1e-9 then return false end
	local crossDir = dA.X * dB.Y - dA.Y * dB.X
	local scaleDir = math.max(lenA * dB.Magnitude, 1e-12)
	if math.abs(crossDir) / scaleDir > 1e-6 then return false end
	local off1 = b1 - a1
	local crossOff = dA.X * off1.Y - dA.Y * off1.X
	if math.abs(crossOff) / (lenA * math.max(off1.Magnitude, lenA)) > 1e-6 then
		return false
	end
	local lenA2 = lenA * lenA
	local t1 = off1:Dot(dA) / lenA2
	local t2 = (b2 - a1):Dot(dA) / lenA2
	if t1 > t2 then t1, t2 = t2, t1 end
	return t2 > 1e-6 and t1 < 1 - 1e-6
end

-- Insert duplicate vertices at T-junctions (vertex v_i lies in the interior of
-- a non-adjacent edge).  This converts a self-contacting polygon into one with
-- true "pinch points" (pairs of coincident vertices) that fallback 2 of the
-- ear-clip can split into simple sub-polygons.
--
-- Comb / maze-like offsets routinely produce self-contacting outputs: e.g.
-- Comb L2's outer traverses y=-1.294 twice along overlapping x intervals,
-- touching each tooth base at a T-junction.  Without resolution the ear-clip
-- picks diagonals that span exterior gap regions, producing triangles several
-- times the polygon's true area.
local function resolveTJunctions(poly: { Vector2 }): { Vector2 }
	-- T_EPS is the perpendicular-distance tolerance for detecting a vertex
	-- lying on the interior of a non-adjacent edge.  Scaled at 2*EPS so that
	-- it slightly exceeds the pre-weld tolerance (otherwise a pair of vertices
	-- that weld to a single point would not be recognised as a T-junction on
	-- the remaining edge).
	local T_EPS = computeEps(poly) * 2
	-- Work on an indices list so we can insert without disturbing earlier indices.
	local pts: { Vector2 } = table.clone(poly)
	local changed = true
	local guard = 0
	while changed and guard < 4 do
		changed = false
		guard += 1
		local n = #pts
		-- For each vertex i, look for a non-adjacent edge e=(pts[k], pts[k+1])
		-- such that pts[i] lies strictly inside e.  Insert a duplicate of pts[i]
		-- between pts[k] and pts[k+1] (edge subdivision).  Iterate until no
		-- more T-junctions are found.
		local inserts: { { edgeAfter: number, point: Vector2 } } = {}
		for i = 1, n do
			local p = pts[i]
			for k = 1, n do
				local k2 = (k % n) + 1
				if k == i or k2 == i then continue end
				local a = pts[k]
				local b = pts[k2]
				local ab = b - a
				local lenSq = ab.X * ab.X + ab.Y * ab.Y
				if lenSq < 1e-12 then continue end
				local ap = p - a
				local cr = ab.X * ap.Y - ab.Y * ap.X
				if math.abs(cr) > T_EPS * math.sqrt(lenSq) then continue end
				-- Use a dimensionless parameter margin so T-junction detection
				-- is independent of absolute edge length.
				local t = (ap.X * ab.X + ap.Y * ab.Y) / lenSq
				if t > 1e-6 and t < 1 - 1e-6 then
					table.insert(inserts, { edgeAfter = k, point = Vector2.new(p.X, p.Y) })
				end
			end
		end
		if #inserts > 0 then
			table.sort(inserts, function(a, b)
				return a.edgeAfter > b.edgeAfter
			end)
			local seen: { [number]: boolean } = {}
			for _, ins in inserts do
				if seen[ins.edgeAfter] then continue end
				seen[ins.edgeAfter] = true
				table.insert(pts, ins.edgeAfter + 1, ins.point)
				changed = true
			end
		end
	end
	return pts
end

-- Strip consecutive near-coincident vertices (|p_i - p_{i+1}| < eps).
-- This is the pre-triangulation defense against sliver triangles: ear-clip
-- cannot produce an edge shorter than the shortest edge of its input, so by
-- eliminating sub-eps boundary segments up front we guarantee every output
-- triangle has every edge >= eps.
--
-- Non-adjacent near-coincident pairs (pinches) are intentionally NOT welded
-- here: they're either intentional bridge pinches (preserved for hole topology)
-- or true self-contact points that the pinch-split path handles below.
local function weldCoincidentVertices(poly: { Vector2 }, eps: number): { Vector2 }
	if #poly < 2 then return table.clone(poly) end
	local out: { Vector2 } = {}
	for i, p in poly do
		local prev = out[#out]
		if prev == nil or (p - prev).Magnitude >= eps then
			table.insert(out, p)
		end
	end
	-- Close-the-loop check: last vertex against first.
	while #out >= 2 and (out[#out] - out[1]).Magnitude < eps do
		table.remove(out, #out)
	end
	return out
end

-- A "bridge pinch" is a duplicate-vertex pair introduced by bridge-merging
-- a hole into an outer polygon (TestCookieGenerator.extrudeProfile and
-- FrostingBuilder.buildRegion use bridges to stitch holes into a single
-- simple polygon).  The polygon visits the bridge-endpoint vertex, traverses
-- the hole loop, then returns to the same vertex — so the two adjacent
-- "other-bridge-endpoint" vertices are identical too.  These are NOT real
-- self-contact pinches and must not be split: splitting them would separate
-- outer from hole and triangulate them independently, filling the hole in.
local function isBridgePinch(pts: { Vector2 }, ii: number, jj: number, eps: number?): boolean
	local n = #pts
	-- BRIDGE_EPS must be at least as loose as the PINCH tolerance that
	-- invokes isBridgePinch, otherwise a bridge pinch detected at 2*eps would
	-- be rejected here at 1*eps and spuriously split (separating outer from
	-- hole).  Default derives from the polygon's own bbox when caller omits.
	local BRIDGE_EPS = eps or (computeEps(pts) * 2)
	local iNext = (ii % n) + 1
	local jPrev = ((jj - 2) % n) + 1
	if (pts[iNext] - pts[jPrev]).Magnitude < BRIDGE_EPS then
		return true
	end
	local iPrev = ((ii - 2) % n) + 1
	local jNext = (jj % n) + 1
	if (pts[iPrev] - pts[jNext]).Magnitude < BRIDGE_EPS then
		return true
	end
	return false
end

--- Ear-clip triangulation of a simple CCW polygon.
--- Returns an array of {i1, i2, i3} index triples (1-based into `poly`).
local function earClipTriangulate(poly: { Vector2 }, excludeZones: { { Vector2 } }?): { { number } }
	-- Unified tolerance for this polygon.  Every distance threshold in the
	-- function scales with this eps.  Sub-polygons produced by pinch splitting
	-- recompute their own eps via a recursive call.
	local EPS = computeEps(poly)
	local COINCIDENT_EPS = EPS
	local PINCH_TOL = EPS * 2
	local MIN_TRI_AREA = EPS * EPS

	-- Resolve T-junctions up-front, then eagerly split at any pinch points
	-- they created.  Self-contacting offset outputs (Comb / maze L2+) can
	-- only be triangulated cleanly once decomposed into simple sub-polygons,
	-- and relying on the "stuck fallback" path to do so is fragile: fallback
	-- 1's collinear-stripping eats exactly the inserted T-junction vertices.
	local resolved = resolveTJunctions(poly)
	local splitNeeded = #resolved ~= #poly
	if not splitNeeded then
		for ii = 1, #resolved do
			for jj = ii + 2, #resolved do
				if ii == 1 and jj == #resolved then continue end
				if (resolved[ii] - resolved[jj]).Magnitude < PINCH_TOL
					and not isBridgePinch(resolved, ii, jj, PINCH_TOL)
				then
					splitNeeded = true
					break
				end
			end
			if splitNeeded then break end
		end
	end
	if splitNeeded then
		local mapping: { number } = {}
		for i, rp in resolved do
			local best, bestD = 1, math.huge
			for j, op in poly do
				local d = (rp - op).Magnitude
				if d < bestD then bestD = d; best = j end
			end
			mapping[i] = best
		end

		local function splitAtPinch(pts: { Vector2 }): { { Vector2 } }
			local n = #pts
			for ii = 1, n do
				for jj = ii + 2, n do
					if ii == 1 and jj == n then continue end
					if (pts[ii] - pts[jj]).Magnitude < PINCH_TOL
						and not isBridgePinch(pts, ii, jj, PINCH_TOL)
					then
						local sub1: { Vector2 } = {}
						for k = ii, jj do table.insert(sub1, pts[k]) end
						local sub2: { Vector2 } = {}
						for k = jj, n do table.insert(sub2, pts[k]) end
						for k = 1, ii do table.insert(sub2, pts[k]) end
						return { sub1, sub2 }
					end
				end
			end
			return { pts }
		end

		local function indexInResolved(v: Vector2, from: number): number
			local matchTol = math.max(EPS * 0.1, MIN_EPS)
			for k = from, #resolved do
				if (resolved[k] - v).Magnitude < matchTol then return k end
			end
			for k = 1, from - 1 do
				if (resolved[k] - v).Magnitude < matchTol then return k end
			end
			return 1
		end

		local pending: { { Vector2 } } = { resolved }
		local finalised: { { Vector2 } } = {}
		local guard = 0
		while #pending > 0 and guard < 64 do
			guard += 1
			local cur = table.remove(pending, 1)
			local parts = splitAtPinch(cur)
			if #parts == 1 then
				table.insert(finalised, parts[1])
			else
				for _, p in parts do
					if #p >= 3 then table.insert(pending, p) end
				end
			end
		end

		-- Splitting at a pinch reverses winding of one of the sub-loops
		-- relative to the other.  For a self-contacting polygon whose
		-- "interior" is the union of every sub-loop (e.g. bottom strip +
		-- 4 teeth of a comb offset), every piece should be treated as CCW
		-- material.  Flip any CW piece back to CCW so the primary ear-clip
		-- sees positive cross products and can find ears normally.
		local out: { { number } } = {}
		for _, subPoly in finalised do
			local sa = signedArea(subPoly)
			if sa < 0 then
				local rev: { Vector2 } = {}
				for i = #subPoly, 1, -1 do
					table.insert(rev, subPoly[i])
				end
				subPoly = rev
			end
			local subTris = earClipTriangulate(subPoly, excludeZones)
			for _, tri in subTris do
				local p1 = subPoly[tri[1]]
				local p2 = subPoly[tri[2]]
				local p3 = subPoly[tri[3]]
				local i1 = indexInResolved(p1, 1)
				local i2 = indexInResolved(p2, 1)
				local i3 = indexInResolved(p3, 1)
				table.insert(out, { mapping[i1], mapping[i2], mapping[i3] })
			end
		end
		return out
	end

	-- Build the working indices array with pre-weld: skip vertices whose
	-- position is within EPS of the previously-kept vertex, so the main
	-- ear-clip loop never sees a zero-or-sub-eps-length boundary edge.
	-- Note this only runs in the fast (no-split) path; the split path routes
	-- through sub-polygons that each get their own recursive pre-weld pass.
	local indices: { number } = {}
	for i = 1, #poly do
		local prevIdx = indices[#indices]
		if prevIdx == nil or (poly[i] - poly[prevIdx]).Magnitude >= EPS then
			table.insert(indices, i)
		end
	end
	while #indices >= 2 and (poly[indices[#indices]] - poly[indices[1]]).Magnitude < EPS do
		table.remove(indices, #indices)
	end

	local triangles: { { number } } = {}
	local maxIter = #poly * 3
	local collinearStripped = false

	while #indices > 3 and maxIter > 0 do
		maxIter -= 1
		local earFound = false
		local m = #indices

		for i = 1, m do
			local prev = indices[((i - 2) % m) + 1]
			local cur = indices[i]
			local nxt = indices[(i % m) + 1]

			local cr = cross2D(poly[prev], poly[cur], poly[nxt])
			local scale = math.max((poly[cur] - poly[prev]).Magnitude, (poly[nxt] - poly[cur]).Magnitude)
			if cr <= COINCIDENT_EPS * math.max(scale, 1e-9) then
				continue
			end

			local pA, pB, pC = poly[prev], poly[cur], poly[nxt]
			local isEar = true
			for j = 1, m do
				local idx = indices[j]
				if idx == prev or idx == cur or idx == nxt then
					continue
				end
				local p = poly[idx]
				if (p - pA).Magnitude < COINCIDENT_EPS
					or (p - pB).Magnitude < COINCIDENT_EPS
					or (p - pC).Magnitude < COINCIDENT_EPS
				then
					continue
				end
				local d1 = cross2D(pA, pB, p)
				local d2 = cross2D(pB, pC, p)
				local d3 = cross2D(pC, pA, p)
				local lenAB = (pB - pA).Magnitude
				local lenBC = (pC - pB).Magnitude
				local lenCA = (pA - pC).Magnitude
				if (lenAB > COINCIDENT_EPS and math.abs(d1) / lenAB < COINCIDENT_EPS)
					or (lenBC > COINCIDENT_EPS and math.abs(d2) / lenBC < COINCIDENT_EPS)
					or (lenCA > COINCIDENT_EPS and math.abs(d3) / lenCA < COINCIDENT_EPS)
				then
					continue
				end
				if not ((d1 < 0) or (d2 < 0) or (d3 < 0)) or not ((d1 > 0) or (d2 > 0) or (d3 > 0)) then
					isEar = false
					break
				end
			end

			-- Reject ears whose new diagonal pA-pC would cross or collinearly
			-- overlap a non-adjacent edge of the current reduced polygon, and
			-- whose diagonal midpoint lies outside the reduced polygon.  The
			-- stock ear test (convex + no other polygon vertex inside the
			-- triangle) is insufficient for comb / maze shapes: it happily
			-- approves "ears" that hang outside the polygon between thin
			-- notches, yielding a triangulation whose triangles overlap each
			-- other and cover several times the polygon's true area.  The
			-- midpoint-inside test is O(n) but guarantees the diagonal is a
			-- true interior diagonal.
			if isEar then
				for k = 1, m do
					local k2 = (k % m) + 1
					local ka = indices[k]
					local kb = indices[k2]
					if ka == prev or ka == cur or ka == nxt
						or kb == prev or kb == cur or kb == nxt
					then
						continue
					end
					local ea, eb = poly[ka], poly[kb]
					if segsCross(pA, pC, ea, eb) then
						isEar = false
						break
					end
					if collinearOverlap(pA, pC, ea, eb) then
						isEar = false
						break
					end
				end
			end

			if isEar then
				local midX = (pA.X + pC.X) * 0.5
				local midY = (pA.Y + pC.Y) * 0.5
				local inside = false
				local n = m
				local jj = n
				for ii = 1, n do
					local pii = poly[indices[ii]]
					local pjj = poly[indices[jj]]
					if ((pii.Y > midY) ~= (pjj.Y > midY))
						and (midX < (pjj.X - pii.X) * (midY - pii.Y) / (pjj.Y - pii.Y) + pii.X)
					then
						inside = not inside
					end
					jj = ii
				end
				if not inside then
					isEar = false
				end
			end

			if isEar and excludeZones then
				local cx = (pA.X + pB.X + pC.X) / 3
				local cy = (pA.Y + pB.Y + pC.Y) / 3
				local centroid = Vector2.new(cx, cy)
				for _, zone in excludeZones do
					if pointInPolygon(centroid, zone) then
						isEar = false
						break
					end
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
			-- Fallback 1: strip collinear/near-collinear vertices.
			-- Bridge-merged polygons can leave vertices exactly on the line
			-- between their neighbors; these never form valid ears but block
			-- adjacent vertices from becoming ears.
			if not collinearStripped then
				collinearStripped = true
				local stripped = false
				for i = #indices, 1, -1 do
					local m2 = #indices
					local pi = indices[((i - 2) % m2) + 1]
					local ci = indices[i]
					local ni = indices[(i % m2) + 1]
					local cr = cross2D(poly[pi], poly[ci], poly[ni])
					local sc = math.max(
						(poly[ci] - poly[pi]).Magnitude,
						(poly[ni] - poly[ci]).Magnitude
					)
					if math.abs(cr) / math.max(sc, 1e-9) < 1e-3 then
						table.remove(indices, i)
						stripped = true
					end
				end
				if stripped and #indices >= 3 then
					continue
				end
			end

			-- Fallback 2: pinch-point splitting.
			-- Bridge-merged polygons can have zero-width "slits" where the
			-- polygon touches itself. Split into two sub-polygons and
			-- recursively triangulate both halves.
			local m2 = #indices
			local splitI: number?, splitJ: number?
			for ii = 1, m2 do
				for jj = ii + 2, m2 do
					if ii == 1 and jj == m2 then continue end
					if (poly[indices[ii]] - poly[indices[jj]]).Magnitude < PINCH_TOL then
						splitI, splitJ = ii, jj
						break
					end
				end
				if splitI then break end
			end

			if splitI and splitJ then
				local sub1Map: { number } = {}
				for k = splitI, splitJ do
					table.insert(sub1Map, indices[k])
				end
				local sub2Map: { number } = {}
				for k = splitJ, m2 do
					table.insert(sub2Map, indices[k])
				end
				for k = 1, splitI do
					table.insert(sub2Map, indices[k])
				end

				for _, subMap in { sub1Map, sub2Map } do
					if #subMap >= 3 then
						local subPoly: { Vector2 } = {}
						for _, idx in subMap do
							table.insert(subPoly, poly[idx])
						end
						local subTris = earClipTriangulate(subPoly, excludeZones)
						for _, tri in subTris do
							table.insert(triangles, { subMap[tri[1]], subMap[tri[2]], subMap[tri[3]] })
						end
					end
				end
				break
			end

			-- Fallback 3: diagonal splitting.
			-- Find the shortest valid internal diagonal and split the polygon
			-- into two simpler halves that can be triangulated recursively.
			local m3 = #indices
			local bestII: number?, bestJJ: number?, bestDist = nil, nil, math.huge
			for ii = 1, m3 do
				local pi = indices[((ii - 2) % m3) + 1]
				local ci = indices[ii]
				local ni = indices[(ii % m3) + 1]
				for jj = ii + 2, m3 do
					if ii == 1 and jj == m3 then continue end
					local pj = indices[((jj - 2) % m3) + 1]
					local cj = indices[jj]
					local nj = indices[(jj % m3) + 1]

					-- inCone test at vertex ii (O'Rourke)
					local a, a0, a1, b = poly[ci], poly[pi], poly[ni], poly[cj]
					local inConeI: boolean
					if cross2D(a, a1, a0) >= 0 then
						inConeI = cross2D(a, b, a0) > 0 and cross2D(a1, b, a) > 0
					else
						inConeI = not (cross2D(a, b, a1) >= 0 and cross2D(a0, b, a) >= 0)
					end
					if not inConeI then continue end

					-- inCone test at vertex jj
					a, a0, a1, b = poly[cj], poly[pj], poly[nj], poly[ci]
					local inConeJ: boolean
					if cross2D(a, a1, a0) >= 0 then
						inConeJ = cross2D(a, b, a0) > 0 and cross2D(a1, b, a) > 0
					else
						inConeJ = not (cross2D(a, b, a1) >= 0 and cross2D(a0, b, a) >= 0)
					end
					if not inConeJ then continue end

					local crosses = false
					for k = 1, m3 do
						local k2 = (k % m3) + 1
						local ek1, ek2 = indices[k], indices[k2]
						if ek1 == ci or ek2 == ci or ek1 == cj or ek2 == cj then continue end
						if segsCross(poly[ci], poly[cj], poly[ek1], poly[ek2])
							or collinearOverlap(poly[ci], poly[cj], poly[ek1], poly[ek2])
						then
							crosses = true
							break
						end
					end
					if crosses then continue end

					-- Midpoint-inside check: the diagonal must lie inside the
					-- reduced polygon.  Without this, cone + no-crossing alone
					-- admit diagonals that span exterior pockets (notch gaps)
					-- whose edges the diagonal happens not to cross.
					local midX = (poly[ci].X + poly[cj].X) * 0.5
					local midY = (poly[ci].Y + poly[cj].Y) * 0.5
					local inside = false
					local jjj = m3
					for iii = 1, m3 do
						local pii = poly[indices[iii]]
						local pjj = poly[indices[jjj]]
						if ((pii.Y > midY) ~= (pjj.Y > midY))
							and (midX < (pjj.X - pii.X) * (midY - pii.Y) / (pjj.Y - pii.Y) + pii.X)
						then
							inside = not inside
						end
						jjj = iii
					end
					if not inside then continue end

					local dist = (poly[ci] - poly[cj]).Magnitude
					if dist < bestDist then
						bestII, bestJJ, bestDist = ii, jj, dist
					end
				end
			end

			if bestII and bestJJ then
				local sub1Map: { number } = {}
				for k = bestII, bestJJ do
					table.insert(sub1Map, indices[k])
				end
				local sub2Map: { number } = {}
				for k = bestJJ, m3 do
					table.insert(sub2Map, indices[k])
				end
				for k = 1, bestII do
					table.insert(sub2Map, indices[k])
				end

				for _, subMap in { sub1Map, sub2Map } do
					if #subMap >= 3 then
						local subPoly: { Vector2 } = {}
						for _, idx in subMap do
							table.insert(subPoly, poly[idx])
						end
						local subTris = earClipTriangulate(subPoly, excludeZones)
						for _, tri in subTris do
							table.insert(triangles, { subMap[tri[1]], subMap[tri[2]], subMap[tri[3]] })
						end
					end
				end
				break
			end

			break
		end
	end

	if #indices == 3 then
		local cr = cross2D(poly[indices[1]], poly[indices[2]], poly[indices[3]])
		if cr > COINCIDENT_EPS then
			table.insert(triangles, { indices[1], indices[2], indices[3] })
		elseif cr < -COINCIDENT_EPS then
			table.insert(triangles, { indices[1], indices[3], indices[2] })
		end
	end

	-- Post-sliver filter: drop any triangle whose area is below eps^2.
	--
	-- This is a safety net: in principle, no sliver can survive the pre-weld
	-- done inside resolveTJunctions/pinch-split because no boundary edge is
	-- shorter than eps.  In practice, interior ear diagonals can still connect
	-- two near-collinear-but-not-welded vertices, and the old ear-clip would
	-- emit the resulting degenerate triangle.  Filtering these out eliminates
	-- the visible "quad" wireframe artefacts where a cap meets a wall on
	-- iterated layers (Comb L2, SwissCheese L2, TightHolePair L2, etc.).
	--
	-- Dropping a triangle is topology-safe because the sliver's 3 vertices are
	-- (nearly) collinear: its area-0 contribution to the mesh is indistinguish-
	-- able from the empty set.
	if #triangles > 0 and MIN_TRI_AREA > 0 then
		local filtered: { { number } } = {}
		for _, tri in triangles do
			local pA = poly[tri[1]]
			local pB = poly[tri[2]]
			local pC = poly[tri[3]]
			local area = math.abs(cross2D(pA, pB, pC)) * 0.5
			if area >= MIN_TRI_AREA then
				table.insert(filtered, tri)
			end
		end
		triangles = filtered
	end

	return triangles
end

-- Ensures the polygon is in CCW order; reverses in-place if CW.
local function ensureCCW(poly: { Vector2 }): { Vector2 }
	if signedArea(poly) < 0 then
		local reversed: { Vector2 } = {}
		for i = #poly, 1, -1 do
			table.insert(reversed, poly[i])
		end
		return reversed
	end
	return poly
end

-- Insets a polygon by `distance` units.
-- Returns a new polygon of the same vertex count.
-- Vertices that would cross over are clamped to prevent mesh inversion.
local function inset(poly: { Vector2 }, distance: number): { Vector2 }
	poly = ensureCCW(poly)
	local n = #poly
	local result: { Vector2 } = {}

	for i = 1, n do
		local prev = poly[((i - 2) % n) + 1]
		local curr = poly[i]
		local next = poly[(i % n) + 1]

		-- Edge directions
		local ePrev = (curr - prev).Unit   -- direction arriving at curr
		local eNext = (next - curr).Unit   -- direction leaving curr

		-- Inward normals (left-perpendicular of each edge direction, for CCW poly)
		local nPrev = Vector2.new(-ePrev.Y, ePrev.X)
		local nNext = Vector2.new(-eNext.Y, eNext.X)

		-- Bisector of the two inward normals
		local bisector = (nPrev + nNext)
		local bisectorLen = bisector.Magnitude
		if bisectorLen < 1e-6 then
			-- Edges are antiparallel (180° turn): move purely along nPrev
			table.insert(result, curr + nPrev * distance)
			continue
		end
		bisector = bisector / bisectorLen

		-- How far along bisector to travel to achieve `distance` perpendicular offset.
		-- dot(bisector, nPrev) = cos(half-angle between bisector and edge normal)
		local dot = bisector:Dot(nPrev)
		-- Clamp to avoid exploding at near-zero (very sharp convex corner)
		-- and to avoid overshooting at reflex (concave) corners.
		dot = math.clamp(dot, MIN_BISECTOR_DOT, 1)

		local offset = distance / dot
		table.insert(result, curr + bisector * offset)
	end

	return result
end

return {
	inset = inset,
	ensureCCW = ensureCCW,
	signedArea = signedArea,
	earClipTriangulate = earClipTriangulate,
	bboxDiag = bboxDiag,
	computeEps = computeEps,
	weldCoincidentVertices = weldCoincidentVertices,
}
