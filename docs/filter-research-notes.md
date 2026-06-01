# Filter Research Notes

## 2026-05-18: Paired dark/bright crease-mask prototype

References:

- https://t3.ftcdn.net/jpg/19/26/88/38/360_F_1926883898_PUZvuk1lRZpEVlHlrMt7tRLWpjaNWwTX.jpg

Added a docs-side research pipeline for a learned "removable paper defect" mask:

- `scripts/generate_synthetic_crease_dataset.py` creates paired synthetic training images under `tmp/`. It uses clean school-handout-like pages plus a crease generator whose normal profile is explicitly bipolar: adjacent dark and bright lobes around one straight or curved fold centerline.
- The texture URL above can be supplied with `--texture-image`. It is cached under the selected `tmp/` output directory and used only as a temporary crease texture source, not committed to the repo.
- `scripts/train_crease_mask_model.py` trains a small U-Net from the synthetic mask labels. Foreground pixels without a synthetic crease are treated as hard negatives so text, ruled lines, QR blocks, and diagrams are not learned as removable defects.
- `scripts/apply_crease_mask_model.py` writes raw CNN probability/mask output plus a foreground-protected mask and conservative whitening preview.

Latest checked run:

- Dataset: `tmp/synthetic-crease-dataset-paired-v4`
- Model: `tmp/crease-mask-model-paired-v4-fg-hardneg/model.pt`
- Real-sample eval at threshold `0.75`: raw mask ratios went from earlier over-detection (`0.62`/`0.75` on the first weak model) down to `0.0134` and `0.0489`; foreground-protected masks were `0.0061` and `0.0126`.

Current assessment: this is a better direction than DnCNN or single directional kernels, but it is still a research prototype. The model still gives nonzero probability around strong printed shapes such as title backgrounds and buttons, so the production cleaning path must combine the CNN candidate mask with foreground/content protection. The next data iteration should add more hard negatives containing colored headings, pale filled shapes, attention buttons, diagrams, and ruled forms without creases.

## 2026-05-19: Broad fold whitening prototype

Target artifacts:

- Broad paper folds like `CleanShot 2026-05-19 at 00.06.19@2x.png` and `CleanShot 2026-05-19 at 00.06.39@2x.png`, where plain smoothing is insufficient because a fold contains a wide dark facet, a neighboring bright facet, and a steep transition ridge.

Changed the synthetic generator and inference prototype:

- Added wide fold synthesis with a signed-distance profile around each fold centerline. This creates a broad shadow lobe and adjacent highlight lobe, not just an independent dark scratch.
- Expanded the model input from 3 channels to 5 channels: luminance, local dark delta, local bright delta, broad dark delta, and gradient magnitude.
- Updated `scripts/apply_crease_mask_model.py` so the CNN mask is used as a seed for a broad soft whitening influence. The whitening preview now lifts luminance toward local paper white and mildly neutralizes chroma only inside the foreground-protected influence field.

Latest checked run:

- Dataset: `tmp/synthetic-crease-dataset-broad-v5`
- Model: `tmp/crease-mask-model-broad-v5/model.pt`
- Evaluation: `tmp/crease-mask-model-broad-v5-real-eval-th085-strongwhite/contact-sheet.jpg`

Current assessment: threshold `0.58` over-detects paper texture on full pages. Threshold `0.85` is much safer on full pages and still reacts to the attached crop-scale broad folds, but it is conservative and only partially whitens the broad facet. Threshold `0.78` removes more broad fold texture but starts producing too many full-page false positives. This confirms the expected production shape: a broad-fold model should be gated by high confidence, foreground/content protection, and probably page-scale hard negatives from real school handouts before being moved into Android/iOS.

Follow-up hard-negative run:

- Dataset: `tmp/synthetic-crease-dataset-hardneg-v6`
- Models:
  - `tmp/crease-mask-model-hardneg-v6/model.pt`: not adopted. The added negative examples were useful visually, but the training loss still leaned too heavily toward positives and the model over-detected full-page paper texture.
  - `tmp/crease-mask-model-hardneg-v7-strictbg/model.pt`: better calibrated by lowering positive weight and increasing background/foreground false-positive penalties.
- Best checked eval: `tmp/crease-mask-model-hardneg-v7-real-eval-th080/contact-sheet.jpg`

Result: v7 at threshold `0.80` is safer than the broad v6 pass on full pages and still reacts to the attached crop-scale folds, but the whitening remains partial. The remaining limitation is not just network shape; synthetic labels do not yet encode real broad fold facets precisely enough. The next meaningful improvement needs a small set of real crop annotations: fold/shadow pixels that should be whitened, and printed/graphic pixels on the same crop that must be protected.

Dark triangular shadow follow-up:

- Updated `scripts/apply_crease_mask_model.py` to treat the black triangular fold facet as a separate low-frequency dark-shadow target. The CNN mask is now only the high-confidence fold seed; a local paper-background estimate then expands whitening to nearby broad dark facets, and the final B/W output force-whitens only the protected shadow mask.
- Added a form-line guard for long printed horizontal/vertical rules so boxes and table borders are not removed when the fold crosses them.
- Added `cleaned-bw-aggressive.png` as a second output for the originally intended fold-ridge and local noise cleanup. It removes extra long sparse black components and tiny isolated components only inside the fold/shadow influence zone.
- Best checked eval: `tmp/crease-mask-model-hardneg-v7-darkshadow-bw-aggressive5-th080/contact-sheet.jpg`

Result: the attached black triangular shadow is substantially reduced in the final B/W output while printed box lines are preserved. The aggressive output removes more of the diagonal fold ridge and local speck noise, but it is intentionally separate because it carries higher risk around tiny text and punctuation.

2026-06-02 decision: do not adopt the CNN crease/shadow strategy for now. The all-sample comparison in `tmp/crease-mask-model-hardneg-v7-all-filter-samples-th080/output-comparison-sheet-1.jpg` and `tmp/crease-mask-model-hardneg-v7-all-filter-samples-th080/output-comparison-sheet-2.jpg` showed that the existing `original bw` output is the best overall baseline. The CNN path improves a few crease-heavy report samples, but the benefit is not broad enough to justify the added model/runtime complexity and the risk of deleting fine text, punctuation, ruled lines, or poster detail. Do not move this prototype into Android/iOS; keep the existing document B/W pipeline as the default.

## 2026-05-18: DnCNN and directional crease-kernel prototypes not adopted

References:

- https://qiita.com/jw-automation/items/f942ea0c6a02e8e50fa2
- https://huggingface.co/qualcomm/DnCNN
- https://csapp-inspection.vercel.app/libmagicenhancer#shadow-family
- https://csapp-inspection.vercel.app/libimageprocessor

Tested three docs-side white-black prototypes outside the committed filter set:

- Qualcomm AI Hub DnCNN ONNX model, tiled over the luminance channel before the existing local-mean white-black threshold.
- The same DnCNN pass blended weakly around text/structure masks so foreground strokes were protected.
- Directional fold candidates from 0/45/90/135 degree anisotropic kernels, with text/line protection and component filtering before forcing likely fold pixels to white.

Result: none was useful enough to keep. DnCNN is a Gaussian-noise denoiser, not a crease/shadow classifier. It slightly smoothed some inputs, but it did not reliably whiten paper folds and sometimes increased black pixels around thin structure. Directional kernels can find line-like crease candidates, but they are not a sufficient discriminator: drawings, borders, ruled lines, poster outlines, handwritten strokes, and folded shadows can share the same oriented response. Tightening the mask to avoid false positives made the output effectively identical to the existing white-black result; loosening it caused false positives on complex/color samples.

Sample-specific notes:

- `report-noisy-bw-android`: DnCNN did not remove the major wrinkle/fold artifacts. The protected blend was close to the existing output, with no meaningful readability gain.
- `report-timetable-dirty-white`: DnCNN and directional candidates left the dotted form structure intact, but did not clean folds enough to justify extra model/runtime cost.
- `report-kids-poster-color`: directional kernels are risky because poster outlines and decorative structure look like long fold candidates.
- `math-cheat-sheet`, `notepad`, and `tax`: foreground protection is mandatory; otherwise faint handwriting, ruled lines, and form boxes can be mistaken for crease structure.

Decision: do not move DnCNN or a pure directional-kernel fold remover into Android/iOS. Treat directional kernels only as a possible feature generator for a future learned crease/background classifier. A real crease-cleanup feature should use a supervised segmentation or matting model trained to output a "removable paper defect" mask, with explicit foreground-preservation loss and negative examples for text, charts, handwriting, ruled paper, borders, and poster graphics.

## 2026-05-17: Wang 2020/2019 shadow-removal preprocessing before white-black not adopted

References:

- https://github.com/CV-Reimplementation/TraditionalDocumentShadowRemoval
- [1] Wang, J.R. and Chuang, Y.Y., 2020. Shadow removal of text document images by estimating local and global background colors.
- [2] Wang, B. and Chen, C.P., 2019. An effective background estimation method for shadows removal of document images.

Tested two docs-side white-black variants:

- `[1]+白黒`: approximate local/global background color shadow removal before the existing white-black pipeline.
- `[2]+白黒`: approximate effective background estimation and tone adjustment before the existing white-black pipeline.

Result: neither variant was effective enough to keep. The existing white-black pipeline already does flat-field correction and local-mean normalization, so adding a traditional shadow-removal pass before it mostly produced small binarization differences. In several samples the variants slightly increased black pixels, wrinkle marks, or fine-line darkness instead of cleaning the background.

Sample-specific notes:

- `report-clean-paper-ios`: `[2]+白黒` increased black specks and wrinkle marks; `[1]+白黒` was closer to existing but not cleaner.
- `report-noisy-bw-android`: both variants left the major fold/shadow artifacts; `[2]+白黒` added more dark pixels.
- `math-cheat-sheet`, `tax`, `notepad`, and `whiteboard-kazakoshi`: variants tended to darken fine structure or ruled lines slightly without improving readability.
- `report-kids-poster-color`: `[1]+白黒` reduced some filled dark texture, but this was content-specific and did not offset the regressions.

Decision: revert the docs filter sections, Python prototype code, and generated comparison assets. Keep only this note; do not move either preprocessing step into Android/iOS.

## 2026-05-17: White-black noise reduction prototypes not adopted

References:

- https://csapp-inspection.vercel.app/libpagescanner
- https://csapp-inspection.vercel.app/libimageprocessor

Tested two docs-side white-black filter variants for reducing noise after binarization:

- `DenoiseColorImageBasedOnRollBall`-inspired rolling-ball background estimation.
- `ReflectBinaryColorShift*BG`-inspired stronger background normalization.

Result: neither prototype was useful enough to keep in the filter documentation or move into Android/iOS. On the noisy report sample, the rolling-ball variant slightly reduced some small black components, but the visual improvement was minor. The Reflect BG variant was even closer to the existing white-black output. Stronger inverted-background normalization was also checked briefly, but it made wrinkles and dirt on otherwise clean paper more likely to turn into black noise.

Decision: keep the existing white-black pipeline for now. Do not re-add these prototypes to `docs/src/pages/filters.astro` unless there is a new implementation detail or a new sample set that materially changes the result.

## 2026-05-17: Structure-connected small black dot cleanup not adopted

Tested a docs-side white-black post-processing variant that removed small black connected components when they were not near larger text-like or line-like black components. The intent was to keep punctuation, dakuten, and nearby text fragments while removing isolated wrinkle or dirt specks.

Result: the effect was limited on the noisy white-black samples. It reduced some small components, but the visible improvement was minor. The first version also removed dotted guide lines in the timetable sample because the dotted lines were interpreted as isolated small black components. A follow-up protection rule for dotted horizontal/vertical structures reduced that side effect, but the overall benefit remained too small to justify keeping the prototype.

Decision: do not keep this prototype in `docs/src/pages/filters.astro`, and do not move it into Android/iOS. Revisit only if there is a stronger text-structure classifier or a sample set where isolated black speck removal is clearly valuable without damaging dotted forms or faint writing.
