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

			-- Offset for disconnected pieces within a shape
			local offsetX = if #shape.profiles > 1 then (pi - 1) * 0.5 else 0
			part.CFrame = CFrame.new(baseX + offsetX, COOKIE_HEIGHT / 2, baseZ)
			part.Parent = folder
		end
	end
end

return {
	generateAll = generateAll,
}
