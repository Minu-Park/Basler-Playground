<p align="center">
  <img src="docs/assets/app_icon.png" alt="Basler Playground" width="96" />
</p>

<h1 align="center">Basler Playground</h1>

<p align="center">
  <b>Unified Workspace for the Entire Basler Vision Ecosystem</b><br>
  <sub>Provided by Basler Korea</sub>
</p>

<p align="center">
  <a href="https://github.com/Minu-Park/Basler-Playground/releases/latest"><img src="https://img.shields.io/github/v/release/Minu-Park/Basler-Playground?style=flat-square&color=00457C&label=Latest%20Release" alt="Latest Release"></a>
  <a href="https://playground.minu.kr"><img src="https://img.shields.io/badge/Homepage-playground.minu.kr-f58220?style=flat-square" alt="Homepage"></a>
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/License-Proprietary-lightgrey?style=flat-square" alt="License">
</p>

---

<p align="center">
  <a href="https://playground.minu.kr">🌐 <b>Visit Homepage →</b></a>
</p>

## Overview

**Basler Playground** is a multi-device vision workspace that controls every Basler 2D camera, 3D sensor, and CoaXPress framegrabber in a single unified suite. It features a built-in **Script Editor** with **Interactive Parameters** — annotate any variable with `// @interactive-range(min, max)` and the application automatically generates live GUI controls for real-time algorithm tuning without stopping image acquisition.

## Key Features

| Feature | Description |
|---------|-------------|
| **Session Workspace** | Unified multi-device authority with multi-window workspace for managing active camera streams, parameters, and live inspection pipelines. |
| **Interactive Parameters** | Write processing scripts in Script Editor. `// @interactive` annotations auto-construct live GUI sliders for real-time JIT parameter hot-swapping. |
| **2D & 3D Visualization** | High-speed rendering for 2D image pan/zoom, 3D point cloud surfaces, profile measurements, and ROI tools. |
| **Basler 2D & 3D Cameras** | Full acquisition for Basler GigE, USB3, and 3D vision cameras with device status contracts. |
| **Basler Framegrabber** | Hardware abstraction for Basler CoaXPress framegrabbers with multi-stream DMA ring buffers. |
| **LMI 3D Sensors** | Integration with LMI Gocator 3D sensors and profilers via GoPxL SDK. |

## Interactive Parameters

The core differentiator of Basler Playground is the **Interactive Parameters** system. Add simple annotations in the Script Editor and the application automatically generates GUI controls that hot-swap algorithm parameters in real time:

```cpp
auto input = get().toMatGray();
auto output = cv::Mat();

int range = 127; // @interactive-range(1, 255)

cv::threshold(input, output, range, 255, cv::THRESH_BINARY);

show(output);
```

Drag the auto-generated slider to adjust `range` live — the processing pipeline updates instantly without dropping frames or restarting acquisition.

## Installation

Download the latest installer from the [**Releases**](https://github.com/Minu-Park/Basler-Playground/releases/latest) page.

Each official Core release is one GitHub release containing a Full Package installer, a Core-only installer, and an immutable snapshot of the independently versioned plugin packages selected for that Core tag. Full is the default user-facing package; Core-only is the minimal profile for machines that do not need bundled device SDKs. Use Playground's **Help > Plugins** package manager to install or update device packages after either profile is installed. Plugin packages are activated after affected sessions close, so a device-only update does not require a Core reinstall or host restart.

GitHub's **Latest** release is reserved for stable Core releases. The `plugins-index.json` asset and all plugin ZIPs live in the same Core release; `plugin-channel` is retained only as a compatibility pointer for already published binaries. New releases do not create individual `plugin-*` package releases.

> **Note**: This repository hosts the release page and installer distribution only. Source code is not included.

### System Requirements

- **OS**: Windows 10 / 11 (x64), macOS (Apple silicon)

## Ecosystem

Basler Playground integrates with the following open-source hardware driver repositories maintained by [**Basler Korea**](https://github.com/BaslerKR):

| Repository | Description |
|------------|-------------|
| [BaslerKR/Camera](https://github.com/BaslerKR/Camera) | Hardware driver & acquisition interface for Basler 2D and 3D vision cameras. |
| [BaslerKR/Framegrabber](https://github.com/BaslerKR/Framegrabber) | High-throughput hardware interface for Basler CoaXPress framegrabbers. |
| [BaslerKR/Gocator](https://github.com/BaslerKR/Gocator) | 3D sensor integration module for LMI Gocator devices via GoPxL SDK. |

## Links

- 🌐 **Homepage**: [playground.minu.kr](https://playground.minu.kr)
- 📦 **Latest Release**: [Download](https://github.com/Minu-Park/Basler-Playground/releases/latest)
- 🐛 **Issues**: [Report a Bug](https://github.com/Minu-Park/Basler-Playground/issues)

## Release layout

- A `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-beta.N` release is one GitHub release record containing Core, Full, Plugins, checksums, `plugins-index.json`, and profile-aware update metadata.
- A plugin package keeps its own version and source binding, but its ZIP and checksum are uploaded as assets of the matching Core release.
- Public asset names identify the download choice: `BaslerPlayground-vX.Y.Z[-beta.N]-Core-Windows-x64.exe`, `BaslerPlayground-vX.Y.Z[-beta.N]-Full-Windows-x64.exe`, and `Plugin-<PluginName>-v<version>-Windows-x64.zip`.
- Core stable releases own GitHub's `Latest` pointer. Beta releases and the mutable compatibility pointers must never become `Latest`.

## Release tools

- `installer.ps1 --tag <core-tag> --output-directory <directory>` builds the Full Package installer; add `--core-only` for the lightweight Core installer. Use separate output directories for the two profiles.
- `assemble-release.ps1 -Tag <core-tag> -CoreArtifactDirectory <directory> -FullArtifactDirectory <directory> -PluginArtifactRoot <directory>` creates one combined release manifest and asset set.
- `deployment.ps1 -ArtifactDirectory <directory>` validates and uploads all profiles and plugin assets to one release. Use `-AllowPublished` only when consolidating a previously published release that is known to be incomplete.
- `plugin-package.ps1 --core-tag <core-tag> --source-ref <immutable-parent-ref> --plugin <id> --version <plugin-version>` builds one device-plugin ZIP.
- `plugin-catalog.ps1 -CoreTag <core-tag> -ReleaseTag <release-tag>` generates URLs for the matching Core release. `plugin-catalog-deployment.ps1` is reserved for maintaining the legacy compatibility pointer.

`--source-ref` is separate from the compatible Core tag so a parent commit containing only one device submodule update can produce a plugin package without rebuilding or replacing the Core source tag; the package is included in the next complete release asset set.

---

<p align="center">
  © 2026 Basler AG. All rights reserved.
</p>
