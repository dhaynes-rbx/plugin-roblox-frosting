--!strict

-- Phase 2 atomic test harness.
--
-- Exposes two globals:
--   _G.__frosting_tests__()        - 2D-only tests against PolygonOffset.
--   _G.__frosting_mesh_tests__()   - full-pipeline (build+re-extract) tests.
--
-- Each test compares expected ranges to observed values and records pass/fail
-- with a short diagnostic.  The harness is read-only (does not construct or
-- destroy Instances for the 2D suite) and runs entirely inside Studio via
-- execute_luau.
--
-- Test selection mirrors the atomic reproducers from Phase 1 in
-- docs/frosting-failures.md: HoleNearEdge 2%, TightHolePair 2%, SharpChevron 2%,
-- Star L0..L6 (iterated 2D), U-Shape L6 (iterated 2D), Arrow L1 mesh round-trip,
-- Maze L1 mesh round-trip, Comb L1 mesh round-trip.

local PolygonOffset = require(script.Parent.Parent.PolygonOffset)
local PolygonInset = require(script.Parent.Parent.PolygonInset)
local TopFaceExtractor = require(script.Parent.Parent.TopFaceExtractor)

--------------------------------------------------------------------------------
-- Primitive profile constructors (kept separate from TestCookieGenerator so
-- the harness has no dependency on the plugin UI path or cookie extrusion).
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
-- Shape factories for the 2D suite
--------------------------------------------------------------------------------

local function shapeHoleNearEdge(): PolygonOffset.PolygonWithHoles
	return {
		outer = rectProfile(0, 0, 5, 4),
		holes = { circleProfile(1.8, 0, 0.5, 16) },
	}
end

local function shapeTightHolePair(): PolygonOffset.PolygonWithHoles
	return {
		outer = rectProfile(0, 0, 5, 5),
		holes = {
			circleProfile(-0.7, 0, 0.6, 16),
			circleProfile(0.7, 0, 0.6, 16),
		},
	}
end

local function shapeSharpChevron(): PolygonOffset.PolygonWithHoles
	-- Simple V-chevron with a ~24° acute outer apex and a reflex fork apex.
	-- CCW traversal starting at the bottom apex:
	--   apex -> right-arm OUTER tip -> right-arm INNER tip -> fork apex ->
	--   left-arm INNER tip -> left-arm OUTER tip -> apex.
	local armW, armL = 0.4, 3.0
	local openHalf = math.rad(12)
	local sinH, cosH = math.sin(openHalf), math.cos(openHalf)
	local function armPt(side: number, along: number, across: number): Vector2
		local axisX, axisY = side * sinH, cosH
		local normX, normY = side * cosH, -sinH
		return Vector2.new(along * axisX + across * normX, along * axisY + across * normY)
	end
	local tFork = armW / (2 * math.tan(openHalf))
	local forkY = tFork * cosH + (armW / 2) * sinH
	return {
		outer = {
			Vector2.new(0, 0),
			armPt(1, armL, armW / 2),   -- right OUTER tip (side+1, across>0 -> larger x)
			armPt(1, armL, -armW / 2),  -- right INNER tip
			Vector2.new(0, forkY),
			armPt(-1, armL, -armW / 2), -- left INNER tip (side-1, across<0 -> smaller |x|)
			armPt(-1, armL, armW / 2),  -- left OUTER tip
		},
		holes = {},
	}
end

local function shapeStar(): PolygonOffset.PolygonWithHoles
	local pts: { Vector2 } = {}
	local nPoints = 5
	local R = 3
	for i = 0, nPoints * 2 - 1 do
		local a = math.pi / 2 + 2 * math.pi * i / (nPoints * 2)
		local r = if i % 2 == 0 then R else R * 0.35
		table.insert(pts, Vector2.new(r * math.cos(a), r * math.sin(a)))
	end
	return { outer = pts, holes = {} }
end

local function shapeUShape(): PolygonOffset.PolygonWithHoles
	local w = 6
	local h = 6
	local armW = w * 0.3
	local channelH = h * 0.6
	return {
		outer = {
			Vector2.new(-w / 2, -h / 2),
			Vector2.new(w / 2, -h / 2),
			Vector2.new(w / 2, h / 2),
			Vector2.new(w / 2 - armW, h / 2),
			Vector2.new(w / 2 - armW, -h / 2 + (h - channelH)),
			Vector2.new(-w / 2 + armW, -h / 2 + (h - channelH)),
			Vector2.new(-w / 2 + armW, h / 2),
			Vector2.new(-w / 2, h / 2),
		},
		holes = {},
	}
end

local function shapeThinCross(): PolygonOffset.PolygonWithHoles
	local arm = 0.18
	local len = 3 * 1.2
	return {
		outer = {
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
		},
		holes = {},
	}
end

local function shapeSnowflake(): PolygonOffset.PolygonWithHoles
	local pts: { Vector2 } = {}
	local nArms = 6
	local armLen = 3 * 1.1
	local notchR = 3 * 0.26
	for i = 0, nArms - 1 do
		local th = 2 * math.pi * i / nArms
		local notchBefore = th - math.pi / nArms
		table.insert(pts, Vector2.new(notchR * math.cos(notchBefore), notchR * math.sin(notchBefore)))
		table.insert(pts, Vector2.new(armLen * math.cos(th), armLen * math.sin(th)))
	end
	return { outer = pts, holes = {} }
end

local function shapeSwissCheese(): PolygonOffset.PolygonWithHoles
	return {
		outer = circleProfile(0, 0, 3 * 1.1, 40),
		holes = {
			circleProfile(-1.5, 1.0, 0.45, 12),
			circleProfile(0.8, 1.3, 0.35, 12),
			circleProfile(-0.5, -0.3, 0.55, 14),
			circleProfile(1.2, -0.6, 0.4, 12),
			circleProfile(-1.3, -1.2, 0.3, 10),
			circleProfile(0.1, 1.8, 0.25, 10),
			circleProfile(1.6, 0.5, 0.3, 10),
			circleProfile(-0.3, -1.6, 0.35, 12),
		},
	}
end

local function shapeGear(): PolygonOffset.PolygonWithHoles
	local nTeeth = 16
	local outerR = 3
	local innerR = 3 * 0.75
	local toothHalfAngle = math.pi / nTeeth * 0.35
	local pts: { Vector2 } = {}
	for i = 0, nTeeth - 1 do
		local baseAngle = 2 * math.pi * i / nTeeth
		table.insert(pts, Vector2.new(innerR * math.cos(baseAngle - toothHalfAngle * 1.5), innerR * math.sin(baseAngle - toothHalfAngle * 1.5)))
		table.insert(pts, Vector2.new(outerR * math.cos(baseAngle - toothHalfAngle), outerR * math.sin(baseAngle - toothHalfAngle)))
		table.insert(pts, Vector2.new(outerR * math.cos(baseAngle + toothHalfAngle), outerR * math.sin(baseAngle + toothHalfAngle)))
		table.insert(pts, Vector2.new(innerR * math.cos(baseAngle + toothHalfAngle * 1.5), innerR * math.sin(baseAngle + toothHalfAngle * 1.5)))
	end
	local hole = circleProfile(0, 0, 3 * 0.3, 20)
	return { outer = pts, holes = { hole } }
end

local function shapeMaze(): PolygonOffset.PolygonWithHoles
	local s = 3 * 1.3
	local w = 0.22
	return {
		outer = rectProfile(0, 0, s * 2, s * 2),
		holes = {
			rectProfile(0, s * 0.58, s * 1.55, w),
			rectProfile(0, -s * 0.58, s * 1.55, w),
			rectProfile(s * 0.48, 0, w, s * 0.72),
			rectProfile(-s * 0.48, 0, w, s * 0.72),
			rectProfile(0, 0, s * 0.55, w),
		},
	}
end

local function shapeDonut(): PolygonOffset.PolygonWithHoles
	return {
		outer = circleProfile(0, 0, 3, 40),
		holes = { circleProfile(0, 0, 3 * 0.55, 32) },
	}
end

local function shapeComb(): PolygonOffset.PolygonWithHoles
	-- Matches the existing `Comb` generator (6 teeth, tall thin arms).
	local base = 1.8
	local toothW = 0.4
	local toothH = 1.5
	local gap = 0.25
	local nTeeth = 6
	local totalTop = nTeeth * toothW + (nTeeth - 1) * gap
	local leftX = -totalTop / 2
	local pts: { Vector2 } = {
		Vector2.new(-totalTop / 2 - 0.25, -base / 2),
		Vector2.new(totalTop / 2 + 0.25, -base / 2),
		Vector2.new(totalTop / 2 + 0.25, base / 2),
	}
	for i = nTeeth - 1, 0, -1 do
		local xR = leftX + (i + 1) * toothW + i * gap
		local xL = leftX + i * toothW + i * gap
		table.insert(pts, Vector2.new(xR, base / 2))
		table.insert(pts, Vector2.new(xR, base / 2 + toothH))
		table.insert(pts, Vector2.new(xL, base / 2 + toothH))
		table.insert(pts, Vector2.new(xL, base / 2))
	end
	table.insert(pts, Vector2.new(-totalTop / 2 - 0.25, base / 2))
	return { outer = pts, holes = {} }
end

--------------------------------------------------------------------------------
-- Geometry primitives used by the assertions
--------------------------------------------------------------------------------

local function signedArea(pts: { Vector2 }): number
	local n = #pts
	if n < 3 then return 0 end
	local s = 0
	local j = n
	for i = 1, n do
		s += (pts[j].X + pts[i].X) * (pts[j].Y - pts[i].Y)
		j = i
	end
	return -0.5 * s
end

local function pwhArea(pwh: PolygonOffset.PolygonWithHoles): number
	local a = math.abs(signedArea(pwh.outer))
	for _, h in pwh.holes do
		a -= math.abs(signedArea(h))
	end
	return a
end

local function bbox(pts: { Vector2 }): (number, number, number, number)
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	for _, p in pts do
		if p.X < minX then minX = p.X end
		if p.X > maxX then maxX = p.X end
		if p.Y < minY then minY = p.Y end
		if p.Y > maxY then maxY = p.Y end
	end
	return minX, maxX, minY, maxY
end

local function diag(pts: { Vector2 }): number
	local minX, maxX, minY, maxY = bbox(pts)
	local dx = maxX - minX
	local dy = maxY - minY
	return math.sqrt(dx * dx + dy * dy)
end

local function minInteriorAngleDeg(pts: { Vector2 }): number
	local n = #pts
	if n < 3 then return 0 end
	local best = 180
	for i = 1, n do
		local prev = pts[((i - 2) % n) + 1]
		local cur = pts[i]
		local nxt = pts[(i % n) + 1]
		local a = prev - cur
		local b = nxt - cur
		if a.Magnitude < 1e-12 or b.Magnitude < 1e-12 then continue end
		local dot = math.clamp((a.X * b.X + a.Y * b.Y) / (a.Magnitude * b.Magnitude), -1, 1)
		local ang = math.deg(math.acos(dot))
		if ang < best then best = ang end
	end
	return best
end

-- Axis-aligned bbox containment (region bbox ⊆ island bbox + margin).
local function bboxContains(inner: { Vector2 }, outer: { Vector2 }, margin: number): boolean
	local iMinX, iMaxX, iMinY, iMaxY = bbox(inner)
	local oMinX, oMaxX, oMinY, oMaxY = bbox(outer)
	return iMinX >= oMinX - margin
		and iMaxX <= oMaxX + margin
		and iMinY >= oMinY - margin
		and iMaxY <= oMaxY + margin
end

--------------------------------------------------------------------------------
-- Test runner primitives
--------------------------------------------------------------------------------

type Result = {
	name: string,
	pass: boolean,
	message: string,
}

local function run2DOffset(pwh: PolygonOffset.PolygonWithHoles, insetFrac: number): {
	regionCount: number,
	holeCount: number,
	regionArea: number,
	islandArea: number,
	minAngleDeg: number,
	regionBBoxFits: boolean,
	regions: { PolygonOffset.PolygonWithHoles },
}
	local islandDiag = diag(pwh.outer)
	local insetAmount = islandDiag * insetFrac
	local regions = PolygonOffset.offsetPWH(pwh, insetAmount)
	local rArea = 0
	local hCount = 0
	local minAngle = 180
	for _, r in regions do
		rArea += pwhArea(r)
		hCount += #r.holes
		local ma = minInteriorAngleDeg(r.outer)
		if ma < minAngle then minAngle = ma end
	end
	local regionFits = true
	for _, r in regions do
		if not bboxContains(r.outer, pwh.outer, 1e-4) then
			regionFits = false
			break
		end
	end
	return {
		regionCount = #regions,
		holeCount = hCount,
		regionArea = rArea,
		islandArea = pwhArea(pwh),
		minAngleDeg = if minAngle == 180 then 0 else minAngle,
		regionBBoxFits = regionFits,
		regions = regions,
	}
end

-- Iteratively offset a pwh N times.  At each layer, collect the full
-- {regionCount, totalArea, minAngle}.  Continues as long as the offset
-- produces at least one region.  Returns the list of per-layer records.
local function iterate2D(pwh: PolygonOffset.PolygonWithHoles, insetFrac: number, maxLayers: number): {
	{ layer: number, regions: number, totalArea: number, minAngle: number, regionBBoxFits: boolean }
}
	local log = {}
	local cur = { pwh }
	for layer = 1, maxLayers do
		local nextLayer: { PolygonOffset.PolygonWithHoles } = {}
		local totalRegions = 0
		local totalArea = 0
		local minAngle = 180
		local regionFits = true
		for _, island in cur do
			local res = run2DOffset(island, insetFrac)
			totalRegions += res.regionCount
			totalArea += res.regionArea
			if res.minAngleDeg < minAngle then minAngle = res.minAngleDeg end
			if not res.regionBBoxFits then regionFits = false end
			for _, r in res.regions do
				table.insert(nextLayer, r)
			end
		end
		table.insert(log, {
			layer = layer,
			regions = totalRegions,
			totalArea = totalArea,
			minAngle = if minAngle == 180 then 0 else minAngle,
			regionBBoxFits = regionFits,
		})
		if totalRegions == 0 then break end
		cur = nextLayer
	end
	return log
end

local function fmt(v: number, places: number?): string
	local p = places or 3
	return string.format("%." .. tostring(p) .. "f", v)
end

--------------------------------------------------------------------------------
-- 2D test cases
--------------------------------------------------------------------------------

local function assertTest(name: string, pass: boolean, message: string): Result
	return { name = name, pass = pass, message = message }
end

local function testHoleNearEdge(): Result
	-- When the hole outset pokes past the outer inset, the correct topology is
	-- a single pacman-shaped outer with no inner hole.  We verify that
	--   * exactly 1 region is returned
	--   * it has 0 inner holes (notch-into-outer topology)
	--   * area matches the pacman area ~= outer - (hole cap inside outer)
	--   * the original hole center (1.8, 0) is NOT inside the outer
	local res = run2DOffset(shapeHoleNearEdge(), 0.02)
	local r = res.regions[1]
	local notched = false
	if r then
		local n = #r.outer
		local inside = false
		local j = n
		local px, py = 1.8, 0
		for i = 1, n do
			local pi = r.outer[i]
			local pj = r.outer[j]
			if (pi.Y > py) ~= (pj.Y > py) then
				local xHit = pi.X + (py - pi.Y) / (pj.Y - pi.Y) * (pj.X - pi.X)
				if px < xHit then inside = not inside end
			end
			j = i
		end
		notched = not inside
	end
	local pass = res.regionCount == 1 and res.holeCount == 0 and notched
		and res.regionArea >= 15 and res.regionArea <= 18
	return assertTest(
		"HoleNearEdge 2% (notch topology correct)",
		pass,
		string.format(
			"regions=%d holes=%d area=%s notched=%s (expect 1/0/~16.5/notched=true)",
			res.regionCount, res.holeCount, fmt(res.regionArea), tostring(notched)
		)
	)
end

local function testTightHolePair(): Result
	-- At 1% inset (2*inset = 0.14 < gap 0.20), holes stay separate.
	-- At 2% inset (2*inset = 0.28 > gap 0.20), holes correctly merge into 1.
	-- We test the 1% case to catch any over-eager hole merger.
	local res1 = run2DOffset(shapeTightHolePair(), 0.01)
	local pass1 = res1.regionCount == 1 and res1.holeCount == 2
	local res2 = run2DOffset(shapeTightHolePair(), 0.02)
	local pass2 = res2.regionCount == 1 and res2.holeCount == 1 -- correct merger
	return assertTest(
		"TightHolePair 1% and 2% (F2: hole preservation and clean merge)",
		pass1 and pass2,
		string.format(
			"1%%: regions=%d holes=%d (expected 1/2); 2%%: regions=%d holes=%d (expected 1/1 merged)",
			res1.regionCount, res1.holeCount, res2.regionCount, res2.holeCount
		)
	)
end

local function testSharpChevron(): Result
	local res = run2DOffset(shapeSharpChevron(), 0.02)
	local noOvershoot = res.regionArea <= res.islandArea + 1e-3
	local pass = res.regionCount == 1 and noOvershoot and res.regionArea > 0
	return assertTest(
		"SharpChevron 2% (F5/F10 atomic)",
		pass,
		string.format(
			"regions=%d regA=%s islA=%s (expected regions=1 regA <= islA+eps)",
			res.regionCount, fmt(res.regionArea), fmt(res.islandArea)
		)
	)
end

local function testStarStack(): Result
	local log = iterate2D(shapeStar(), 0.02, 10)
	local monotone = true
	local firstArea = log[1].totalArea
	local lastA = math.huge
	for _, row in log do
		if row.totalArea > lastA + 1e-3 then
			monotone = false
			break
		end
		lastA = row.totalArea
	end
	local fitsAll = true
	for _, row in log do if not row.regionBBoxFits then fitsAll = false end end
	return assertTest(
		"Star 0..10 layers 2% (F10/F5 cascade)",
		monotone and fitsAll,
		string.format(
			"layers=%d monotone=%s bboxFits=%s firstArea=%s",
			#log, tostring(monotone), tostring(fitsAll), fmt(firstArea)
		)
	)
end

local function testUShapeStack(): Result
	local log = iterate2D(shapeUShape(), 0.02, 8)
	local fitsAll = true
	for _, row in log do if not row.regionBBoxFits then fitsAll = false end end
	return assertTest(
		"U-Shape 0..8 layers 2% (F3 bbox overshoot)",
		fitsAll,
		string.format("layers=%d bboxFitsEveryLayer=%s", #log, tostring(fitsAll))
	)
end

local function testThinCrossL0(): Result
	-- At 1% the arm half-width (0.18) exceeds the inset (~0.10) so the cross
	-- survives with arms narrowed but still connected.  This catches F6
	-- premature termination if rawOffset produces a self-intersecting raw whose
	-- DCEL extraction rejects the genuine face.
	local res = run2DOffset(shapeThinCross(), 0.01)
	local pass = res.regionCount == 1 and res.regionArea > 0.2
	return assertTest(
		"ThinCross L0 1% (F6 premature collapse)",
		pass,
		string.format("regions=%d area=%s (expected 1 region, area > 0.2)", res.regionCount, fmt(res.regionArea))
	)
end

local function testSnowflakeStack(): Result
	local log = iterate2D(shapeSnowflake(), 0.02, 6)
	local layersSurvived = #log
	for _, row in log do if row.regions == 0 then layersSurvived -= 1 end end
	local pass = layersSurvived >= 3
	return assertTest(
		"Snowflake 0..6 layers 2% (F6 premature termination)",
		pass,
		string.format("layersSurvived=%d (expected >= 3)", layersSurvived)
	)
end

local function testSwissCheeseStack(): Result
	local log = iterate2D(shapeSwissCheese(), 0.02, 6)
	local layersSurvived = #log
	for _, row in log do if row.regions == 0 then layersSurvived -= 1 end end
	-- Expect at least 4 clean layers before any collapse; area must be monotone-decreasing per layer.
	local monotone = true
	local lastA = math.huge
	for _, row in log do
		if row.totalArea > lastA + 1e-3 then monotone = false end
		lastA = row.totalArea
	end
	return assertTest(
		"SwissCheese 0..6 layers 2% (F2/F5 cascade)",
		layersSurvived >= 4 and monotone,
		string.format("layersSurvived=%d monotone=%s", layersSurvived, tostring(monotone))
	)
end

local function testGearL1(): Result
	local res = run2DOffset(shapeGear(), 0.02)
	-- Correct behavior: single connected body (teeth attached to rim, not severed).
	local pass = res.regionCount == 1
	return assertTest(
		"Gear L1 2% (F10 tooth severance)",
		pass,
		string.format("regions=%d (expected 1 connected body)", res.regionCount)
	)
end

local function testMazeL0(): Result
	local res = run2DOffset(shapeMaze(), 0.03)
	local pass = res.regionCount == 1 and res.holeCount == 5
	return assertTest(
		"Maze L0 3% (5 slit holes preserved in offset output)",
		pass,
		string.format("regions=%d holes=%d (expected regions=1 holes=5)", res.regionCount, res.holeCount)
	)
end

local function testDonutStack(): Result
	local log = iterate2D(shapeDonut(), 0.02, 12)
	local layersSurvived = #log
	for _, row in log do if row.regions == 0 then layersSurvived -= 1 end end
	local monotone = true
	local lastA = math.huge
	for _, row in log do
		if row.totalArea > lastA + 1e-3 then monotone = false end
		lastA = row.totalArea
	end
	return assertTest(
		"Donut 0..12 layers 2% (reference clean run)",
		layersSurvived >= 4 and monotone,
		string.format("layersSurvived=%d monotone=%s", layersSurvived, tostring(monotone))
	)
end

local function testCombL1(): Result
	local res = run2DOffset(shapeComb(), 0.02)
	-- Correct behavior: single connected body (teeth attached to base, not severed into slivers).
	local pass = res.regionCount == 1
	return assertTest(
		"Comb L1 2% (F10/F8 tooth-sliver severance)",
		pass,
		string.format("regions=%d (expected 1 connected body)", res.regionCount)
	)
end

local ALL_2D_TESTS: { () -> Result } = {
	testHoleNearEdge,
	testTightHolePair,
	testSharpChevron,
	testStarStack,
	testUShapeStack,
	testThinCrossL0,
	testSnowflakeStack,
	testSwissCheeseStack,
	testGearL1,
	testMazeL0,
	testDonutStack,
	testCombL1,
}

--------------------------------------------------------------------------------
-- Mesh round-trip tests: require a MeshPart in workspace (frosted by a real
-- pipeline call via `_G.__frosting_build__`).  These catch F9-class bugs
-- (TopFaceExtractor area/hole loss, FrostingBuilder bridge merging).
--------------------------------------------------------------------------------

local function findCookie(name: string): MeshPart?
	local folder = workspace:FindFirstChild("TestCookies")
	if not folder then return nil end
	local child = folder:FindFirstChild(name)
	if child and child:IsA("MeshPart") then
		return child
	end
	return nil
end

-- Extract 2D islands from a MeshPart via TopFaceExtractor and report summary
-- stats that the atomic reproducers care about.
local function inspectMesh(part: MeshPart): {
	totalIslands: number,
	totalHoles: number,
	totalArea: number,
}
	local res = TopFaceExtractor.extract(part)
	local islands = 0
	local holes = 0
	local area = 0
	for _, island in res.islands do
		islands += 1
		holes += #island.holes
		area += pwhArea(island)
	end
	return { totalIslands = islands, totalHoles = holes, totalArea = area }
end

-- Mesh round-trip: frost a cookie once, then compare pre-build (offsetPWH)
-- vs post-build (re-extracted) area/hole-count on the resulting frosting.
-- Expectations come from Phase 1: pre-offset state is already known
-- correct (proven by the 2D tests) so any loss here is mesh-side.
local function testMeshArrowL1(): Result
	local cookie = findCookie("Arrow")
	if not cookie then return assertTest("MeshArrowL1", false, "Arrow cookie not found in workspace.TestCookies") end
	-- F9 specifically asks: does TopFaceExtractor + FrostingBuilder round-trip
	-- preserve offsetPWH's area?  Compare the 2D offset area (known-correct
	-- per the atomic tests) to the mesh re-extraction area.  Losing material
	-- to the sharp tips during the offset itself is expected geometry, not a
	-- round-trip bug.
	local island = TopFaceExtractor.extract(cookie).islands[1]
	local diag = math.sqrt(cookie.Size.X ^ 2 + cookie.Size.Z ^ 2)
	local regions = PolygonOffset.offsetPWH(island, diag * 0.02)
	local offsetArea = 0
	for _, r in regions do offsetArea += pwhArea(r) end
	local built = _G.__frosting_build__(cookie) :: MeshPart?
	if not built then return assertTest("MeshArrowL1", false, "frosting build returned nil") end
	local after = inspectMesh(built)
	local lossFrac = if offsetArea > 0 then 1 - after.totalArea / offsetArea else 1
	local pass = math.abs(lossFrac) < 0.05
	return assertTest(
		"Mesh Arrow L1 (F9 area round-trip)",
		pass,
		string.format("offsetArea=%s afterArea=%s lossFrac=%s (expected |loss| < 0.05)",
			fmt(offsetArea), fmt(after.totalArea), fmt(lossFrac))
	)
end

local function testMeshMazeL1(): Result
	local cookie = findCookie("Maze")
	if not cookie then return assertTest("MeshMazeL1", false, "Maze cookie not found in workspace.TestCookies") end
	local beforeHoles = #TopFaceExtractor.extract(cookie).islands[1].holes
	local built = _G.__frosting_build__(cookie) :: MeshPart?
	if not built then return assertTest("MeshMazeL1", false, "frosting build returned nil") end
	local after = inspectMesh(built)
	local pass = after.totalHoles == beforeHoles
	return assertTest(
		"Mesh Maze L1 (F2 hole round-trip)",
		pass,
		string.format("beforeHoles=%d afterHoles=%d (expected equal)", beforeHoles, after.totalHoles)
	)
end

local function testMeshCombL1L2(): Result
	local cookie = findCookie("Comb")
	if not cookie then return assertTest("MeshCombL1L2", false, "Comb cookie not found in workspace.TestCookies") end
	local l1 = _G.__frosting_build__(cookie) :: MeshPart?
	if not l1 then return assertTest("MeshCombL1L2", false, "L1 build returned nil") end
	local l1State = inspectMesh(l1)
	local l2 = _G.__frosting_build__(l1) :: MeshPart?
	if not l2 then
		return assertTest(
			"Mesh Comb L1->L2 (F9 sliver re-merge)",
			true,
			string.format("L1 islands=%d area=%s; L2 terminated gracefully", l1State.totalIslands, fmt(l1State.totalArea))
		)
	end
	local l2State = inspectMesh(l2)
	-- L2 area must not exceed L1 area (the sliver-re-merge bug produces L2 > L1).
	local pass = l2State.totalArea <= l1State.totalArea + 1e-3
	return assertTest(
		"Mesh Comb L1->L2 (F9 sliver re-merge)",
		pass,
		string.format("L1 area=%s islands=%d; L2 area=%s islands=%d (expected L2 <= L1)",
			fmt(l1State.totalArea), l1State.totalIslands, fmt(l2State.totalArea), l2State.totalIslands)
	)
end

local ALL_MESH_TESTS: { () -> Result } = {
	testMeshArrowL1,
	testMeshMazeL1,
	testMeshCombL1L2,
}

--------------------------------------------------------------------------------
-- Exports via _G
--------------------------------------------------------------------------------

local function runAll(tests: { () -> Result }, label: string): {
	pass: number, fail: number, results: { Result }
}
	local results: { Result } = {}
	local pass, fail = 0, 0
	print(string.format("[PolygonOffsetTests] === %s ===", label))
	for _, fn in tests do
		local ok, res = pcall(fn)
		if not ok then
			table.insert(results, { name = "(error)", pass = false, message = tostring(res) })
			fail += 1
			print(string.format("[PolygonOffsetTests] ERROR: %s", tostring(res)))
			continue
		end
		table.insert(results, res)
		if res.pass then
			pass += 1
			print(string.format("[PolygonOffsetTests] PASS  %s", res.name))
		else
			fail += 1
			print(string.format("[PolygonOffsetTests] FAIL  %s   %s", res.name, res.message))
		end
	end
	print(string.format("[PolygonOffsetTests] === %s: %d/%d pass ===", label, pass, pass + fail))
	return { pass = pass, fail = fail, results = results }
end

_G.__frosting_tests__ = function()
	return runAll(ALL_2D_TESTS, "2D (PolygonOffset atomic)")
end

_G.__frosting_mesh_tests__ = function()
	return runAll(ALL_MESH_TESTS, "Mesh round-trip (TopFaceExtractor + FrostingBuilder)")
end
