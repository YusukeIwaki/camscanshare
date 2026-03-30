# CamScanShare

A mobile app focused on scanning paper documents, converting them to PDF, and sharing them through platform-native share features such as Google Drive and AirDrop.

## Overview

- **Scan**: Capture paper documents with the camera, with automatic paper detection, perspective correction, and cropping.
- **Adjust**: Improve readability with rotation and filters such as vivid, black-and-white, and whiteboard.
- **Share**: Export to PDF and share immediately with the OS-native share sheet.

## Screens

1. **Document List**: Home screen showing previously scanned documents.
2. **Camera Scan**: Camera capture screen with paper detection guidance.
3. **Page List**: Grid view of scanned pages, with sharing, editing, and page add actions.
4. **Page Edit**: Per-page rotation, filter adjustment, and retake.

## Project Structure

```
camscanshare/
├── androidapp/                  # Android app
├── iosapp/                      # iPhone / iPad app
├── docs/                        # Documentation site (Astro, only in Japanese)
├── README.md
└── CLAUDE.md
```

## Documentation

For the Astro-based documentation site, including local run commands, internal structure, and design notes, see [docs/README.md](/Users/yusuke-iwaki/src/github/YusukeIwaki/camscanshare/docs/README.md).
