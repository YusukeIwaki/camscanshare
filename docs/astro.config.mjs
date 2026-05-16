// @ts-check
import { defineConfig } from 'astro/config';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const FILTER_KEYS = ['bw', 'eco', 'enhance', 'magic_pro', 'sharpen', 'vivid', 'whiteboard'];

function publicRelativePath(path) {
  return path.replace(/^docs\/public\//, '').replace(/^public\//, '');
}

function privateSampleCleanup() {
  return {
    name: 'private-sample-cleanup',
    hooks: {
      'astro:build:done': ({ dir }) => {
        const localManifestUrl = new URL('./filter-samples.local.json', import.meta.url);
        if (!existsSync(localManifestUrl)) return;

        const distRoot = fileURLToPath(dir);
        const samples = JSON.parse(readFileSync(localManifestUrl, 'utf-8'));
        const paths = new Set();

        for (const sample of samples) {
          for (const key of ['source', 'step0', 'step1', 'magic_step2', 'magic_step3']) {
            if (sample[key]) paths.add(publicRelativePath(sample[key]));
          }

          const step1File = sample.step1?.split('/').pop() ?? '';
          const base = step1File.replace(/-step1\.[^.]+$/, '').replace(/\.[^.]+$/, '');
          for (const filterKey of FILTER_KEYS) {
            const explicit = sample.filters?.[filterKey];
            paths.add(publicRelativePath(explicit ?? `docs/public/algorithm/filters/${filterKey}/${base}.png`));
          }
        }

        for (const path of paths) {
          rmSync(join(distRoot, path), { force: true });
        }
      },
    },
  };
}

// https://astro.build/config
export default defineConfig({
  integrations: [privateSampleCleanup()],
});
