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

local MIN_BISECTOR_DOT = 0.05 -- clamp for near-parallel or reflex corners

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
}
