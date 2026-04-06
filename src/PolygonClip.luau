--!strict

-- Polygon boolean operations via the Weiler-Atherton algorithm.
--
-- Supported operations:
--   intersection(subject, clip) → parts of subject inside clip
--   difference(subject, clip)   → parts of subject outside clip
--
-- Both inputs must be simple CCW polygons.  Results are zero or more simple
-- CCW polygons.

local PolygonInset = require(script.Parent.PolygonInset)
local PolygonOffset = require(script.Parent.PolygonOffset)

local EPS = 1e-9
local SEG_MARGIN = 1e-6

--------------------------------------------------------------------------------
-- Augmented vertex list used by the W-A walk
--------------------------------------------------------------------------------

type AugNode = {
	pos: Vector2,
	isIsect: boolean,
	isectId: number, -- 0 for regular vertices; 1-based id for intersection points
	entering: boolean, -- true = subject enters clip at this intersection
	partnerId: number, -- index in the OTHER augmented list (valid when isIsect)
}

--------------------------------------------------------------------------------
-- Internal: find all edge-edge intersections between two polygons
--------------------------------------------------------------------------------

type IsectRecord = {
	id: number,
	sEdge: number,
	cEdge: number,
	tS: number,
	tC: number,
	point: Vector2,
	entering: boolean,
}

local function findIntersections(
	subject: { Vector2 },
	clip: { Vector2 }
): { IsectRecord }
	local ns = #subject
	local nc = #clip
	local result: { IsectRecord } = {}
	local nextId = 1

	for si = 1, ns do
		local sA = subject[si]
		local sB = subject[(si % ns) + 1]
		for ci = 1, nc do
			local cA = clip[ci]
			local cB = clip[(ci % nc) + 1]
			local t, u, pt = PolygonOffset.segSegIntersect(sA, sB, cA, cB)
			if t and u and pt then
				local sDir = sB - sA
				local cDir = cB - cA
				local cross = sDir.X * cDir.Y - sDir.Y * cDir.X
				table.insert(result, {
					id = nextId,
					sEdge = si,
					cEdge = ci,
					tS = t,
					tC = u,
					point = pt,
					entering = cross > 0,
				})
				nextId += 1
			end
		end
	end

	return result
end

--------------------------------------------------------------------------------
-- Internal: build augmented vertex lists with intersections inserted in order
--------------------------------------------------------------------------------

local function buildAugmented(
	poly: { Vector2 },
	isects: { IsectRecord },
	edgeField: string, -- "sEdge" or "cEdge"
	tField: string -- "tS" or "tC"
): { AugNode }
	local n = #poly
	-- Group intersections by edge
	local edgeBuckets: { { IsectRecord } } = {}
	for i = 1, n do
		edgeBuckets[i] = {}
	end
	for _, ix in isects do
		table.insert(edgeBuckets[(ix :: any)[edgeField]], ix)
	end
	for i = 1, n do
		table.sort(edgeBuckets[i], function(a, b)
			return (a :: any)[tField] < (b :: any)[tField]
		end)
	end

	local aug: { AugNode } = {}
	for i = 1, n do
		table.insert(aug, {
			pos = poly[i],
			isIsect = false,
			isectId = 0,
			entering = false,
			partnerId = 0,
		})
		for _, ix in edgeBuckets[i] do
			table.insert(aug, {
				pos = ix.point,
				isIsect = true,
				isectId = ix.id,
				entering = ix.entering,
				partnerId = 0, -- filled in later
			})
		end
	end

	return aug
end

--------------------------------------------------------------------------------
-- Internal: link partner indices between subject-aug and clip-aug lists
--------------------------------------------------------------------------------

local function linkPartners(
	sAug: { AugNode },
	cAug: { AugNode },
	isects: { IsectRecord }
)
	-- Map isectId → index in each augmented list
	local sMap: { [number]: number } = {}
	local cMap: { [number]: number } = {}
	for i, node in sAug do
		if node.isIsect then
			sMap[node.isectId] = i
		end
	end
	for i, node in cAug do
		if node.isIsect then
			cMap[node.isectId] = i
		end
	end
	for _, ix in isects do
		local si = sMap[ix.id]
		local ci = cMap[ix.id]
		if si and ci then
			sAug[si].partnerId = ci
			cAug[ci].partnerId = si
		end
	end
end

--------------------------------------------------------------------------------
-- Internal: generic W-A walk
-- `startEntering` = true  → start at entering intersections  (intersection op)
-- `startEntering` = false → start at exiting intersections   (difference op)
-- `clipForward`   = true  → walk clip CCW  (intersection / union)
-- `clipForward`   = false → walk clip CW   (difference)
--------------------------------------------------------------------------------

local function waWalk(
	sAug: { AugNode },
	cAug: { AugNode },
	isects: { IsectRecord },
	startEntering: boolean,
	clipForward: boolean
): { { Vector2 } }
	local sLen = #sAug
	local cLen = #cAug
	local visited: { [number]: boolean } = {} -- keyed by isectId
	local result: { { Vector2 } } = {}

	-- Helper: advance index in a list
	local function advance(idx: number, len: number, forward: boolean): number
		if forward then
			return (idx % len) + 1
		else
			return ((idx - 2) % len) + 1
		end
	end

	for sIdx = 1, sLen do
		local sNode = sAug[sIdx]
		if not sNode.isIsect then
			continue
		end
		if sNode.entering ~= startEntering then
			continue
		end
		if visited[sNode.isectId] then
			continue
		end

		local poly: { Vector2 } = {}
		local onSubject = true
		local curIdx = sIdx
		local startIsectId = sNode.isectId
		local maxSteps = sLen + cLen + 4
		local done = false

		-- Record the starting intersection
		table.insert(poly, sNode.pos)
		visited[startIsectId] = true

		for _ = 1, maxSteps do
			if done then
				break
			end

			if onSubject then
				curIdx = advance(curIdx, sLen, true)
				local node = sAug[curIdx]
				table.insert(poly, node.pos)

				if node.isIsect then
					visited[node.isectId] = true
					-- Switch condition: opposite of start type
					if node.entering ~= startEntering then
						-- Switch to clip
						curIdx = node.partnerId
						onSubject = false
					end
				end
			else
				curIdx = advance(curIdx, cLen, clipForward)
				local node = cAug[curIdx]

				if node.isIsect then
					if node.isectId == startIsectId then
						done = true
						break
					end
					visited[node.isectId] = true
					table.insert(poly, node.pos)
					-- Switch condition: same as start type
					if node.entering == startEntering then
						curIdx = node.partnerId
						onSubject = true
					end
				else
					table.insert(poly, node.pos)
				end
			end

			-- Safety: if we somehow arrive back at start on subject
			if onSubject and sAug[curIdx].isIsect and sAug[curIdx].isectId == startIsectId then
				done = true
			end
		end

		if #poly >= 3 then
			table.insert(result, poly)
		end
	end

	return result
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Returns the parts of `subject` that lie inside `clip`.
local function intersection(subject: { Vector2 }, clip: { Vector2 }): { { Vector2 } }
	subject = PolygonInset.ensureCCW(subject)
	clip = PolygonInset.ensureCCW(clip)

	local isects = findIntersections(subject, clip)

	if #isects == 0 then
		if PolygonOffset.pointInPolygon(subject[1], clip) then
			return { subject }
		end
		if PolygonOffset.pointInPolygon(clip[1], subject) then
			return { clip }
		end
		return {}
	end

	local sAug = buildAugmented(subject, isects, "sEdge", "tS")
	local cAug = buildAugmented(clip, isects, "cEdge", "tC")
	linkPartners(sAug, cAug, isects)

	return waWalk(sAug, cAug, isects, true, true)
end

--- Returns the parts of `subject` that lie outside `clip`.
local function difference(subject: { Vector2 }, clip: { Vector2 }): { { Vector2 } }
	subject = PolygonInset.ensureCCW(subject)
	clip = PolygonInset.ensureCCW(clip)

	local isects = findIntersections(subject, clip)

	if #isects == 0 then
		if PolygonOffset.pointInPolygon(subject[1], clip) then
			return {} -- subject entirely inside clip → nothing remains
		end
		if PolygonOffset.pointInPolygon(clip[1], subject) then
			-- clip entirely inside subject → subject with clip as a hole
			-- Return subject unchanged; caller adds clip as a hole.
			return { subject }
		end
		return { subject } -- no overlap
	end

	local sAug = buildAugmented(subject, isects, "sEdge", "tS")
	local cAug = buildAugmented(clip, isects, "cEdge", "tC")
	linkPartners(sAug, cAug, isects)

	return waWalk(sAug, cAug, isects, false, false)
end

return {
	intersection = intersection,
	difference = difference,
}
