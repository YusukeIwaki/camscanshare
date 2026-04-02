# Documentation Site

This directory contains the Astro-based documentation site for CamScanShare.

Note: the site content itself is currently only available in Japanese.

## Local Development

Run all commands from `docs/`.

```bash
npm install
npm run dev
```

Open [http://localhost:4321/](http://localhost:4321/) in your browser to view the documentation site. Each screen section contains an interactive mockup so you can inspect transitions and behavior.

## Project Structure

```text
docs/
├── src/
│   ├── layouts/Layout.astro     # Base layout using Atlassian Design System styling
│   └── pages/
│       ├── index.astro          # Main documentation page
│       ├── filters.astro        # Filter behavior documentation
│       └── image_lifecycle/
│           └── index.astro      # Image lifecycle and cache behavior documentation
├── public/
│   ├── mockups/                 # Interactive HTML mockups
│   │   ├── document-list.html   # Document list mockup
│   │   ├── camera-scan.html     # Camera scan mockup
│   │   ├── camera-retake.html   # Camera retake mockup
│   │   ├── page-list.html       # Page list mockup
│   │   └── page-edit.html       # Page edit mockup
│   ├── image_lifecycle/         # Lifecycle diagrams and animations embedded via iframe
│   └── algorithm/               # Static assets for algorithm and filter docs
├── astro.config.mjs
├── package.json
└── README.md
```

## Commands

| Command | Action |
| --- | --- |
| `npm install` | Install dependencies |
| `npm run dev` | Start the local dev server at `http://localhost:4321/` |
| `npm run build` | Build the static site |
| `npm run preview` | Preview the production build locally |

## Design Systems

| Target | Design System |
| --- | --- |
| Documentation site | [Atlassian Design System](https://atlassian.design/components) |
| App screen mockups | [Material Web](https://github.com/material-components/material-web) |

## Notes

- `public/mockups/` contains standalone interactive mockups embedded from the main documentation page.
- `public/image_lifecycle/` contains standalone HTML diagrams used by the image lifecycle documentation page.
- `public/algorithm/` contains sample images and generated assets used to explain detection and filter behavior.
