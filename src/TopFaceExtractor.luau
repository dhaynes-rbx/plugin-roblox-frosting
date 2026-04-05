--!strict

-- Reads a MeshPart's EditableMesh, identifies the top-facing polygon,
-- and returns an ordered list of 2D boundary vertices (X-Z plane) plus topY.
--
-- Handles split vertices (same position, different IDs) by merging by position.

local AssetService = game:GetService("AssetService")
local PolygonInset = require(script.Parent.PolygonInset)

export type TopFaceResult = {
	polygon: { Vector2 },
	holePolygons: { { Vector2 } },
	topY: number,
}

local NORMAL_UP_THRESHOLD = 0.7
local Y_SNAP_TOLERANCE = 0.02
local POSITION_SNAP = 1000 -- round to 3 decimal places for position merging

-- Round a position to a string key for vertex merging.
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
	local em = AssetService:CreateEditableMeshAsync(
		meshPart.MeshContent,
		{ FixedSize = false }
	)

	-- 1. Build position-merge map: vertex ID → canonical position key.
	--    Also store one representative position per key.
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

	-- 2. Find all upward-facing faces and determine topY.
	local topFaceIds: { number } = {}
	local maxY = -math.huge

	for _, faceId in em:GetFaces() do
		local verts = em:GetFaceVertices(faceId)
		if #verts < 3 then continue end

		local p0 = em:GetPosition(verts[1])
		local p1 = em:GetPosition(verts[2])
		local p2 = em:GetPosition(verts[3])
		local cross = (p1 - p0):Cross(p2 - p0)
		if cross.Magnitude < 1e-8 then continue end

		if cross.Unit.Y >= NORMAL_UP_THRESHOLD then
			table.insert(topFaceIds, faceId)
			for _, vid in verts do
				local y = em:GetPosition(vid).Y
				if y > maxY then maxY = y end
			end
		end
	end

	assert(#topFaceIds > 0, "No upward-facing faces found on this MeshPart")

	-- 3. Collect position keys that sit on topY.
	local topPosKeys: { [string]: boolean } = {}
	for _, faceId in topFaceIds do
		for _, vid in em:GetFaceVertices(faceId) do
			local pos = em:GetPosition(vid)
			if math.abs(pos.Y - maxY) <= Y_SNAP_TOLERANCE then
				topPosKeys[vidToPosKey[vid]] = true
			end
		end
	end

	-- 4. Find boundary edges using merged position keys.
	local edgeCount: { [string]: number } = {}
	local directedEdgeStore: { [string]: { string } } = {} -- ek -> {pkA, pkB}

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

	-- 5. Build directed adjacency from boundary edges (count == 1).
	local directedEdges: { [string]: string } = {}
	for ek, count in edgeCount do
		if count == 1 then
			local edge = directedEdgeStore[ek]
			directedEdges[edge[1]] = edge[2]
		end
	end

	-- 6. Walk all boundary chains.
	local seen: { [string]: boolean } = {}
	local chains: { { string } } = {}

	for startPk, _ in directedEdges do
		if seen[startPk] then continue end
		local chain: { string } = {}
		local cur: string? = startPk
		repeat
			if cur == nil or seen[cur] then break end
			seen[cur] = true
			table.insert(chain, cur)
			cur = directedEdges[cur]
		until cur == startPk
		if #chain >= 3 then
			table.insert(chains, chain)
		end
	end

	-- Try reversed direction if no chains found.
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
			if seen[startPk] then continue end
			local chain: { string } = {}
			local cur: string? = startPk
			repeat
				if cur == nil or seen[cur] then break end
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

	-- 7. Convert all chains to Vector2 polygons, sort by area descending.
	local chainPolygons: { { poly: { Vector2 }, area: number } } = {}

	for _, chain in chains do
		local poly: { Vector2 } = {}
		for _, pk in chain do
			local pos = posKeyToPos[pk]
			table.insert(poly, Vector2.new(pos.X, pos.Z))
		end
		table.insert(chainPolygons, {
			poly = poly,
			area = math.abs(PolygonInset.signedArea(poly)),
		})
	end

	table.sort(chainPolygons, function(a, b) return a.area > b.area end)

	assert(#chainPolygons > 0, "No boundary chains found")

	-- Largest = outer boundary; remaining = hole boundaries.
	local outerPoly = chainPolygons[1].poly
	local holePolygons: { { Vector2 } } = {}
	for i = 2, #chainPolygons do
		table.insert(holePolygons, chainPolygons[i].poly)
	end

	em:Destroy()

	return {
		polygon = outerPoly,
		holePolygons = holePolygons,
		topY = maxY,
	}
end

return {
	extract = extract,
}
