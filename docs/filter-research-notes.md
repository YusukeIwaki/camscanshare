# Filter Research Notes

## 2026-05-17: White-black noise reduction prototypes not adopted

References:

- https://csapp-inspection.vercel.app/libpagescanner
- https://csapp-inspection.vercel.app/libimageprocessor

Tested two docs-side white-black filter variants for reducing noise after binarization:

- `DenoiseColorImageBasedOnRollBall`-inspired rolling-ball background estimation.
- `ReflectBinaryColorShift*BG`-inspired stronger background normalization.

Result: neither prototype was useful enough to keep in the filter documentation or move into Android/iOS. On the noisy report sample, the rolling-ball variant slightly reduced some small black components, but the visual improvement was minor. The Reflect BG variant was even closer to the existing white-black output. Stronger inverted-background normalization was also checked briefly, but it made wrinkles and dirt on otherwise clean paper more likely to turn into black noise.

Decision: keep the existing white-black pipeline for now. Do not re-add these prototypes to `docs/src/pages/filters.astro` unless there is a new implementation detail or a new sample set that materially changes the result.
