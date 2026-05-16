--!strict

-- Reads a MeshPart's EditableMesh, identifies the top-facing polygon(s),
-- and returns one or more islands, each with an outer boundary and zero or
-- more hole boundaries (all as 2D X-Z polygons), plus the shared topY.
--
-- Multi-island support: disconnected cookie pieces are returned as separate
-- islands.  Holes are assigned to their containing outer boundary via
-- point-in-polygon containment tests.

local AssetService = game:GetService("AssetService")
local PolygonInset = require(script.Parent.PolygonInset)
local PolygonNesting = require(script.Parent.PolygonNesting)

export type Island = PolygonNesting.PolygonWithHoles

export type TopFaceResult = {
	islands: { Island },
	topY: number,
}

local NORMAL_UP_THRESHOLD = 0.7

-- Y_SNAP_TOLERANCE is chosen adaptively per-mesh in `extract`.  The value
-- controls which vertices of upward-facing faces are considered part of the
-- shared top plane.  A fixed 0.02 was too coarse for stacked frosting layers
-- whose extrude height (cookie-diagonal * EXTRUDE_FRACTION) shrinks below
-- 0.02, which caused the bottom rim of a thin cap to be mis-classified as part
-- of the top plane and fuse with it on mesh re-extraction (F9/F2 root cause
-- for thin stacked caps).  We target 5% of the mesh's Y extent with a relative
-- floor so we never exceed the planar-EPS grid resolution.
local Y_SNAP_FRACTION = 0.05
local Y_SNAP_FLOOR_FRACTION = 1e-5

-- POSITION_SNAP is chosen adaptively per-mesh in `extract`.  We target 4
-- decimal digits of precision relative to the mesh bounding box diagonal:
--   * mesh-scale cookies don't lose distinct vertices to over-welding
--   * tiny stacked frosting caps still dedup coincident vertices reliably
-- Empirically matching the downstream PolygonOffset grid (1e5) over-preserves
-- floating-point noise from EditableMesh storage and causes cap boundaries
-- to grow spurious near-collinear vertices on every iteration (ScaleSweep,
-- TightHolePair, Maze all regress 4-6 layers with the finer grid).  The 1e4
-- grid acts as a mild noise filter that the downstream PolygonInset/Offset
-- eps (diag * 1e-5, ~10x finer) then refines as needed.
local POSITION_SNAP_TARGET_DIGITS = 1e4

local function edgeKey(a: string, b: string): string
	if a < b then
		return a .. "|" .. b
	else
		return b .. "|" .. a
	end
end

local function extract(meshPart: MeshPart): TopFaceResult
	local em = AssetService:CreateEditableMeshAsync(meshPart.MeshContent, { FixedSize = false })

	-- Adaptive POSITION_SNAP: target ~4 significant digits across the part's
	-- bounding-box diagonal.  Small cookies (stacked frosting) otherwise lose
	-- distinct vertices to the old fixed 1e-3 snap; large cookies with fine
	-- detail otherwise fail to dedup near-identical positions.
	local meshSize = meshPart.Size
	local diag = math.sqrt(meshSize.X ^ 2 + meshSize.Y ^ 2 + meshSize.Z ^ 2)
	local snap = if diag > 1e-6 then POSITION_SNAP_TARGET_DIGITS / diag else 1000

	-- Scale Y snap to the part's Y extent so stacked frosting layers (whose
	-- extrude height is proportional to their cookie-diagonal, not absolute)
	-- never merge bottom-rim verts into the top plane.  The floor is also
	-- relative to meshSize.Y so the snap never exceeds the planar EPS grid.
	local ySnapTolerance = math.max(meshSize.Y * Y_SNAP_FRACTION, meshSize.Y * Y_SNAP_FLOOR_FRACTION)

	local function posKey(pos: Vector3): string
		local x = math.round(pos.X * snap)
		local y = math.round(pos.Y * snap)
		local z = math.round(pos.Z * snap)
		return x .. "," .. y .. "," .. z
	end

	-- 1. Build position-merge map
	local vidToPosKey: { [number]: string } = {}
	local posKeyToPos: { [string]: Vector3 } = {}

	for _, vid in em:GetVertices() do
		local pos = em:GetPosition(vid)
		local pk = posKey(pos)
		vidToPosKey[vid] = pk
		if not posKeyToPos[pk] then
			posKeyToPos[pk] = pos
		end
	end

	-- 2. Find upward-facing faces, determine topY
	local topFaceIds: { number } = {}
	local maxY = -math.huge

	for _, faceId in em:GetFaces() do
		local verts = em:GetFaceVertices(faceId)
		if #verts < 3 then
			continue
		end
		local p0 = em:GetPosition(verts[1])
		local p1 = em:GetPosition(verts[2])
		local p2 = em:GetPosition(verts[3])
		local cross = (p1 - p0):Cross(p2 - p0)
		if cross.Magnitude < 1e-8 then
			continue
		end
		if cross.Unit.Y >= NORMAL_UP_THRESHOLD then
			table.insert(topFaceIds, faceId)
			for _, vid in verts do
				local y = em:GetPosition(vid).Y
				if y > maxY then
					maxY = y
				end
			end
		end
	end

	assert(#topFaceIds > 0, "No upward-facing faces found on this MeshPart")

	-- 3. Collect top position keys
	local topPosKeys: { [string]: boolean } = {}
	for _, faceId in topFaceIds do
		for _, vid in em:GetFaceVertices(faceId) do
			local pos = em:GetPosition(vid)
			if math.abs(pos.Y - maxY) <= ySnapTolerance then
				topPosKeys[vidToPosKey[vid]] = true
			end
		end
	end

	-- 4. Boundary edges
	local edgeCount: { [string]: number } = {}
	local directedEdgeStore: { [string]: { string } } = {}

	for _, faceId in topFaceIds do
		local verts = em:GetFaceVertices(faceId)
		for i = 1, #verts do
			local a = verts[i]
			local b = verts[(i % #verts) + 1]
			local pkA = vidToPosKey[a]
			local pkB = vidToPosKey[b]
			if topPosKeys[pkA] and topPosKeys[pkB] and pkA ~= pkB then
				local ek = edgeKey(pkA, pkB)
				edgeCount[ek] = (edgeCount[ek] or 0) + 1
				if not directedEdgeStore[ek] then
					directedEdgeStore[ek] = { pkA, pkB }
				end
			end
		end
	end

	-- 5. Undirected adjacency from boundary edges
	local adjacency: { [string]: { string } } = {}
	for ek, count in edgeCount do
		if count == 1 then
			local edge = directedEdgeStore[ek]
			local a, b = edge[1], edge[2]
			if not adjacency[a] then
				adjacency[a] = {}
			end
			if not adjacency[b] then
				adjacency[b] = {}
			end
			table.insert(adjacency[a], b)
			table.insert(adjacency[b], a)
		end
	end

	-- 6. Walk boundary chains using undirected adjacency.
	--    At junction vertices (degree > 2), use the leftmost-turn rule
	--    (smallest CCW angle from incoming edge) so the walk stays on the
	--    correct boundary loop instead of short-circuiting.
	local function pickNext(
		curPk: string,
		prevPk: string?,
		neighbors: { string },
		usedEdges: { [string]: boolean }
	): string?
		-- Filter to unvisited-edge candidates
		local cands: { string } = {}
		for _, nb in neighbors do
			local ek = edgeKey(curPk, nb)
			if nb ~= prevPk and not usedEdges[ek] then
				table.insert(cands, nb)
			end
		end
		if #cands == 0 then return nil end
		if #cands == 1 then return cands[1] end

		-- Multiple candidates: pick leftmost turn (smallest CCW angle) so that
		-- a walk starting on a CCW outer boundary stays on the outer and a
		-- walk starting on a CW hole boundary stays on that hole.  "Straightest
		-- continuation" might feel more natural at a crossover but it is
		-- orientation-blind: at a genuine degree-4 junction (two hole boundaries
		-- crossing at a shared tip), straightest can flip the winding of one
		-- sub-loop and cause PolygonNesting.classify to emit a phantom island.
		local curPos = posKeyToPos[curPk]
		local inDir: Vector2
		if prevPk then
			local prevPos = posKeyToPos[prevPk]
			inDir = Vector2.new(curPos.X - prevPos.X, curPos.Z - prevPos.Z)
		else
			local firstNb = posKeyToPos[cands[1]]
			inDir = Vector2.new(firstNb.X - curPos.X, firstNb.Z - curPos.Z)
		end
		local inAngle = math.atan2(inDir.Y, inDir.X)

		local best: string? = nil
		local bestTurn = math.huge
		for _, nb in cands do
			local nbPos = posKeyToPos[nb]
			local outDir = Vector2.new(nbPos.X - curPos.X, nbPos.Z - curPos.Z)
			local outAngle = math.atan2(outDir.Y, outDir.X)
			local turn = outAngle - inAngle + math.pi
			turn = turn % (2 * math.pi)
			if turn < bestTurn then
				bestTurn = turn
				best = nb
			end
		end
		return best
	end

	local usedEdges: { [string]: boolean } = {}
	local chains: { { string } } = {}

	for startPk in adjacency do
		local neighbors = adjacency[startPk]
		for _, firstNb in neighbors do
			local ek = edgeKey(startPk, firstNb)
			if usedEdges[ek] then continue end

			local chain: { string } = { startPk }
			usedEdges[ek] = true
			local prev = startPk
			local cur = firstNb
			while cur ~= startPk do
				table.insert(chain, cur)
				local nxt = pickNext(cur, prev, adjacency[cur], usedEdges)
				if not nxt then break end
				usedEdges[edgeKey(cur, nxt)] = true
				prev = cur
				cur = nxt
			end
			if #chain >= 3 and cur == startPk then
				table.insert(chains, chain)
			end
		end
	end

	assert(#chains > 0, "No boundary chains found on top face")

	-- 7. Convert chains to Vector2 polygons
	local chainPolys: { { Vector2 } } = {}
	for _, chain in chains do
		local poly: { Vector2 } = {}
		for _, pk in chain do
			local pos = posKeyToPos[pk]
			table.insert(poly, Vector2.new(pos.X, pos.Z))
		end
		table.insert(chainPolys, poly)
	end

	-- 8. Classify chains into islands via even/odd containment depth.
	local islands: { Island } = PolygonNesting.classify(chainPolys)

	-- Fallback: if classification yielded nothing (pathological input), treat
	-- the largest polygon as outer and the rest as holes.
	if #islands == 0 then
		table.sort(chainPolys, function(a, b)
			return math.abs(PolygonInset.signedArea(a))
				> math.abs(PolygonInset.signedArea(b))
		end)
		local fallback: Island = {
			outer = PolygonInset.ensureCCW(chainPolys[1]),
			holes = {},
		}
		for i = 2, #chainPolys do
			table.insert(fallback.holes, PolygonInset.ensureCCW(chainPolys[i]))
		end
		table.insert(islands, fallback)
	end

	em:Destroy()

	return {
		islands = islands,
		topY = maxY,
	}
end

return {
	extract = extract,
}
