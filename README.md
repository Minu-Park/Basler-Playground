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

**Basler Playground** is a workspace for Basler vision devices. Connect Basler 2D and 3D cameras, CoaXPress framegrabbers, and LMI Gocator sensors in one application, watch the live image, and adjust a processing script while acquisition keeps running.

## What you can do

| Capability | What it does |
|------------|----------------|
| **Session workspace** | Keep several devices, their settings, and live inspection views together. Use more than one window when the job needs it. |
| **Script Editor** | Write a C++ script that reads the current frame and shows the processed result in the viewer. |
| **Interactive Parameters** | Mark a variable in the script. Playground turns that mark into a control you can move while the camera stays live. |
| **2D and 3D view** | Pan and zoom images, inspect profiles and point clouds, and place regions of interest. |
| **Basler cameras** | Acquire from Basler GigE, USB3, and 3D cameras. |
| **Basler framegrabbers** | Acquire CoaXPress streams from Basler framegrabbers. |
| **LMI Gocator** | Connect Gocator 3D sensors and profilers and inspect their profiles and surfaces. |

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

Install the current package from [**Releases**](https://github.com/Minu-Park/Basler-Playground/releases/latest).

- **Full** installs Playground together with its device packages.
- **Core** installs Playground only. Add or update cameras, framegrabbers, and sensors later from **Device > Manage Plugins**.

Further device packages are published in [Basler-Playground-Plugins](https://github.com/Minu-Park/Basler-Playground-Plugins).

Each release page shows a SHA-256 digest for the installer. Compare it before you run the file:

- Windows: `Get-FileHash <file> -Algorithm SHA256`
- macOS: `shasum -a 256 <file>`

### System requirements

- Windows 10 or Windows 11 (64-bit)
- macOS on Apple silicon, when that release includes a macOS package

## Supported devices

Playground uses these Basler Korea device projects:

| Device | Project |
|--------|---------|
| Basler 2D and 3D cameras | [BaslerKR/Camera](https://github.com/BaslerKR/Camera) |
| Basler CoaXPress framegrabbers | [BaslerKR/Framegrabber](https://github.com/BaslerKR/Framegrabber) |
| LMI Gocator sensors | [BaslerKR/Gocator](https://github.com/BaslerKR/Gocator) |

## Links

- 🌐 **Homepage**: [playground.minu.kr](https://playground.minu.kr)
- 📦 **Latest release**: [Download](https://github.com/Minu-Park/Basler-Playground/releases/latest)
- 🐛 **Issues**: [Report a bug](https://github.com/Minu-Park/Basler-Playground/issues)

---

<p align="center">
  © 2026 Basler AG. All rights reserved.
</p>
