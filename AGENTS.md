# Repository Guidelines

## Start Here

- Read `CLAUDE.md` first. It contains the product overview, screen design workflow, and platform implementation notes.
- Treat `docs/` as the source of truth for UX and filter behavior. Validate there before changing app code.
- If the task involves filter design, tuning, or evaluation, also read `.codex/skills/filter-evaluation/SKILL.md`.

## Filter Evaluation Mission

- `docs/src/pages/filters.astro` and `http://localhost:4321/filters` are the primary evaluation surface for filters. This page exists so humans can quickly compare before/after results across many samples.
- When evaluating a filter, the agent's job is not to judge a few hand-picked examples. The agent must regenerate outputs for all test images with the Python pipeline and reason about robustness across the full sample set in `docs/filter-samples.json`.
- A filter change is only acceptable when it does not produce an extremely bad result on any test image, even if some images are not the filter's ideal target. Optimize for broad safety and usefulness, not a narrow best case.
- Use the generated artifacts plus the `/filters` page together: generate with Python, then inspect the results in the browser UI that humans will use to review them.
- Record important tradeoffs explicitly. If one sample improves at the cost of another, call that out instead of silently optimizing for the easiest image.

## Expected Filter Workflow

1. Regenerate affected assets with the Python scripts in `scripts/`.
2. Review the changed outputs in `http://localhost:4321/filters` with `agent-browser`.
3. Compare across all relevant samples, looking for catastrophic regressions such as unreadable text, blown highlights, destroyed faint strokes, excessive background noise, or unintended loss of color information.
4. Only after the docs-side evaluation is solid should the change be propagated to `androidapp/` or `iosapp/`.

## Key Files

- `docs/filter-samples.json`: canonical sample set that must be evaluated.
- `docs/src/pages/filters.astro`: human review UI for comparing filter outputs.
- `scripts/filter_asset_pipeline.py`: shared Python implementation of the filter asset pipeline.
- `scripts/generate_filter_assets.sh`: end-to-end regeneration command for all current samples.
