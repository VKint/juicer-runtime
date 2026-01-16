# Juicer Runtime & Exporter

A high-performance rendering runtime and Blender level exporter designed for custom engine development.

## Overview

Juicer is a minimal, data-driven rendering pipeline focusing on interoperability with Blender. It consists of:
1.  **Level Exporter**: A Blender addon that packages scene data (geometry, textures, samplers, and lights) into a custom binary format (`.bin`).
2.  **Runtime**: A modern rendering engine written in **Odin** using **SDL3 GPU**, capable of loading and displaying these scenes with hot-reloading support (via the exporter).

## Features

-   **Custom Binary Format**: Optimized for fast loading with a magic header `0xB00BFACE`.
-   **Modern Tech Stack**: Built with Odin and SDL3's new GPU API (SPIR-V shaders).
-   **Blender Integration**: One-click "Export & Run" from within Blender.
-   **Asset Pipeline**: Automated texture handling, sampler configuration extraction, and PBR-lite material support.
-   **Light Support**: Support for Sun, Point, and Spot lights with shadow metadata.

## Getting Started

### Prerequisites

-   [Odin Compiler](https://odin-lang.org/)
-   [SDL3](https://github.com/libsdl-org/SDL) (configured for your system)
-   Blender 5.0+

### 1. Install the Exporter
1.  Open Blender.
2.  Install `level-exporter/level_exporter.py` as an addon.
3.  In the Sidebar (N-panel), find the **Juicer** tab.

### 2. Build the Runtime
```bash
cd juicer-runtime
odin build src -out:main -debug
```

### 3. Workflow
1.  Configure the "Runtime Executable" path in the Blender Juicer panel.
2.  Build your level in Blender.
3.  Press **F5** to export and launch the runtime instantly.

## Architecture

-   **`scene.bin`**: Contains interleaved vertex data (Pos, UV, Norm, Tangent), object transforms, and referenced textures.
-   **Odin Runtime**: Handles SDL3 GPU initialization, pipeline management, and scene graph traversal.

## TODO

- A ton
- This is an exploratory/learning project with the purpose of expanding my knowledge of game engine architecture and data pipelines.

## License

MIT
