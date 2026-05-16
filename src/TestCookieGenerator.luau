--!strict

-- Procedural test cookie generator.
--
-- Each shape is a 2D polygon profile extruded vertically into a flat-topped
-- MeshPart cookie.  The shapes exercise edge-cases in the frosting algorithm:
-- concavities, thin features, holes, disconnected islands, etc.

local AssetService = game:GetService("AssetService")
local PolygonInset = require(script.Parent.PolygonInset)

local COOKIE_HEIGHT = 0.4
local COOKIE_RADIUS = 3 -- baseline radius for circle-based shapes
local GRID_SPACING = 10

--------------------------------------------------------------------------------
-- 2-D profile helpers
--------------------------------------------------------------------------------

local function circleProfile(cx: number, cz: number, r: number, nSeg: number): { Vector2 }
	local pts: { Vector2 } = {}
	for i = 0, nSeg - 1 do
		local a = 2 * math.pi * i / nSeg
		table.insert(pts, Vector2.new(cx + r * math.cos(a), cz + r * math.sin(a)))
	end
	return pts
end

local function rectProfile(cx: number, cz: number, w: number, h: number): { Vector2 }
	local hw, hh = w / 2, h / 2
	return {
		Vector2.new(cx - hw, cz - hh),
		Vector2.new(cx + hw, cz - hh),
		Vector2.new(cx + hw, cz + hh),
		Vector2.new(cx - hw, cz + hh),
	}
end

local function diamondProfile(cx: number, cz: number, w: number, h: number): { Vector2 }
	local hw, hh = w / 2, h / 2
	return {
		Vector2.new(cx, cz - hh),
		Vector2.new(cx + hw, cz),
		Vector2.new(cx, cz + hh),
		Vector2.new(cx - hw, cz),
	}
end

local function regularPolygonProfile(
	cx: number,
	cz: number,
	r: number,
	n: number,
	rotation: number?
): { Vector2 }
	local rot = rotation or 0
	local pts: { Vector2 } = {}
	for i = 0, n - 1 do
		local a = rot + 2 * math.pi * i / n
		table.insert(pts, Vector2.new(cx + r * math.cos(a), cz + r * math.sin(a)))
	end
	return pts
end

local function starProfileAt(
	cx: number,
	cz: number,
	rOuter: number,
	rInner: number,
	nPoints: number,
	rotation: number?
): { Vector2 }
	local rot = rotation or math.pi / 2
	local pts: { Vector2 } = {}
	for i = 0, nPoints * 2 - 1 do
		local a = rot + 2 * math.pi * i / (nPoints * 2)
		local r = if i % 2 == 0 then rOuter else rInner
		table.insert(pts, Vector2.new(cx + r * math.cos(a), cz + r * math.sin(a)))
	end
	return pts
end

local function plusProfile(
	cx: number,
	cz: number,
	armHalfLen: number,
	armHalfWidth: number
): { Vector2 }
	local L, W = armHalfLen, armHalfWidth
	return {
		Vector2.new(cx - W, cz - L),
		Vector2.new(cx + W, cz - L),
		Vector2.new(cx + W, cz - W),
		Vector2.new(cx + L, cz - W),
		Vector2.new(cx + L, cz + W),
		Vector2.new(cx + W, cz + W),
		Vector2.new(cx + W, cz + L),
		Vector2.new(cx - W, cz + L),
		Vector2.new(cx - W, cz + W),
		Vector2.new(cx - L, cz + W),
		Vector2.new(cx - L, cz - W),
		Vector2.new(cx - W, cz - W),
	}
end

--------------------------------------------------------------------------------
-- Shape generators: each returns { profiles = { {outer, holes?} }, name }
-- `outer` is { Vector2 } CCW, `holes` is optional { { Vector2 } }.
-- Multiple entries in `profiles` produce disconnected pieces.
--------------------------------------------------------------------------------

type ShapeProfile = {
	outer: { Vector2 },
	holes: { { Vector2 } }?,
}

type Shape = {
	name: string,
	profiles: { ShapeProfile },
	-- Multi-profile shapes where the author has already laid the islands out in
	-- non-overlapping local coordinates (archipelago-style). Opts out of the
	-- default per-profile X offset that is used to visually separate concentric
	-- profiles like NestedRing.
	noOffset: boolean?,
}

local function makeCircle(): Shape
	return {
		name = "Circle",
		profiles = { { outer = circleProfile(0, 0, COOKIE_RADIUS, 32) } },
	}
end

local function makeStar(): Shape
	local pts: { Vector2 } = {}
	local nPoints = 5
	for i = 0, nPoints * 2 - 1 do
		local a = math.pi / 2 + 2 * math.pi * i / (nPoints * 2)
		local r = if i % 2 == 0 then COOKIE_RADIUS else COOKIE_RADIUS * 0.35
		table.insert(pts, Vector2.new(r * math.cos(a), r * math.sin(a)))
	end
	return { name = "Star", profiles = { { outer = pts } } }
end

local function makeLShape(): Shape
	local s = COOKIE_RADIUS
	local pts = {
		Vector2.new(0, 0),
		Vector2.new(s * 2, 0),
		Vector2.new(s * 2, s * 0.6),
		Vector2.new(s * 0.6, s * 0.6),
		Vector2.new(s * 0.6, s * 2),
		Vector2.new(0, s * 2),
	}
	-- Center the shape
	local cx, cz = s, s
	for i, p in pts do
		pts[i] = Vector2.new(p.X - cx, p.Y - cz)
	end
	return { name = "L-Shape", profiles = { { outer = pts } } }
end

local function makeUShape(): Shape
	local w = COOKIE_RADIUS * 2
	local h = COOKIE_RADIUS * 2
	local armW = w * 0.3
	local channelH = h * 0.6
	local pts = {
		Vector2.new(-w / 2, -h / 2),
		Vector2.new(w / 2, -h / 2),
		Vector2.new(w / 2, h / 2),
		Vector2.new(w / 2 - armW, h / 2),
		Vector2.new(w / 2 - armW, -h / 2 + (h - channelH)),
		Vector2.new(-w / 2 + armW, -h / 2 + (h - channelH)),
		Vector2.new(-w / 2 + armW, h / 2),
		Vector2.new(-w / 2, h / 2),
	}
	return { name = "U-Shape", profiles = { { outer = pts } } }
end

local function makeThinRect(): Shape
	return {
		name = "ThinRect",
		profiles = { { outer = rectProfile(0, 0, COOKIE_RADIUS * 2, 0.3) } },
	}
end

local function makeCrescent(): Shape
	local R = COOKIE_RADIUS
	local innerR = R * 0.85
	local cx = R * 0.6 -- inner circle center X

	-- Circle-circle intersection angles
	local cosOuter = (cx * cx + R * R - innerR * innerR) / (2 * cx * R)
	cosOuter = math.clamp(cosOuter, -1, 1)
	local outerAngle = math.acos(cosOuter)

	-- Intersection point (top)
	local ix = R * math.cos(outerAngle)
	local iy = R * math.sin(outerAngle)

	-- Angles on inner circle for the intersection points
	local innerAngleTop = math.atan2(iy, ix - cx)
	local innerAngleBot = math.atan2(-iy, ix - cx)

	local pts: { Vector2 } = {}
	local nOuter = 40
	local nInner = 24

	-- Outer arc: CCW from P_top to P_bot (the long way, through π)
	local outerSweep = 2 * math.pi - 2 * outerAngle
	for i = 0, nOuter - 1 do
		local a = outerAngle + (i / nOuter) * outerSweep
		table.insert(pts, Vector2.new(R * math.cos(a), R * math.sin(a)))
	end

	-- Inner arc: CW from P_bot back to P_top (through π on the inner circle)
	local cwSweep = (2 * math.pi) - (innerAngleTop - innerAngleBot)
	for i = 0, nInner - 1 do
		local a = innerAngleBot - (i / nInner) * cwSweep
		table.insert(pts, Vector2.new(cx + innerR * math.cos(a), innerR * math.sin(a)))
	end

	return { name = "Crescent", profiles = { { outer = pts } } }
end

local function makeDonut(): Shape
	local outer = circleProfile(0, 0, COOKIE_RADIUS, 32)
	local inner = circleProfile(0, 0, COOKIE_RADIUS * 0.4, 24)
	return {
		name = "Donut",
		profiles = { { outer = outer, holes = { inner } } },
	}
end

local function makeMultiHole(): Shape
	local outer = rectProfile(0, 0, COOKIE_RADIUS * 2.5, COOKIE_RADIUS * 2.5)
	local h1 = circleProfile(-COOKIE_RADIUS * 0.55, COOKIE_RADIUS * 0.55, COOKIE_RADIUS * 0.3, 16)
	local h2 = circleProfile(COOKIE_RADIUS * 0.55, COOKIE_RADIUS * 0.55, COOKIE_RADIUS * 0.25, 16)
	local h3 = circleProfile(0, -COOKIE_RADIUS * 0.5, COOKIE_RADIUS * 0.35, 16)
	return {
		name = "MultiHole",
		profiles = { { outer = outer, holes = { h1, h2, h3 } } },
	}
end

local function makeTwoDiscs(): Shape
	local left = circleProfile(-COOKIE_RADIUS * 1.2, 0, COOKIE_RADIUS * 0.8, 24)
	local right = circleProfile(COOKIE_RADIUS * 1.2, 0, COOKIE_RADIUS * 0.8, 24)
	return {
		name = "TwoDiscs",
		profiles = {
			{ outer = left },
			{ outer = right },
		},
	}
end

local function makeFigure8(): Shape
	local n = 32
	local pts: { Vector2 } = {}
	-- Lemniscate-like shape via two overlapping circles merged
	local r = COOKIE_RADIUS * 0.75
	local sep = r * 0.65
	for i = 0, n - 1 do
		local a = 2 * math.pi * i / n
		local px = r * math.cos(a) - sep
		local py = r * math.sin(a)
		table.insert(pts, Vector2.new(px, py))
	end
	for i = 0, n - 1 do
		local a = 2 * math.pi * i / n
		local px = r * math.cos(a) + sep
		local py = r * math.sin(a)
		table.insert(pts, Vector2.new(px, py))
	end
	-- Simplify: use a parametric figure-8 instead
	pts = {}
	local total = 64
	for i = 0, total - 1 do
		local t = 2 * math.pi * i / total
		local scale = COOKIE_RADIUS
		-- "pinched" ellipse: narrower in the middle
		local px = scale * math.cos(t)
		local py = scale * math.sin(t) * (0.5 + 0.5 * math.abs(math.cos(t)))
		table.insert(pts, Vector2.new(px, py))
	end
	return { name = "Figure8", profiles = { { outer = pts } } }
end

local function makeHeart(): Shape
	local pts: { Vector2 } = {}
	local n = 48
	for i = 0, n - 1 do
		local t = 2 * math.pi * i / n
		local r = COOKIE_RADIUS * 0.7
		local px = r * 16 * math.sin(t) ^ 3 / 16
		local py = r
			* (13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
			/ 16
		table.insert(pts, Vector2.new(px, py))
	end
	return { name = "Heart", profiles = { { outer = pts } } }
end

local function makeComb(): Shape
	local nTeeth = 6
	local toothW = 0.4
	local toothH = COOKIE_RADIUS * 1.2
	local gap = 0.25
	local baseH = COOKIE_RADIUS * 0.5
	local totalW = nTeeth * toothW + (nTeeth - 1) * gap

	local pts: { Vector2 } = {}
	local startX = -totalW / 2

	-- Bottom-left
	table.insert(pts, Vector2.new(startX, 0))

	-- Teeth (going left to right along the top)
	for i = 0, nTeeth - 1 do
		local tx = startX + i * (toothW + gap)
		table.insert(pts, Vector2.new(tx, baseH))
		table.insert(pts, Vector2.new(tx, baseH + toothH))
		table.insert(pts, Vector2.new(tx + toothW, baseH + toothH))
		table.insert(pts, Vector2.new(tx + toothW, baseH))
	end

	-- Bottom-right
	table.insert(pts, Vector2.new(startX + totalW, 0))

	-- Center vertically
	local midY = (baseH + toothH) / 2
	for i, p in pts do
		pts[i] = Vector2.new(p.X, p.Y - midY)
	end

	return { name = "Comb", profiles = { { outer = pts } } }
end

--------------------------------------------------------------------------------
-- Extrusion: 2D profile → flat-topped EditableMesh → MeshPart
--------------------------------------------------------------------------------

local function extrudeProfile(profile: ShapeProfile, height: number): MeshPart
	local em = AssetService:CreateEditableMesh()
	-- Side wall winding assumes a CCW outer boundary (viewed from +Y). Shapes defined CW
	-- (e.g. parametric hearts, hand-authored zigzags) get inverted side normals otherwise.
	local outer = PolygonInset.ensureCCW(profile.outer)
	local holes: { { Vector2 } } = profile.holes or {}
	local nOuter = #outer

	local function addTri(a: number, b: number, c: number)
		em:AddTriangle(a, b, c)
	end

	-- Separate vertex sets for walls vs caps prevents normal averaging.
	-- Wall vertices are shared between adjacent wall quads (smooth side shading).
	-- Cap vertices are isolated to cap faces (flat top/bottom normals).
	local outerWallBotVids: { number } = {}
	local outerWallTopVids: { number } = {}
	local outerCapTopVids: { number } = {}
	local outerCapBotVids: { number } = {}
	for _, p in outer do
		local x, z = p.X, p.Y
		table.insert(outerWallBotVids, em:AddVertex(Vector3.new(x, 0, z)))
		table.insert(outerWallTopVids, em:AddVertex(Vector3.new(x, height, z)))
		table.insert(outerCapTopVids, em:AddVertex(Vector3.new(x, height, z)))
		table.insert(outerCapBotVids, em:AddVertex(Vector3.new(x, 0, z)))
	end

	-- Outer side walls (outward-facing normals)
	for i = 1, nOuter do
		local i2 = (i % nOuter) + 1
		addTri(outerWallBotVids[i2], outerWallBotVids[i], outerWallTopVids[i])
		addTri(outerWallBotVids[i2], outerWallTopVids[i], outerWallTopVids[i2])
	end

	-- Hole vertices and side walls
	local allHoleCapTopVids: { { number } } = {}
	local allHoleCapBotVids: { { number } } = {}
	for h, holePoly in holes do
		local wallBVids: { number } = {}
		local wallTVids: { number } = {}
		local capTVids: { number } = {}
		local capBVids: { number } = {}
		for _, p in holePoly do
			local x, z = p.X, p.Y
			table.insert(wallBVids, em:AddVertex(Vector3.new(x, 0, z)))
			table.insert(wallTVids, em:AddVertex(Vector3.new(x, height, z)))
			table.insert(capTVids, em:AddVertex(Vector3.new(x, height, z)))
			table.insert(capBVids, em:AddVertex(Vector3.new(x, 0, z)))
		end
		allHoleCapTopVids[h] = capTVids
		allHoleCapBotVids[h] = capBVids

		-- Hole side walls (normals face into hole void)
		local nH = #holePoly
		for i = 1, nH do
			local i2 = (i % nH) + 1
			addTri(wallBVids[i], wallBVids[i2], wallTVids[i2])
			addTri(wallBVids[i], wallTVids[i2], wallTVids[i])
		end
	end

	-- Ear-clip a cap face using the given vertex ids
	local function earClipCap(poly: { Vector2 }, vids: { number }, flipWinding: boolean)
		local ccwPoly = PolygonInset.ensureCCW(poly)
		local orderedVids = vids
		if PolygonInset.signedArea(poly) < 0 then
			orderedVids = {}
			for i = #vids, 1, -1 do
				table.insert(orderedVids, vids[i])
			end
		end
		local tris = PolygonInset.earClipTriangulate(ccwPoly)
		for _, tri in tris do
			if flipWinding then
				addTri(orderedVids[tri[3]], orderedVids[tri[2]], orderedVids[tri[1]])
			else
				addTri(orderedVids[tri[1]], orderedVids[tri[2]], orderedVids[tri[3]])
			end
		end
	end

	if #holes == 0 then
		earClipCap(outer, outerCapTopVids, true)
		earClipCap(outer, outerCapBotVids, false)
	else
		local mergedPoly: { Vector2 } = table.clone(outer)
		local mergedTopVids: { number } = table.clone(outerCapTopVids)
		local mergedBotVids: { number } = table.clone(outerCapBotVids)

		for h, holePoly in holes do
			local nh = #holePoly
			local nm = #mergedPoly
			-- Naive nearest-pair bridge.  We explicitly do NOT adopt the
			-- crossing-safe algorithm used by FrostingBuilder.mergeHoleVids
			-- here: the downstream pipeline re-extracts the top face via
			-- TopFaceExtractor and re-merges holes with the production
			-- logic, so this generator only needs to produce a mesh that is
			-- topologically walkable by TopFaceExtractor.  Swapping in
			-- crossing-safe bridges here regresses Maze (multi-hole layouts
			-- that depend on specific bridge chaining to keep all 5 hole
			-- boundaries distinct after triangulation).
			local bestDist = math.huge
			local bridgeIdx, holeStartIdx = 1, 1
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
			local newTopV: { number } = {}
			local newBotV: { number } = {}
			for i = 1, bridgeIdx do
				table.insert(newPoly, mergedPoly[i])
				table.insert(newTopV, mergedTopVids[i])
				table.insert(newBotV, mergedBotVids[i])
			end
			for k = 0, nh do
				local idx = ((holeStartIdx - 1 - k) % nh) + 1
				table.insert(newPoly, holePoly[idx])
				table.insert(newTopV, allHoleCapTopVids[h][idx])
				table.insert(newBotV, allHoleCapBotVids[h][idx])
			end
			table.insert(newPoly, mergedPoly[bridgeIdx])
			table.insert(newTopV, mergedTopVids[bridgeIdx])
			table.insert(newBotV, mergedBotVids[bridgeIdx])
			for i = bridgeIdx + 1, nm do
				table.insert(newPoly, mergedPoly[i])
				table.insert(newTopV, mergedTopVids[i])
				table.insert(newBotV, mergedBotVids[i])
			end
			mergedPoly = newPoly
			mergedTopVids = newTopV
			mergedBotVids = newBotV
		end

		earClipCap(mergedPoly, mergedTopVids, true)
		earClipCap(mergedPoly, mergedBotVids, false)
	end

	return AssetService:CreateMeshPartAsync(Content.fromObject(em))
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Wave 2: harder shapes
--------------------------------------------------------------------------------

local function makeSwissCheese(): Shape
	local outer = circleProfile(0, 0, COOKIE_RADIUS * 1.1, 40)
	local holes = {
		circleProfile(-1.5, 1.0, 0.45, 12),
		circleProfile(0.8, 1.3, 0.35, 12),
		circleProfile(-0.5, -0.3, 0.55, 14),
		circleProfile(1.2, -0.6, 0.4, 12),
		circleProfile(-1.3, -1.2, 0.3, 10),
		circleProfile(0.1, 1.8, 0.25, 10),
		circleProfile(1.6, 0.5, 0.3, 10),
		circleProfile(-0.3, -1.6, 0.35, 12),
	}
	return { name = "SwissCheese", profiles = { { outer = outer, holes = holes } } }
end

local function makeLightning(): Shape
	local pts: { Vector2 } = {
		Vector2.new(-0.5, 3.0),
		Vector2.new(0.5, 3.0),
		Vector2.new(0.2, 1.5),
		Vector2.new(1.0, 1.5),
		Vector2.new(-0.3, -0.5),
		Vector2.new(0.4, -0.5),
		Vector2.new(-0.8, -3.0),
		Vector2.new(-1.2, -3.0),
		Vector2.new(-0.1, -0.8),
		Vector2.new(-0.8, -0.8),
		Vector2.new(0.5, 1.2),
		Vector2.new(-0.2, 1.2),
	}
	return { name = "Lightning", profiles = { { outer = pts } } }
end

local function makeThinCross(): Shape
	local arm = 0.18
	local len = COOKIE_RADIUS * 1.2
	local pts: { Vector2 } = {
		Vector2.new(-arm, -len),
		Vector2.new(arm, -len),
		Vector2.new(arm, -arm),
		Vector2.new(len, -arm),
		Vector2.new(len, arm),
		Vector2.new(arm, arm),
		Vector2.new(arm, len),
		Vector2.new(-arm, len),
		Vector2.new(-arm, arm),
		Vector2.new(-len, arm),
		Vector2.new(-len, -arm),
		Vector2.new(-arm, -arm),
	}
	return { name = "ThinCross", profiles = { { outer = pts } } }
end

local function makeGear(): Shape
	local nTeeth = 16
	local outerR = COOKIE_RADIUS
	local innerR = COOKIE_RADIUS * 0.75
	local toothHalfAngle = math.pi / nTeeth * 0.35
	local pts: { Vector2 } = {}
	for i = 0, nTeeth - 1 do
		local baseAngle = 2 * math.pi * i / nTeeth
		table.insert(pts, Vector2.new(innerR * math.cos(baseAngle - toothHalfAngle * 1.5), innerR * math.sin(baseAngle - toothHalfAngle * 1.5)))
		table.insert(pts, Vector2.new(outerR * math.cos(baseAngle - toothHalfAngle), outerR * math.sin(baseAngle - toothHalfAngle)))
		table.insert(pts, Vector2.new(outerR * math.cos(baseAngle + toothHalfAngle), outerR * math.sin(baseAngle + toothHalfAngle)))
		table.insert(pts, Vector2.new(innerR * math.cos(baseAngle + toothHalfAngle * 1.5), innerR * math.sin(baseAngle + toothHalfAngle * 1.5)))
	end
	local hole = circleProfile(0, 0, COOKIE_RADIUS * 0.3, 20)
	return { name = "Gear", profiles = { { outer = pts, holes = { hole } } } }
end

local function makeSnowflake(): Shape
	-- Inward notch + tip per arm (12 verts). Any extra “side branch” points off the notch–tip
	-- chord cross other arms and self-intersect, which breaks ear-clipping and corrupts the mesh.
	local pts: { Vector2 } = {}
	local nArms = 6
	local armLen = COOKIE_RADIUS * 1.1
	local notchR = COOKIE_RADIUS * 0.26

	for i = 0, nArms - 1 do
		local th = 2 * math.pi * i / nArms
		local notchBefore = th - math.pi / nArms
		table.insert(pts, Vector2.new(notchR * math.cos(notchBefore), notchR * math.sin(notchBefore)))
		table.insert(pts, Vector2.new(armLen * math.cos(th), armLen * math.sin(th)))
	end

	return { name = "Snowflake", profiles = { { outer = pts } } }
end

local function makeArrow(): Shape
	local pts: { Vector2 } = {
		-- Arrowhead (very acute tip)
		Vector2.new(0, 3.5),
		Vector2.new(1.8, 1.2),
		Vector2.new(0.3, 1.2),
		-- Thin shaft
		Vector2.new(0.3, -1.5),
		-- Tail flare
		Vector2.new(1.2, -1.5),
		Vector2.new(1.2, -2.5),
		Vector2.new(-1.2, -2.5),
		Vector2.new(-1.2, -1.5),
		-- Thin shaft left
		Vector2.new(-0.3, -1.5),
		Vector2.new(-0.3, 1.2),
		-- Arrowhead left
		Vector2.new(-1.8, 1.2),
	}
	return { name = "Arrow", profiles = { { outer = pts } } }
end

local function makeMaze(): Shape
	local s = COOKIE_RADIUS * 1.3
	local outer = rectProfile(0, 0, s * 2, s * 2)
	local w = 0.22
	-- Non-overlapping corridors only. (The previous layout had crossing slits; merged caps
	-- then triangulated a self-intersecting boundary, corrupting the mesh.)
	local holes = {
		rectProfile(0, s * 0.58, s * 1.55, w),
		rectProfile(0, -s * 0.58, s * 1.55, w),
		rectProfile(s * 0.48, 0, w, s * 0.72),
		rectProfile(-s * 0.48, 0, w, s * 0.72),
		rectProfile(0, 0, s * 0.55, w),
	}
	return { name = "Maze", profiles = { { outer = outer, holes = holes } } }
end

local function makeNestedRing(): Shape
	local profiles: { ShapeProfile } = {}
	-- Outer ring (large circle with hole)
	local outerOuter = circleProfile(0, 0, COOKIE_RADIUS * 1.2, 40)
	local outerHole = circleProfile(0, 0, COOKIE_RADIUS * 0.85, 32)
	table.insert(profiles, { outer = outerOuter, holes = { outerHole } })
	-- Middle ring (sits inside the outer ring's hole)
	local midOuter = circleProfile(0, 0, COOKIE_RADIUS * 0.7, 28)
	local midHole = circleProfile(0, 0, COOKIE_RADIUS * 0.45, 24)
	table.insert(profiles, { outer = midOuter, holes = { midHole } })
	-- Inner disc
	local innerOuter = circleProfile(0, 0, COOKIE_RADIUS * 0.3, 20)
	table.insert(profiles, { outer = innerOuter })
	return { name = "NestedRing", profiles = profiles }
end

local function makeButterfly(): Shape
	-- Simple closed outline (no self-intersections). The old path crossed itself and broke caps.
	local R = COOKIE_RADIUS * 0.9
	local bw = 0.4
	local pts: { Vector2 } = {
		Vector2.new(0, -R * 0.5),
		Vector2.new(-R * 0.35, -R * 0.25),
		Vector2.new(-R * 1.05, 0),
		Vector2.new(-R * 0.35, R * 0.25),
		Vector2.new(-bw, R * 0.45),
		Vector2.new(bw, R * 0.45),
		Vector2.new(R * 0.35, R * 0.25),
		Vector2.new(R * 1.05, 0),
		Vector2.new(R * 0.35, -R * 0.25),
		Vector2.new(bw, -R * 0.5),
	}
	return { name = "Butterfly", profiles = { { outer = pts } } }
end

local function makeSpikeCircle(): Shape
	-- Valley on the base circle + tip per spike (16 verts for 8 spikes). The old layout mixed
	-- off-circle spike sides with arc samples; those chords crossed other edges and corrupted caps.
	local nSpikes = 8
	local baseR = COOKIE_RADIUS * 0.72
	local tipR = baseR + COOKIE_RADIUS * 0.65
	local pts: { Vector2 } = {}

	for i = 0, nSpikes - 1 do
		local valleyAngle = 2 * math.pi * i / nSpikes - math.pi / nSpikes
		table.insert(pts, Vector2.new(baseR * math.cos(valleyAngle), baseR * math.sin(valleyAngle)))
		local tipAngle = 2 * math.pi * i / nSpikes
		table.insert(pts, Vector2.new(tipR * math.cos(tipAngle), tipR * math.sin(tipAngle)))
	end

	return { name = "SpikeCircle", profiles = { { outer = pts } } }
end

--------------------------------------------------------------------------------
-- Synthesized edge-case shapes (Phase 1 step 6).
--
-- Each shape targets a specific class of failure observed in the stack sweep:
--   Dumbbell       - stress the pinch-to-waist geometry (cf. Figure8 passes
--                     through 1→2 split; Dumbbell keeps a narrow body with
--                     minor-axis close to 2*inset).
--   TightHolePair  - two holes whose gap is about 2*inset, isolating the
--                     hole-hole merge threshold responsible for SwissCheese L1.
--   HoleNearEdge   - single hole ~2*inset from the outer boundary, isolating
--                     the hole-outer abutment failure in arrangementSubtract.
--   PlusSign       - thicker + cross (arms at COOKIE_RADIUS*0.55 width) to
--                     contrast with ThinCross (arm 0.18); verifies whether
--                     ThinCross F6 is an arm-width threshold or a topology bug.
--   SharpChevron   - single V with interior angle <= 20° at the hinge, to
--                     isolate the acute-angle sharpening path that Heart L6+
--                     and Star L6 exercise but mix with other concerns.
--   NestedHoles    - outer ring + inside that ring a second island with its
--                     own hole (2 profiles). Stresses the multi-island
--                     topology classification in PolygonNesting.
--   ScaleSweep     - same Comb-ish geometry at 3 sizes (small 0.5*, medium 1*,
--                     large 1.6*); inset is computed from cookie diagonal so
--                     the relative inset is constant while absolute arm width
--                     varies, isolating scale-dependent thresholds.
--------------------------------------------------------------------------------

local function makeDumbbell(): Shape
	-- Two circles (r=1.2) centered at x=±1.8 joined by a waist of height 0.3.
	-- Total width 6.0, waist-half-height 0.15 (~5% of diagonal).
	local leftR, rightR = 1.2, 1.2
	local leftCx, rightCx = -1.8, 1.8
	local waistHY = 0.15
	local pts: { Vector2 } = {}
	local nArc = 20
	-- Right lobe from -pi/2 to +pi/2 (CCW outer boundary, going counter-clockwise)
	for i = 0, nArc do
		local a = -math.pi / 2 + math.pi * i / nArc
		table.insert(pts, Vector2.new(rightCx + rightR * math.cos(a), rightR * math.sin(a)))
	end
	-- Top waist edge
	table.insert(pts, Vector2.new(leftCx, waistHY))
	-- Left lobe from +pi/2 to +3pi/2 (continuing CCW)
	for i = 0, nArc do
		local a = math.pi / 2 + math.pi * i / nArc
		table.insert(pts, Vector2.new(leftCx + leftR * math.cos(a), leftR * math.sin(a)))
	end
	-- Bottom waist edge
	table.insert(pts, Vector2.new(rightCx, -waistHY))
	return { name = "Dumbbell", profiles = { { outer = pts } } }
end

local function makeTightHolePair(): Shape
	-- Outer square (w=5), two circular holes of radius 0.6 centered at x=±0.7.
	-- Hole centers 1.4 apart, hole edges 0.2 apart: gap < 2% diag (0.14).
	local outer = rectProfile(0, 0, 5, 5)
	local holes = {
		circleProfile(-0.7, 0, 0.6, 16),
		circleProfile(0.7, 0, 0.6, 16),
	}
	return { name = "TightHolePair", profiles = { { outer = outer, holes = holes } } }
end

local function makeHoleNearEdge(): Shape
	-- Outer rect (w=5,h=4); hole circle r=0.5 with center at (+1.8, 0),
	-- leaving 0.2 clearance from the right edge.
	local outer = rectProfile(0, 0, 5, 4)
	local holes = {
		circleProfile(1.8, 0, 0.5, 16),
	}
	return { name = "HoleNearEdge", profiles = { { outer = outer, holes = holes } } }
end

local function makePlusSign(): Shape
	-- Symmetric + cross with arm width 1.0 and arm length 2.5.
	-- Contrast with ThinCross (arm 0.18, len 3.6): arm_width/diag = 0.17 here
	-- vs 0.035 for ThinCross.
	local arm = 0.5
	local len = 2.5
	local pts: { Vector2 } = {
		Vector2.new(-arm, -len),
		Vector2.new(arm, -len),
		Vector2.new(arm, -arm),
		Vector2.new(len, -arm),
		Vector2.new(len, arm),
		Vector2.new(arm, arm),
		Vector2.new(arm, len),
		Vector2.new(-arm, len),
		Vector2.new(-arm, arm),
		Vector2.new(-len, arm),
		Vector2.new(-len, -arm),
		Vector2.new(-arm, -arm),
	}
	return { name = "PlusSign", profiles = { { outer = pts } } }
end

local function makeSharpChevron(): Shape
	-- V-shape with interior angle ~24° at the bottom outer apex (very acute).
	-- 6-vertex CCW outer walking: apex -> right OUTER tip -> right INNER tip ->
	-- fork -> left INNER tip -> left OUTER tip -> apex.
	-- armPt(side,along,across>0) is the arm's OUTER-side point (larger |x|),
	-- armPt(side,along,across<0) is the arm's INNER-side point.
	local armW = 0.4
	local armL = 3.0
	local openHalf = math.rad(12) -- half-opening angle
	local sinH, cosH = math.sin(openHalf), math.cos(openHalf)
	local function armPt(side: number, along: number, across: number): Vector2
		local axisX, axisY = side * sinH, cosH
		local normX, normY = side * cosH, -sinH
		return Vector2.new(along * axisX + across * normX, along * axisY + across * normY)
	end
	local tFork = armW / (2 * math.tan(openHalf))
	local forkY = tFork * cosH + (armW / 2) * sinH
	local pts: { Vector2 } = {
		Vector2.new(0, 0),                         -- 1. bottom outer apex
		armPt(1, armL, armW / 2),                  -- 2. right arm tip, OUTER edge
		armPt(1, armL, -armW / 2),                 -- 3. right arm tip, INNER edge
		Vector2.new(0, forkY),                     -- 4. inner fork apex
		armPt(-1, armL, -armW / 2),                -- 5. left arm tip, INNER edge
		armPt(-1, armL, armW / 2),                 -- 6. left arm tip, outer edge
	}
	return { name = "SharpChevron", profiles = { { outer = pts } } }
end

local function makeNestedHoles(): Shape
	-- Profile 1: ring (outer r=3, hole r=2.4).
	-- Profile 2: disc with its own hole (outer r=1.8, hole r=1.0), placed at
	-- origin so it sits inside the ring's hole but disconnected from the ring.
	local profiles: { ShapeProfile } = {}
	local ringOuter = circleProfile(0, 0, 3.0, 40)
	local ringHole = circleProfile(0, 0, 2.4, 32)
	table.insert(profiles, { outer = ringOuter, holes = { ringHole } })
	local discOuter = circleProfile(0, 0, 1.8, 32)
	local discHole = circleProfile(0, 0, 1.0, 24)
	table.insert(profiles, { outer = discOuter, holes = { discHole } })
	return { name = "NestedHoles", profiles = profiles }
end

local function makeScaleSweep(): Shape
	-- Three scaled copies of a 4-tooth comb-ish profile at 0.5×, 1×, 1.6× scale,
	-- placed with 0.8 offset so they fit in one grid cell. Each copy exercises
	-- the same geometry class at a different absolute arm width; with inset
	-- being diag% of each part's own bbox, this isolates scale-dependent
	-- thresholds (the same % inset produces proportionally identical regions
	-- *if* the offset is scale-invariant, which Phase 1 seed evidence suggests
	-- it is not for thin features).
	local function comb(scale: number): { Vector2 }
		local base = 1.2 * scale
		local toothW = 0.25 * scale
		local toothH = 0.6 * scale
		local gap = 0.2 * scale
		local nTeeth = 4
		local totalTop = nTeeth * toothW + (nTeeth - 1) * gap
		local leftX = -totalTop / 2
		local pts: { Vector2 } = {
			Vector2.new(-totalTop / 2 - 0.2 * scale, -base / 2),
			Vector2.new(totalTop / 2 + 0.2 * scale, -base / 2),
			Vector2.new(totalTop / 2 + 0.2 * scale, base / 2),
		}
		for i = nTeeth - 1, 0, -1 do
			local xR = leftX + (i + 1) * toothW + i * gap
			local xL = leftX + i * toothW + i * gap
			table.insert(pts, Vector2.new(xR, base / 2))
			table.insert(pts, Vector2.new(xR, base / 2 + toothH))
			table.insert(pts, Vector2.new(xL, base / 2 + toothH))
			table.insert(pts, Vector2.new(xL, base / 2))
		end
		table.insert(pts, Vector2.new(-totalTop / 2 - 0.2 * scale, base / 2))
		return pts
	end
	local profiles: { ShapeProfile } = {
		{ outer = comb(0.5) },
		{ outer = comb(1.0) },
		{ outer = comb(1.6) },
	}
	return { name = "ScaleSweep", profiles = profiles }
end

--------------------------------------------------------------------------------
-- Wave 4: significantly harder cookies.
--
-- These stress the frosting pipeline with:
--   * many holes per outer (14+),
--   * mixed hole shapes in a single cookie (circle / square / diamond /
--     triangle / pentagon / star / plus),
--   * multiple disconnected islands that each carry their own holes,
--   * regular lattices that exercise hole-hole and hole-edge thresholds at
--     many positions simultaneously.
--------------------------------------------------------------------------------

local function makeMixedHoles(): Shape
	-- Square outer with six differently-shaped holes. Stresses the hole
	-- normalization / nesting pipeline with a variety of hole primitives in
	-- a single mesh.
	local outer = rectProfile(0, 0, 7, 7)
	local holes = {
		circleProfile(0, 0, 0.8, 20),                          -- center circle
		diamondProfile(-2.2, 2.2, 1.4, 1.4),                   -- NW diamond
		regularPolygonProfile(2.2, 2.2, 0.9, 3, math.pi / 2),  -- NE triangle
		rectProfile(-2.2, -2.2, 1.3, 1.3),                     -- SW square
		starProfileAt(2.2, -2.2, 0.9, 0.4, 5),                 -- SE star
		regularPolygonProfile(0, 2.5, 0.7, 5, math.pi / 2),    -- N pentagon
	}
	return { name = "MixedHoles", profiles = { { outer = outer, holes = holes } } }
end

local function makeArchipelago(): Shape
	-- Seven disconnected islands of distinct primitive shapes, laid out at
	-- explicit positions so the frosting pipeline sees a classic multi-island
	-- input with no overlapping bounding boxes.
	return {
		name = "Archipelago",
		noOffset = true,
		profiles = {
			{ outer = circleProfile(-2.5, 2, 0.9, 20) },
			{ outer = rectProfile(2.5, 2, 1.5, 1.5) },
			{ outer = regularPolygonProfile(-2.5, -2, 1.0, 3, math.pi / 2) },
			{ outer = diamondProfile(2.5, -2, 1.6, 1.6) },
			{ outer = regularPolygonProfile(0, 2.5, 0.8, 5, math.pi / 2) },
			{ outer = starProfileAt(0, -2.5, 1.0, 0.4, 5) },
			{ outer = regularPolygonProfile(0, 0, 0.9, 6) },
		},
	}
end

local function makeHoleyArchipelago(): Shape
	-- Three disconnected islands where every island carries its own holes.
	-- Combines multi-island topology with per-island hole nesting.
	local leftOuter = circleProfile(-3, 0, 1.5, 32)
	local leftHoles = {
		circleProfile(-3.4, 0.5, 0.3, 14),
		circleProfile(-2.7, -0.4, 0.35, 14),
		rectProfile(-3, 0, 0.5, 0.3),
	}
	local midOuter = regularPolygonProfile(0, 0, 1.3, 6)
	local midHoles = {
		diamondProfile(-0.4, 0, 0.6, 0.6),
		circleProfile(0.45, 0, 0.28, 14),
	}
	local rightOuter = regularPolygonProfile(3, -0.3, 1.6, 3, math.pi / 2)
	local rightHoles = {
		circleProfile(3, 0, 0.4, 14),
	}
	return {
		name = "HoleyArchipelago",
		noOffset = true,
		profiles = {
			{ outer = leftOuter, holes = leftHoles },
			{ outer = midOuter, holes = midHoles },
			{ outer = rightOuter, holes = rightHoles },
		},
	}
end

local function makeDiamondLattice(): Shape
	-- 4x3 grid of diamond-shaped holes in a large rect. Each column / row
	-- exercises hole-hole spacing simultaneously at twelve sites.
	local outer = rectProfile(0, 0, 8, 6)
	local holes: { { Vector2 } } = {}
	local cols = { -2.7, -0.9, 0.9, 2.7 }
	local rows = { -2, 0, 2 }
	for _, x in cols do
		for _, z in rows do
			table.insert(holes, diamondProfile(x, z, 0.8, 0.8))
		end
	end
	return { name = "DiamondLattice", profiles = { { outer = outer, holes = holes } } }
end

local function makeStarburstHoles(): Shape
	-- Large five-point star with a small circular hole placed inside each
	-- tip and a diamond hole at the center. Tests holes near acute star
	-- features combined with a central void.
	local outer: { Vector2 } = {}
	local nPoints = 5
	local rOut = 3.2
	local rIn = 1.35
	for i = 0, nPoints * 2 - 1 do
		local a = math.pi / 2 + 2 * math.pi * i / (nPoints * 2)
		local r = if i % 2 == 0 then rOut else rIn
		table.insert(outer, Vector2.new(r * math.cos(a), r * math.sin(a)))
	end
	local holes: { { Vector2 } } = {}
	for i = 0, nPoints - 1 do
		local a = math.pi / 2 + 2 * math.pi * i / nPoints
		local cx = 2.1 * math.cos(a)
		local cz = 2.1 * math.sin(a)
		table.insert(holes, circleProfile(cx, cz, 0.35, 14))
	end
	table.insert(holes, diamondProfile(0, 0, 0.9, 0.9))
	return { name = "StarburstHoles", profiles = { { outer = outer, holes = holes } } }
end

local function makeHoneycomb(): Shape
	-- Hexagonal outer with a honeycomb of 1 + 6 smaller hexagonal holes.
	local outer = regularPolygonProfile(0, 0, 3.3, 6, math.pi / 6)
	local holes: { { Vector2 } } = {}
	table.insert(holes, regularPolygonProfile(0, 0, 0.7, 6, math.pi / 6))
	for i = 0, 5 do
		local a = math.pi / 6 + 2 * math.pi * i / 6
		local cx = 1.75 * math.cos(a)
		local cz = 1.75 * math.sin(a)
		table.insert(holes, regularPolygonProfile(cx, cz, 0.65, 6, math.pi / 6))
	end
	return { name = "Honeycomb", profiles = { { outer = outer, holes = holes } } }
end

local function makeChainLinks(): Shape
	-- Four disconnected ring-like pieces in a row. Each piece is a small
	-- donut, so the shape combines multi-island topology with per-island
	-- holes at every island.
	local profiles: { ShapeProfile } = {}
	for i = 0, 3 do
		local cx = -3 + i * 2
		table.insert(profiles, {
			outer = circleProfile(cx, 0, 0.9, 24),
			holes = { circleProfile(cx, 0, 0.5, 18) },
		})
	end
	return { name = "ChainLinks", noOffset = true, profiles = profiles }
end

local function makeFractalPlus(): Shape
	-- Large plus outline with four smaller plus-shaped holes placed one per
	-- arm, and a central diamond hole.
	local outer = plusProfile(0, 0, 3.2, 1.0)
	local holes = {
		plusProfile(2.2, 0, 0.6, 0.2),
		plusProfile(-2.2, 0, 0.6, 0.2),
		plusProfile(0, 2.2, 0.6, 0.2),
		plusProfile(0, -2.2, 0.6, 0.2),
		diamondProfile(0, 0, 0.8, 0.8),
	}
	return { name = "FractalPlus", profiles = { { outer = outer, holes = holes } } }
end

local function makeDenseMultiHole(): Shape
	-- 7x7 rect densely packed with 13 mixed-shape holes. Intentionally
	-- pushes the hole count and variety well beyond SwissCheese.
	local outer = rectProfile(0, 0, 7, 7)
	local holes = {
		starProfileAt(-2.5, 2.5, 0.55, 0.22, 5),
		diamondProfile(2.5, 2.5, 1.0, 1.0),
		rectProfile(-2.5, -2.5, 1.0, 1.0),
		regularPolygonProfile(2.5, -2.5, 0.6, 3, math.pi / 2),
		circleProfile(0, 2.5, 0.5, 16),
		circleProfile(0, -2.5, 0.5, 16),
		rectProfile(-2.5, 0, 0.9, 0.9),
		diamondProfile(2.5, 0, 1.0, 1.0),
		circleProfile(0, 0, 0.5, 16),
		regularPolygonProfile(-1.2, 1.2, 0.35, 3, math.pi / 2),
		diamondProfile(1.2, 1.2, 0.5, 0.5),
		circleProfile(-1.2, -1.2, 0.35, 14),
		starProfileAt(1.2, -1.2, 0.35, 0.15, 5),
	}
	return { name = "DenseMultiHole", profiles = { { outer = outer, holes = holes } } }
end

local function makeMultiIslandComplex(): Shape
	-- Four disconnected islands, each carrying several mixed-shape holes.
	-- Combines archipelago topology with Swiss-cheese-style hole density on
	-- every island.
	local nwOuter = circleProfile(-2.5, 2.5, 1.4, 28)
	local nwHoles = {
		diamondProfile(-2.8, 2.8, 0.5, 0.5),
		rectProfile(-2.2, 2.2, 0.5, 0.5),
		circleProfile(-2.5, 2.5, 0.25, 14),
	}
	local neOuter = rectProfile(2.5, 2.5, 2.6, 2.6)
	local neHoles = {
		circleProfile(2.0, 2.8, 0.35, 14),
		circleProfile(3.0, 2.0, 0.35, 14),
		regularPolygonProfile(2.8, 2.2, 0.4, 3, math.pi / 2),
	}
	local swOuter = regularPolygonProfile(-2.5, -2.5, 1.5, 5, math.pi / 2)
	local swHoles = {
		circleProfile(-2.9, -2.2, 0.25, 14),
		circleProfile(-2.1, -2.2, 0.25, 14),
		circleProfile(-2.5, -2.9, 0.25, 14),
	}
	local seOuter = regularPolygonProfile(2.5, -2.5, 1.5, 6)
	local seHoles = {
		starProfileAt(2.5, -2.5, 0.7, 0.3, 5),
	}
	return {
		name = "MultiIslandComplex",
		noOffset = true,
		profiles = {
			{ outer = nwOuter, holes = nwHoles },
			{ outer = neOuter, holes = neHoles },
			{ outer = swOuter, holes = swHoles },
			{ outer = seOuter, holes = seHoles },
		},
	}
end

local ALL_SHAPES: { () -> Shape } = {
	makeCircle,
	makeStar,
	makeLShape,
	makeUShape,
	makeThinRect,
	makeCrescent,
	makeDonut,
	makeMultiHole,
	makeTwoDiscs,
	makeFigure8,
	makeHeart,
	makeComb,
	-- Wave 2
	makeSwissCheese,
	makeLightning,
	makeThinCross,
	makeGear,
	makeSnowflake,
	makeArrow,
	makeMaze,
	makeNestedRing,
	makeButterfly,
	makeSpikeCircle,
	-- Wave 3 - Phase 1 synthesized edge cases
	makeDumbbell,
	makeTightHolePair,
	makeHoleNearEdge,
	makePlusSign,
	makeSharpChevron,
	makeNestedHoles,
	makeScaleSweep,
	-- Wave 4 - significantly harder cookies
	makeMixedHoles,
	makeArchipelago,
	makeHoleyArchipelago,
	makeDiamondLattice,
	makeStarburstHoles,
	makeHoneycomb,
	makeChainLinks,
	makeFractalPlus,
	makeDenseMultiHole,
	makeMultiIslandComplex,
}

local function generateAll()
	local folder = Instance.new("Folder")
	folder.Name = "TestCookies"
	folder.Parent = workspace

	local cols = 4
	for i, shapeFn in ALL_SHAPES do
		local shape = shapeFn()

		local col = ((i - 1) % cols)
		local row = math.floor((i - 1) / cols)
		local baseX = col * GRID_SPACING
		local baseZ = row * GRID_SPACING

		for pi, profile in shape.profiles do
			local part = extrudeProfile(profile, COOKIE_HEIGHT)
			part.Name = shape.name .. (if #shape.profiles > 1 then "_" .. pi else "")
			part.Anchored = true
			part.Color = Color3.fromRGB(210, 170, 109) -- cookie brown
			part.Material = Enum.Material.SmoothPlastic

			-- Offset for disconnected pieces within a shape. Archipelago-style
			-- shapes (noOffset) already place each island at distinct local
			-- coordinates, so the extra offset just smears the layout.
			local offsetX = if #shape.profiles > 1 and not shape.noOffset
				then (pi - 1) * 0.5
				else 0
			part.CFrame = CFrame.new(baseX + offsetX, COOKIE_HEIGHT / 2, baseZ)
			part.Parent = folder
		end
	end
end

return {
	generateAll = generateAll,
}
