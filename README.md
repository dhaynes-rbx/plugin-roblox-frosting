# Frosting Plugin

A Roblox Studio plugin that automatically generates a frosting layer on top of cookie-shaped `MeshPart`s. Select one or more `MeshPart`s, click **Create Frosting**, and the plugin extrudes a new frosting mesh along the top surface outline of each part.

## How It Works

The plugin uses `AssetService` `EditableMesh` to read the source mesh and write the output mesh. For each selected `MeshPart`:

1. **Top face extraction** — Finds all upward-facing triangles, walks their boundary loops, and classifies them as outer contours or holes. Supports multiple disconnected islands.
2. **Region computation** — Insets the outer boundary and offsets holes inward by a fraction of the mesh's XZ bounding-box diagonal. Clips holes to the inset outer region using Weiler–Atherton polygon clipping.
3. **Geometry building** — Constructs a 3D frosting mesh (rim, side walls, top cap with ear-clipping triangulation) from the 2D regions, then calls `CreateMeshPartAsync` to produce the final part.

The new part is named `{OriginalName}_Frosting`, anchored, tagged `Frosting` via `CollectionService`, and parented next to the source part.

### Colors

| Source | Frosting color |
|---|---|
| Regular mesh | Pink (`255, 105, 180`) |
| Mesh already tagged `Frosting` | Green (frosting on frosting) |

## Usage

1. Open a place in Roblox Studio with the plugin installed.
2. Select one or more `MeshPart`s that have a clearly defined top surface.
3. Click the **Frosting** toolbar button to open the panel.
4. Click **Create Frosting** to generate frosting parts for the selection.

The **Generate Test Cookies** button populates `workspace.TestCookies` with a grid of procedurally generated cookie shapes (circles, stars, donuts, gears, mazes, etc.) useful for testing edge cases.

## Development

### Prerequisites

- [Aftman](https://github.com/LPGhatguy/aftman) (toolchain manager)
- [Rojo](https://rojo.space) (installed via Aftman)

### Setup

```bash
aftman install
```

### Build

```bash
rojo build --plugin frosting.rbxmx
```

Rojo places the built plugin in the correct Roblox Studio plugins directory for your OS.

### Linting & Formatting

```bash
selene src/
stylua src/
```

Config lives in `selene.toml` (Roblox standard library) and `stylua.toml` (4-space indent, Luau syntax).

## Project Structure

```
src/
  init.server.luau       # Plugin entry point — toolbar, UI, orchestration
  FrostingBuilder.luau   # Builds 3D frosting geometry from 2D regions
  TopFaceExtractor.luau  # Detects top faces and extracts boundary loops
  PolygonInset.luau      # CCW/area helpers, ear-clip triangulation, inset
  PolygonOffset.luau     # Polygon offset with self-intersection handling
  PolygonClip.luau       # Weiler–Atherton intersection, difference, union
  TestCookieGenerator.luau  # Procedural test cookie shapes
default.project.json     # Rojo project definition
aftman.toml              # Toolchain pins (Rojo 7.4.4)
```

## Tunables

Constants at the top of `init.server.luau` control the frosting shape:

| Constant | Description |
|---|---|
| `INSET_FRACTION` | Inward inset as a fraction of the XZ bounding-box diagonal |
| `EXTRUDE_FRACTION` | Upward extrusion height as a fraction of the same diagonal |
| `HOLE_AREA_RATIO_MIN` | Minimum hole area ratio — holes smaller than this are ignored |
