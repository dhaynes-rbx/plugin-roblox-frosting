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
local COINCIDENT_EPS = 1e-6

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

--- Ear-clip triangulation of a simple CCW polygon.
--- Returns an array of {i1, i2, i3} index triples (1-based into `poly`).
local function earClipTriangulate(poly: { Vector2 }, excludeZones: { { Vector2 } }?): { { number } }
	local indices: { number } = {}
	for i = 1, #poly do
		table.insert(indices, i)
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
			local PINCH_EPS = 1e-4
			local splitI: number?, splitJ: number?
			for ii = 1, m2 do
				for jj = ii + 2, m2 do
					if ii == 1 and jj == m2 then continue end
					if (poly[indices[ii]] - poly[indices[jj]]).Magnitude < PINCH_EPS then
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
						if segsCross(poly[ci], poly[cj], poly[ek1], poly[ek2]) then
							crosses = true
							break
						end
					end
					if crosses then continue end

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
}
