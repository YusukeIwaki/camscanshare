# OpenCV xcframework

This repository uses a generated `opencv2.xcframework` for the iOS preview-only
OpenCV pipeline.

Why this is generated instead of checked in:

- GitHub rejects the simulator slice because `libopencv_merged.a` exceeds 100 MB.
- The official `opencv-<version>-ios-framework.zip` release is not sufficient for
  this repository's current setup.
- This app uses a legacy static `opencv2` layout without the Objective-C wrapper.
- This app also needs an `arm64` iOS Simulator slice, so the xcframework is
  built from source and then repacked into the static-library layout expected by
  `iosapp/project.yml`.

## Regenerate

```bash
./iosapp/scripts/build_opencv_xcframework.sh
```

The default build uses OpenCV `4.13.0` and writes to
`iosapp/Vendor/opencv2.xcframework`.

Useful options:

```bash
./iosapp/scripts/build_opencv_xcframework.sh --keep-work
./iosapp/scripts/build_opencv_xcframework.sh --work-dir /tmp/opencv-build
./iosapp/scripts/build_opencv_xcframework.sh --version 4.13.0
```

## Verify

```bash
xcodebuild -scheme CamScanShare \
  -project iosapp/CamScanShare.xcodeproj \
  -destination 'generic/platform=iOS Simulator' \
  build
```

If the generated xcframework is in place, no project changes are required. The
app already references `iosapp/Vendor/opencv2.xcframework`.
