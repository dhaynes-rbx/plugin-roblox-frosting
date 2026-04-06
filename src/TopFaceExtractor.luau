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
local PolygonOffset = require(script.Parent.PolygonOffset)

export type Island = {
	outer: { Vector2 },
	holes: { { Vector2 } },
}

export type TopFaceResult = {
	islands: { Island },
	topY: number,
}

local NORMAL_UP_THRESHOLD = 0.7
local Y_SNAP_TOLERANCE = 0.02
local POSITION_SNAP = 1000

local function posKey(pos: Vector3): string
	local x = math.round(pos.X * POSITION_SNAP)
	local y = math.round(pos.Y * POSITION_SNAP)
	local z = math.round(pos.Z * POSITION_SNAP)
	return x .. "," .. y .. "," .. z
end

local function edgeKey(a: string, b: string): string
	if a < b then
		return a .. "|" .. b
	else
		return b .. "|" .. a
	end
end

local function extract(meshPart: MeshPart): TopFaceResult
	local em = AssetService:CreateEditableMeshAsync(meshPart.MeshContent, { FixedSize = false })

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
			if math.abs(pos.Y - maxY) <= Y_SNAP_TOLERANCE then
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

	-- 5. Directed adjacency from boundary edges
	local directedEdges: { [string]: string } = {}
	for ek, count in edgeCount do
		if count == 1 then
			local edge = directedEdgeStore[ek]
			directedEdges[edge[1]] = edge[2]
		end
	end

	-- 6. Walk boundary chains
	local seen: { [string]: boolean } = {}
	local chains: { { string } } = {}

	for startPk, _ in directedEdges do
		if seen[startPk] then
			continue
		end
		local chain: { string } = {}
		local cur: string? = startPk
		repeat
			if cur == nil or seen[cur] then
				break
			end
			seen[cur] = true
			table.insert(chain, cur)
			cur = directedEdges[cur]
		until cur == startPk
		if #chain >= 3 then
			table.insert(chains, chain)
		end
	end

	-- Try reversed direction if nothing found
	if #chains == 0 then
		local rev: { [string]: string } = {}
		for ek, count in edgeCount do
			if count == 1 then
				local edge = directedEdgeStore[ek]
				rev[edge[2]] = edge[1]
			end
		end
		seen = {}
		for startPk, _ in rev do
			if seen[startPk] then
				continue
			end
			local chain: { string } = {}
			local cur: string? = startPk
			repeat
				if cur == nil or seen[cur] then
					break
				end
				seen[cur] = true
				table.insert(chain, cur)
				cur = rev[cur]
			until cur == startPk
			if #chain >= 3 then
				table.insert(chains, chain)
			end
		end
	end

	assert(#chains > 0, "No boundary chains found on top face")

	-- 7. Convert chains to Vector2 polygons
	type ChainInfo = {
		poly: { Vector2 },
		area: number,
	}
	local chainInfos: { ChainInfo } = {}

	for _, chain in chains do
		local poly: { Vector2 } = {}
		for _, pk in chain do
			local pos = posKeyToPos[pk]
			table.insert(poly, Vector2.new(pos.X, pos.Z))
		end
		table.insert(chainInfos, {
			poly = poly,
			area = math.abs(PolygonInset.signedArea(poly)),
		})
	end

	-- 8. Classify chains into islands using containment -----------------------
	--    A chain contained by zero others → outer boundary of an island.
	--    A chain contained by exactly one other → hole of that island.
	--    A chain contained by N (even) others → outer boundary (nested island).
	--    A chain contained by N (odd) others  → hole.

	local nChains = #chainInfos

	-- For each chain, pick a sample vertex and count how many other chains
	-- contain that point.
	local containedBy: { { number } } = {} -- containedBy[i] = list of chain indices that contain chain i
	for i = 1, nChains do
		containedBy[i] = {}
	end

	for i = 1, nChains do
		local samplePt = chainInfos[i].poly[1]
		for j = 1, nChains do
			if i == j then
				continue
			end
			if PolygonOffset.pointInPolygon(samplePt, chainInfos[j].poly) then
				table.insert(containedBy[i], j)
			end
		end
	end

	-- Build islands: even nesting depth = outer, odd = hole
	local islandMap: { [number]: Island } = {} -- outer chain index → Island
	local holeAssignment: { [number]: number } = {} -- hole chain index → outer chain index

	for i = 1, nChains do
		local depth = #containedBy[i]
		if depth % 2 == 0 then
			-- Outer boundary
			islandMap[i] = {
				outer = PolygonInset.ensureCCW(chainInfos[i].poly),
				holes = {},
			}
		end
	end

	for i = 1, nChains do
		local depth = #containedBy[i]
		if depth % 2 == 1 then
			-- Hole: find its immediate parent (the containing chain with the
			-- smallest area among those at depth-1 nesting).
			local bestParent: number? = nil
			local bestArea = math.huge
			for _, parentIdx in containedBy[i] do
				if #containedBy[parentIdx] == depth - 1 then
					if chainInfos[parentIdx].area < bestArea then
						bestArea = chainInfos[parentIdx].area
						bestParent = parentIdx
					end
				end
			end
			if bestParent and islandMap[bestParent] then
				table.insert(islandMap[bestParent].holes, chainInfos[i].poly)
				holeAssignment[i] = bestParent
			end
		end
	end

	-- Collect islands into an array
	local islands: { Island } = {}
	for _, island in islandMap do
		table.insert(islands, island)
	end

	-- Fallback: if the classification yielded nothing, use the legacy approach
	-- (largest polygon = outer, rest = holes).
	if #islands == 0 then
		table.sort(chainInfos, function(a, b)
			return a.area > b.area
		end)
		local fallbackIsland: Island = {
			outer = PolygonInset.ensureCCW(chainInfos[1].poly),
			holes = {},
		}
		for i = 2, nChains do
			table.insert(fallbackIsland.holes, chainInfos[i].poly)
		end
		table.insert(islands, fallbackIsland)
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
