# Filter Research Notes

## 2026-07-04: Page-segmentation paper detector adopted (supersedes the LDRNet corner-regression attempt)

Input:

- User report that finder-preview paper detection is worse than CamScanner, with two example frames (a document inside a translucent plastic folder on a lap, and a white handout close-up). CamScanner hugs the true page tightly; our OpenCV detector picks a loose/edge-hugging quad.
- CamScanner reverse-engineering notes in `../CamScannerInspection` (`libpagescanner.so`, `libscannercs.so`).
- Reference list `ZZZHANG-jx/Recommendations-Document-Image-Processing`.
- SmartDoc 2015 Challenge 1 frames+models (24,889 real handheld frames with ground-truth quads), downloaded to `tmp/smartdoc15/`.
- Real improvement-report `source.jpg` frames under `report_server/reports/` (product-domain, no GT — visual eval only).

Candidate analysis:

- CamScanner's modern detector (`libpagescanner.so`) is a small **MNN CNN** with a Conv/Sigmoid head that produces a page region (`pagescan::InferNet::forward` + `SingleRectCrop`), refined by OpenCV and Catmull-Rom curve fitting; the legacy `libscannercs.so` classical Canny/contour path (downscale-to-320) is only a fallback. So the robust route is **page segmentation → contour → quad**, not direct corner regression.
- The 2026-06-15 LDRNet attempt (MobileNetV2 + 8-value corner regression, 224²) plateaued at ~0.53 IoU with a 0.0 high-IoU rate and was rejected. Segmentation is refinable by the existing OpenCV scoring/anchor code and degrades gracefully, so it was chosen instead.

Execution:

- Added a repository-local pipeline under `scripts/document_detection/`: a compact depthwise-separable U-Net (`seg_model.py`, export-clean: Conv/BN/ReLU6/bilinear/sigmoid only) at 320² RGB → 1-channel page-probability mask; a dataset (`dataset.py`) combining SmartDoc real frames (mask rasterized from the quad) with on-the-fly synthetic composites (a warped page over cluttered desk/lap backgrounds, with translucent plastic-folder overlay, cast shadow, and partial-occlusion hard cases, and background documents left unmasked as hard negatives); training/eval/export scripts.
- First pass (256², documents only ever sub-region): beat the OpenCV baseline on the SmartDoc background05 holdout but **collapsed on near-full-frame documents** (predicted a small central blob on full-page report frames). Fixed the distribution gap by adding full-frame/edge-touching synthetic placement plus a tight-crop augmentation that turns real SmartDoc sub-region frames into real near-full-frame examples with exact boundaries, and raised input to 320².
- Quad extraction: threshold the mask at 0.5, largest external contour, approxPolyDP (4-pt convex) with a minAreaRect fallback.

Result (SmartDoc background05 holdout, quad IoU; OpenCV baseline is a reference Canny+contour reimplementation on the identical set):

- Adopted checkpoint: `tmp/docdet-v2/best.pt` (epoch 2). Evaluation script on 300 held-out background05 frames (`--limit 300 --stride 8`): model mean IoU `0.5978`, median `0.6577`, p05 `0.0135`, IoU >= 0.80 `0.1100`, IoU >= 0.90 `0.0100`; reference OpenCV baseline mean IoU `0.0181`, median `0.0000`, p05 `0.0000`, IoU >= 0.80/0.90 `0.0000`. The training-time full validation pass for the same checkpoint recorded mean `0.6057`, median `0.6600`, p05 `0.0201`, IoU >= 0.80 `0.1207`, IoU >= 0.90 `0.0186`.
- Rejected follow-up: low-LR fine-tuning from the epoch-2 checkpoint (`tmp/docdet-v2ft`) degraded the held-out mean to `0.4006` at its best and then lower, so it was not exported.
- Report-frame overlays: the full-frame poster and the white-on-white handout that both the OpenCV baseline and the 256² model failed are now tracked tightly by the segmentation model.

Integration:

- Exported fp16 ONNX (`androidapp/app/src/main/assets/document_detection/pageseg-320-fp16.onnx`, ~0.23 MB) and Core ML (`iosapp/CamScanShare/MLModels/PageSegNet.mlpackage`) from the single PyTorch checkpoint. ONNX-to-PyTorch max diff on a deterministic smoke input is `0.0042`; Core ML converts and compiles cleanly (no torch.roll issue).
- Wired the model mask into the existing detector as one more candidate for the shared findBestQuad refinement (Android `DocumentSegmenter.kt` via ONNX Runtime, already a dependency; iOS `buildModelDocumentMask` in `OpenCVDocumentFilterBridge.mm` via Core ML). Score bonus 0.22. A weak/empty mask yields no candidate, so the OpenCV masks remain the fallback and a confident mask wins. Edge-touching quads are allowed only for the model candidate so near-full-frame scans can pass while the OpenCV fallback still rejects edge-hugging false positives. Both apps build.

Decision:

- Adopt PageSegNet as an app-bundled candidate, not as an outright replacement for OpenCV. It gets a score bonus and uses the same contour/scoring/anchor validation path; weak or empty model masks fall back to the existing OpenCV candidates.

## 2026-06-15: LDRNet-style document corner detector evaluated, mobile integration rolled back

Input:

- User request to improve paper detection quality toward CamScanner-like behavior using LDRNet.
- SmartDoc 2015 Challenge 1 frames release downloaded to `tmp/smartdoc15`.
- Current docs sample corpus from `docs/filter-samples.json`.

Execution:

- Added a repository-local PyTorch implementation of an LDRNet-style detector: MobileNetV2 features plus an 8-value corner regression head, fixed 224x224 RGB input, ImageNet normalization, and top-left/top-right/bottom-right/bottom-left normalized output.
- Trained locally with `.venv/bin/python scripts/train_ldrnet_detector.py --dataset-dir tmp/smartdoc15 --out-dir tmp/ldrnet-camscanshare --epochs 5 --batch-size 64 --max-train 12000 --max-val 2000 --stride 2 --num-workers 4 --pretrained`.
- Best checkpoint: `tmp/ldrnet-camscanshare/best.pt`, epoch 5, train records `11156`, validation records `1289`, validation IoU mean on the script's 200-sample check `0.5351`, IoU >= 0.90 pass rate `0.0`.
- Evaluated with `.venv/bin/python scripts/evaluate_document_detection.py --dataset-dir tmp/smartdoc15 --checkpoint tmp/ldrnet-camscanshare/best.pt --out-dir tmp/ldrnet-camscanshare/eval --smartdoc-limit 1000 --smartdoc-stride 4 --overlay-limit 24 --write-docs-assets`.
- SmartDoc background05 validation subset, 645 evaluated frames:
  - OpenCV mean IoU `0.3423`, median `0.2491`, p05 `0.1482`, IoU >= 0.80 pass rate `0.1116`, IoU >= 0.90 pass rate `0.0279`.
  - LDRNet-style mean IoU `0.5376`, median `0.5517`, p05 `0.3887`, IoU >= 0.80 pass rate `0.0`, IoU >= 0.90 pass rate `0.0`.
- Temporarily exported mobile models:
  - Android: `androidapp/app/src/main/assets/document_detection/ldrnet-224-fp32.onnx`, opset 18, single-file ONNX, about 9.1 MB, ONNX Runtime CPU smoke test passed.
  - iOS: `iosapp/CamScanShare/MLModels/LDRNet.mlpackage`, Core ML mlprogram, Xcode `coremlc` compile passed in the simulator build.
- Temporarily generated docs-side overlays under `docs/public/algorithm/detection/` and added OpenCV/LDRNet toggles to the `台形選択` section.

Result:

- LDRNet improves average overlap on the SmartDoc validation subset compared with the current OpenCV detector, especially by avoiding some very low-overlap OpenCV failures.
- The trained local model is still not precise enough to replace the OpenCV detector outright: high-IoU pass rates are zero on this evaluation pass, and docs sample overlays show rough global quadrilateral placement rather than consistently tight paper boundaries.
- The temporary app integration therefore treated LDRNet as a gated capture-time candidate only. Even that conservative shape was not kept, because the quality was not yet high enough to justify the model/runtime surface.

Decision:

- Do not adopt the LDRNet-style detector in Android/iOS or docs for now. Remove the temporary scripts, mobile model assets, app integration, and docs overlay UI from the working tree, keeping this note as the record of the experiment.
- Do not claim CamScanner parity. The next useful iteration is better training data and target shaping before integration: more epochs, higher-resolution or feature-map-based corner prediction, synthetic hard negatives, real improvement-report frames, and evaluation against a manually labeled subset from this app.

## 2026-06-12: GCDRNet adopted as the 影除去 (deshadow) product filter

Input:

- User-supplied 3-page school-event PDF `tmp/e4e86ad2-161a-486b-ab29-4152ce41dd78.pdf` rendered at 150/300 dpi, with `tmp/令和8年度能古島小中学校運動会.pdf` as the CamScanner-like visual target.
- Full docs sample corpus from `docs/filter-samples.json` plus the local dev sample.
- GCDRNet code from `ZZZHANG-jx/GCDRNet`, checkpoints from Hugging Face `FahNos/GCDRnet` (`gcnet.pkl` 3ch/1.47M params, `drnet.pkl` 6ch/4.18M params; this rehost has correct file naming, unlike the earlier swap).

Execution:

- Reproduced the 2026-06-07 GCDRNet result: full-res inference on MPS reaches near-target paper whiteness on all 3 pages in 0.4-1.6 s/page.
- Designed a mobile-shaped pipeline: GCNet on a fixed 512x512 square resize, DRNet on an aspect-fit resize inside a 1024x1024 replicate-padded square, then a gain map (DRNet output / DRNet input, Gaussian sigma 2.0, +8 epsilon) bilinearly upsampled and multiplied onto the full-resolution image. The gain map keeps original-resolution text/photo sharpness; direct upsampling of the 1024 output visibly thickens fine strokes.
- Exported fixed-shape ONNX (opset 17). fp16 conversion is visually lossless (max diff 5/255): gcnet 3.2 MB + drnet 8.3 MB = 11.5 MB total. Mac CPU end-to-end via onnxruntime: ~0.46 s for a 2480x3509 page, so a mid-range phone should stay well inside the 10 s/A4 budget.
- OpenCV dnn cannot load the ONNX (the torch.roll Slice decomposition is unsupported), so Android uses ONNX Runtime (`com.microsoft.onnxruntime:onnxruntime-android`).
- Converted the same checkpoints to Core ML mlpackages (fp16 mlprogram, iOS17 target) via torch.export + run_decompositions; the legacy jit.trace path fails on aten::Int. GCNet runs on all compute units; DRNet fails to build an ANE plan at 1024x1024 and must be loaded with CPU+GPU compute units (Mac GPU warm run ~0.04 s). Core ML pipeline output matches the ONNX pipeline (max diff 5/255).
- Full-corpus evaluation: all 17 docs samples are broadly safe. Strong improvements on shadowed/creased paper (notepad, school handouts, timetable); color posters, whiteboard marker colors, and the dollar bill remain intact; faint pencil on the math sheet stays readable. The blue noisy report keeps some blue crease residue (improved but not fully cleaned), consistent with the earlier DocRes evaluation.

Decision:

- Ship as product filter 影除去 (`deshadow`), placed between 超強化 and マジック.
- Single source of truth for the models is the fp16 ONNX pair committed under `androidapp/app/src/main/assets/deshadow/`; `scripts/deshadow_pipeline.py` (used by `scripts/generate_deshadow_filter_samples.py`) runs the identical pipeline for docs, and iOS uses Core ML conversions under `iosapp/CamScanShare/MLModels/`.
- This supersedes the 2026-06-07 "do not ship DocRes" decision only in the sense that GCDRNet (a far smaller UNeXt pair from the same group) is shippable; the DocRes Restormer itself remains rejected for mobile.

## 2026-06-07: GL-PGENet paper implementation as deterministic mobile filter

Input:

- Paper: `arXiv:2505.22021v2`, GL-PGENet: A Parameterized Generation Framework for Robust Document Image Enhancement.
- Upstream repository: `kukugpt/GL-PGENet`.
- Full docs sample corpus from `docs/filter-samples.json`, plus the local dev sample when present.

Execution:

- Checked the upstream repository. `inference.py` is empty, there are no model definitions, and the README still lists pretrained model and inference-mode upload as TODO.
- The paper's exact neural pipeline requires GPPNet pretraining and DB-LRNet training on 500,000+ synthetic samples, then task-specific fine-tuning. The public materials do not provide enough architecture/training code to reproduce a verified checkpoint in this repo.
- Implemented an app-shippable `glpgenet` filter that follows the paper's parameterized-generation shape without learned weights:
  - GPPNet approximation: estimate brightness, contrast, and color-preservation strength from page luminance/chroma statistics.
  - DB-LRNet approximation: generate local `alpha`/`beta` maps from local mean/stddev over the luminance channel.
  - Final synthesis: apply `alpha * h(I) + beta`, fuse high-frequency detail residuals, then protect text, color accents, and color-rich paper regions.
- Generated docs outputs with `scripts/generate_simple_filter_samples.py --filter glpgenet`.
- Product display name: `超強化`.

Result:

- Broadly safe on the full sample set: no checked sample had completely unreadable text, fully blown document content, or destroyed color information.
- Improves ordinary paper samples, the dirty-white timetable, and the blue noisy report by whitening paper and increasing text contrast more strongly than `enhance`.
- The handwritten math page becomes high contrast and somewhat harsher, but faint handwriting is still visible.
- Color poster and paper-currency samples retain useful color; GL-PGENet is less color-destructive than a hard grayscale/BW filter.
- Whiteboard samples remain usable, though the dedicated `whiteboard` filter is still the better preset for marker-board photos.

Decision:

- Ship `超強化` as a deterministic OpenCV filter inspired by GL-PGENet, not as the exact pretrained neural network.
- Do not claim model parity with the paper's quantitative results, because no public checkpoint or complete inference/training implementation is available.
- Keep this filter in docs, Android, and iOS because it adds a useful stronger color-preserving document cleanup option without bundling a large neural runtime.

## 2026-06-07: Real `DocRes` appearance filter evaluated, mobile adoption rejected

Input:

- Full docs sample corpus from `docs/filter-samples.json`, plus the local dev sample when present.
- Upstream DocRes checkout at `tmp/deshadow-repos/DocRes`.
- DocRes checkpoint from Hugging Face `DaVinciCode/doctra-docres-main/docres.pkl`.

Execution:

- Generated reference outputs locally with the real DocRes Restormer `appearance` task, using max side 512 for the docs sample corpus.
- Exported fixed 512x512 mobile ONNX candidates from the same checkpoint to estimate model size and integration feasibility.
- Temporarily integrated bundled ONNX models into Android and iOS to measure practical app behavior.

Result:

- This is the real DocRes Restormer `appearance` task, not the lightweight OpenCV approximation.
- Strongly improves broad paper shading on notepad, school handout, receipt/form, and many ordinary document samples.
- The hand-written math sample becomes cleaner but some faint pencil strokes look weaker, so it is not a universally safe product filter.
- The color poster and whiteboard samples remain usable, but this reference is still tuned for document appearance restoration rather than color fidelity.
- The noisy blue report sample keeps some blue/purple shadow residue around the page, confirming that DocRes appearance is not a complete crease/shadow solution on every case.
- Android applied the filter but was far slower than normal filters, roughly an order of magnitude slower in interactive use.
- iOS continued to crash during filter application even after reducing output memory pressure; the observed device-console termination was `signal 9`, consistent with iOS killing the app under memory pressure.

Decision:

- Do not ship DocRes as a product filter for now.
- Do not keep the temporary Android/iOS ONNX Runtime implementation, bundled ONNX models, docs-side DocRes filter page entry, generated DocRes docs assets, or DocRes export/generation scripts in the repo.
- Keep only this research note as evidence that DocRes can produce visually strong results but is currently unsuitable for this mobile app's filter pipeline.
- Do not reintroduce `影なし` as a lightweight substitute; that approximation was also rejected.

Mobile-size follow-up:

- Fixed input contract: fit the page into a 512x512 square while preserving aspect ratio, replicate-pad right/bottom, run DocRes appearance, crop back to the resized page, then resize to the original preview/output size.
- Generated mobile candidates under `tmp/docres-mobile-models/`:
  - FP32 ONNX: `63.61 MB`.
  - FP16 ONNX: `33.20 MB`.
  - Dynamic INT8 ONNX: `17.87 MB`.
  - Dynamic INT8 ORT format: `16.30 MB`.
- ONNX Runtime CPU smoke test succeeded for FP32, FP16, dynamic INT8 ONNX, and dynamic INT8 ORT. On the local Mac CPU, FP16 was close to FP32 and fastest among the tested ONNX variants; INT8 was much smaller but slower in this local CPU test. Device-side timing still needs Android/iOS measurement.
- The model sizes are not impossible by themselves, but the runtime and memory behavior made the mobile integration unsuitable.

## 2026-06-07: Lightweight `shadowless` filter rejected after DocRes comparison

Input:

- Full docs sample corpus from `docs/filter-samples.json`, plus the local dev sample when present.
- DocRes `appearance` reference outputs generated from the same Step 1 images at max side 512 for comparison.
- User-supplied 3-page school-event PDF pages from the external deshadow sweep.

Tried:

- DocRes appearance reference using `tmp/deshadow-repos/DocRes/checkpoints/docres.pkl`.
- Four deterministic OpenCV variants inspired by DocRes `appearance_prompt`:
  - per-channel dilation + median background difference normalization,
  - local reflect background normalization on Lab L,
  - stronger masked paper whitening,
  - structure/accent/color-paper protection.

Result:

- DocRes is still better on very broad dark shadows, especially the notepad sample. It removes the diagonal shadow more completely than any lightweight OpenCV variant.
- The selected lightweight variant is close to DocRes on most ordinary documents, forms, receipts, dirty-white timetable samples, and the school handout examples.
- On the user-supplied PDF, the lightweight variant leaves slightly more paper texture than DocRes but avoids the purple cast and preserves colored panels more naturally.
- Color-heavy samples did not show catastrophic color loss. The kids poster remains usable, and whiteboard samples retain marker color.

Decision:

- Superseded as an implementation candidate; the real `DocRes` evaluation above also remains research-only.
- Do not keep `shadowless` / display name `影なし` as a product filter.
- Keep the notes only as a record of the rejected lightweight approximation.

## 2026-06-07: GCDRNet checkpoint evaluation on 3-page school-event PDF

Input:

- User-supplied 3-page PDF `e4e86ad2-161a-486b-ab29-4152ce41dd78.pdf`, rendered at 150 dpi for this pass.
- Visual target PDF `令和8年度能古島小中学校運動会.pdf`, rendered at 150 dpi for side-by-side comparison.
- Paper/repo reference: `ZZZHANG-jx/GCDRNet`, "Appearance Enhancement for Camera-captured Document Images in the Wild".

Execution notes:

- The downloaded checkpoint filenames appeared swapped relative to the official inference code: `drnet-checkpoint.pkl` matched the 3-channel GC-Net shape, while `gcnet-checkpoint.pkl` matched the 6-channel DR-Net shape.
- Official GCDRNet inference ran on Apple MPS after adapting the device handling outside the repository code. Full 150 dpi pages processed successfully, taking roughly 0.5-0.8 seconds per page after model load.
- Temporary deterministic "GCDR-lite" prototypes were also checked using background/shadow-map division, paper whitening, and content protection. They could whiten the page but either left too much natural paper texture or misclassified wrinkles as dark content, so they are not suitable to keep.

Result:

- GCDRNet substantially improves this specific PDF toward the CamScanner-like target. Median luminance moved from `225/215/217` on the source pages to `254/254/254` after GCDRNet; the target pages are `255/254.4/244.8`.
- Page 1 is close to the target in paper whiteness and text density. It still keeps some crease/purple-gray residue around the title and illustration, and the illustration is more contrasty/ink-like than the target.
- Page 2 is also close for background removal and layout readability. Some pale paper texture remains near the center fold and page edges.
- Page 3 improves strongly, especially broad paper shadows, but it is not identical to the target: color panels are less saturated and some fold/color residue remains in the lower pink area.

Decision:

- GCDRNet is a promising candidate for this sample and is materially closer to the target than the current docs-side `enhance`, `magic`, or `whiteboard` filters.
- Do not move it into Android/iOS yet. It needs full `docs/filter-samples.json` evaluation, model-size/runtime review, a color-preservation/cast postprocess, and a product decision about shipping an external neural network filter.

## 2026-06-07: External deshadow model sweep on 3-page school-event PDF

Input:

- User-supplied 3-page PDF `e4e86ad2-161a-486b-ab29-4152ce41dd78.pdf`, rendered at 180 dpi.
- Visual target PDF `令和8年度能古島小中学校運動会.pdf`, also rendered at 180 dpi.

Tried external pretrained deshadow/restoration candidates from `ZZZHANG-jx/Recommendations-Document-Image-Processing`:

- `deshadow-1`: DocShadow-ONNX SD7K, max side 1536.
- `deshadow-2`: DocShadow-ONNX Jung, max side 1536.
- `deshadow-3`: DocShadow-ONNX Kligler, max side 1536.
- `deshadow-4`: DocRes `deshadowing`, max side 1024 then upscaled.
- `deshadow-5`: DocRes `appearance`, max side 1024 then upscaled.
- `deshadow-6`: DocRes `deshadowing` followed by `appearance`, max side 1024 then upscaled.
- `deshadow-7`: BGShadowNet RDD pretrained, 512 square then upscaled.
- `deshadow-8`: BEDSR-Net Jung pretrained, 1024x768 / 768x1024 then upscaled.

Execution notes:

- DocShadow ONNX weights downloaded from the GitHub release and ran on CPU through onnxruntime.
- DocRes official OneDrive link returned 403, so the Hugging Face rehosted `docres.pkl` and `mbd.pkl` were used. Inference ran on MPS after loading weights on CPU.
- BGShadowNet Google Drive pretrained zip was downloaded successfully. The repo has hard-coded `.cuda()` tensor creation, so the local test used a monkey patch to route those tensors to MPS.
- BEDSR-Net pretrained zip was downloaded successfully. The old PyTorch implementation needed a local temporary fix for `ConvTranspose2d` argument compatibility and CUDA-saved weight loading.
- DocNLC was checked but not run: both OneDrive model-zoo links returned 403, and no equivalent accessible pretrained weights were found during this pass. Its documented dependency target is also old (`torch==1.7.1+cu101`).

Result:

- Best overall for matching the CamScanner-like target was `deshadow-5` (DocRes `appearance`). It whitened the wrinkled paper more than pure deshadow models while preserving text readability.
- `deshadow-6` whitened similarly but introduced stronger purple color cast, especially on pages 2 and 3.
- `deshadow-4` was useful but less scanner-like than `deshadow-5`.
- DocShadow, BGShadowNet, and BEDSR removed little of the crease/fold shading on this sample. They preserved color more naturally in some regions, but did not approach the reference PDF's white background.
- Page 3 remains the hardest case: DocRes appearance reduces paper shadows but weakens the colored blue/yellow/pink text panels compared with the CamScanner target, which keeps those colors stronger.

Decision:

- Do not adopt any external model as a product filter yet. The best candidate for this specific PDF is `deshadow-5`, but it is not a safe universal filter without all-sample evaluation and a color-cast correction stage.
- Keep the generated artifacts in `tmp/deshadow-eval/` as local comparison output for this run.

## 2026-06-07: Foreground-masked inpaint shading prototype tried as magic+

Input:

- User-supplied 3-page scanned PDF rendered at 180 dpi for a quick restoration check.

Tested a local-only prototype based on foreground-aware background estimation:

- Lab luminance correction with foreground masks from saturation, black-hat response, dark pixels, local texture, and Laplacian energy.
- Reduced-size Telea inpainting over the protected foreground mask, followed by morphological close and Gaussian smoothing to estimate the paper shading field.
- Ratio/log-domain luminance normalization, then soft whitening only on bright low-chroma pixels outside the protected mask.

Result: the direction is relevant, but it is not safe enough to replace the existing `magic` filter. It made page 1 and the colored timetable on page 2 a little cleaner while preserving most photo/color content, but it weakened thin map lines and pale labels on page 2. On page 3 it treated parts of the yellow and pink background text areas as removable paper/background, causing faint vertical text to lose contrast.

Initial decision: this direction was tried as a separate aggressive `magic_plus` filter after the user explicitly accepted that some document types may be damaged. The existing `magic` filter remained the safer default. The prototype should be treated as a non-universal cleanup preset: it can strongly whiten paper and suppress shading, but it may damage faint lines, handwriting, colored backgrounds, notebook paper, and dirty reports.

Follow-up from a 2-page wrinkled school handout PDF: the first adopted version protected too many wrinkle pixels as foreground/structure, then darkened them during the final content-preservation step. That made creases look like gray dirt after whitening. The prototype added a low-chroma, moderate-blackhat, moderate-local-delta `removable_texture_mask`; these weak wrinkle candidates were removed from foreground protection, included in paper whitening, and excluded from the final structure darkening mask. This reduced gray speckling on heavily wrinkled paper while keeping `magic_plus` explicitly aggressive and non-universal.

Second follow-up: local/global background color estimation was checked as a way to lift remaining gray smudges. A guided version could whiten broader paper haze, but the visible artifact on the wrinkled handout was mostly a final rendering-mask problem: weak gray halo around text and isolated gray dots were being preserved as foreground-adjacent content. A final low-saturation gray halo cleanup based on strong text cores, weak candidates, connected components, and distance-to-core limiting was tried. It keeps only gray pixels connected to a strong text/line core and close enough to be anti-aliasing; disconnected gray candidates and near-white low-saturation paper pixels are forced to white.

2026-06-07 rollback: Magic+ is removed from docs, Android, and iOS for now. Keep this section as a research record only; do not treat `magic_plus` as a current product filter or implementation target without re-evaluating it across the full sample corpus.

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
