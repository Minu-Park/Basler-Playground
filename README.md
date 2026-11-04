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

**Basler Playground** is a workspace for machine vision devices. Connect Basler 2D and 3D cameras, Basler frame grabbers, LMI Gocator sensors, Heliotis heliInspect systems and GenTL devices in one application, watch the live data in 2D and 3D, and adjust a processing script while acquisition keeps running.

## What you can do

| Capability | What it does |
|------------|----------------|
| **2D and 3D views** | Show the same frame as Image, Range, Surface or PointCloud from the display-mode bubble, without a conversion step. |
| **Measure** | Right-click the view to add a Rectangle or Line, then choose Histogram, Projection or Measure. Measure rows report target, field, unit, valid samples, minimum, maximum, mean and standard deviation, and can follow each new frame. |
| **Script Editor** | Write a C++ script that reads the current frame and shows the result in the viewer. Build, load and unload it without stopping acquisition. |
| **Interactive Parameters** | Mark a variable in the script. The loaded build turns it into a control you can move while the camera stays live. |
| **External libraries** | Register your own C++ libraries under **System › Libraries** with include, library and runtime DLL paths, then `#include` them in a script. |
| **MCP connection** | Turn on **System › MCP Connection** to let a trusted AI client on the same computer open sessions, work with devices and capture snapshots. Script editing and execution need a separate approval. |
| **Session workspace** | Keep several devices, their settings and live views together, across more than one window. |

## Interactive Parameters

Add an annotation next to a variable in the Script Editor. Playground builds a control for it, so you can tune the script on the live image.

```cpp
auto input = get().toMatGray();
auto output = cv::Mat();

int range = 127; // @interactive-range(1, 255)

cv::threshold(input, output, range, 255, cv::THRESH_BINARY);

show(output);
```

Move the slider for `range`. The view updates from the script without starting acquisition again.

## Download

Download the installer from the [**homepage**](https://playground.minu.kr) or the [**latest release**](https://github.com/Minu-Park/Basler-Playground/releases/latest):

- Windows: `BaslerPlayground-v<version>-Core-Windows-x64.exe`
- macOS: `BaslerPlayground-v<version>-Core-macOS-arm64.pkg`

Device support ships as separate plugin packages. Install, update or remove them from **System › Plugins** inside Playground. The packages are published in [Basler-Playground-Plugins](https://github.com/Minu-Park/Basler-Playground-Plugins).

Each release page shows a SHA-256 digest for the installer. Compare it before you run the file:

- Windows: `Get-FileHash <file> -Algorithm SHA256`
- macOS: `shasum -a 256 <file>`

### System requirements

- Windows 10 or Windows 11 (64-bit)
- macOS on Apple silicon, when that release includes a macOS package

## Supported devices

Each device family is a plugin with its own version:

| Plugin | Runtime | Devices |
|--------|---------|---------|
| Camera | Basler pylon | Basler 2D cameras and supported 3D cameras (GigE, USB3, blaze, Stereo ace, Stereo mini) |
| Frame Grabber | Basler Frame Grabber SDK | Basler frame grabbers with applets and multiple DMA channels |
| Gocator | LMI GoPxL | LMI Gocator 3D sensors and profilers |
| Heliotis C4 | C4Utility | Heliotis heliInspect H8 systems |
| GenICam | GenTL / GenApi | Devices exposed by GenTL producers (`.cti`) |

## Links

- 🌐 **Homepage**: [playground.minu.kr](https://playground.minu.kr)
- 📦 **Latest release**: [Download](https://github.com/Minu-Park/Basler-Playground/releases/latest)
- 🧩 **Device plugins**: [Basler-Playground-Plugins](https://github.com/Minu-Park/Basler-Playground-Plugins/releases)
- 🐛 **Issues**: [Report a bug](https://github.com/Minu-Park/Basler-Playground/issues)

---

<p align="center">
  © 2026 Basler AG. All rights reserved.
</p>
