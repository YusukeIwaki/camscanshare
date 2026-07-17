from __future__ import annotations

import argparse
import json
import mimetypes
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .finder_eval import REPO_ROOT, VALID_DOCUMENT_STATES, load_manifests, parse_sample


ANNOTATION_HTML = r"""<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Finder paper annotation</title>
  <style>
    :root { color-scheme: dark; font-family: system-ui, sans-serif; }
    body { margin: 0; background: #11151a; color: #eef2f6; }
    header, aside { padding: 12px 16px; background: #1b222b; }
    header { display: flex; align-items: center; gap: 12px; border-bottom: 1px solid #39424d; }
    header strong { min-width: 280px; }
    button, select, input, textarea { font: inherit; }
    button { padding: 8px 12px; border: 1px solid #5d6b7a; border-radius: 7px; background: #26313d; color: white; }
    button.primary { background: #1769aa; border-color: #4c9bd4; }
    button:disabled { opacity: .4; }
    main { display: grid; grid-template-columns: minmax(0, 1fr) 310px; min-height: calc(100vh - 58px); }
    .stage { display: grid; place-items: center; padding: 14px; overflow: auto; }
    canvas { max-width: calc(100vw - 360px); max-height: calc(100vh - 90px); border: 1px solid #657382; cursor: crosshair; background: #090b0d; }
    aside { border-left: 1px solid #39424d; display: flex; flex-direction: column; gap: 12px; }
    label { display: grid; gap: 5px; font-size: 13px; color: #bdc8d4; }
    select, input, textarea { box-sizing: border-box; width: 100%; padding: 7px; color: white; background: #10151b; border: 1px solid #536170; border-radius: 6px; }
    textarea { min-height: 72px; resize: vertical; }
    .hint { font-size: 12px; color: #9aa8b5; line-height: 1.5; }
    #points { font-family: ui-monospace, monospace; font-size: 12px; white-space: pre-wrap; }
    #status { min-height: 24px; color: #80cbc4; }
    .row { display: flex; gap: 8px; }
    .row > * { flex: 1; }
  </style>
</head>
<body>
<header>
  <button id="prev">← 前</button>
  <button id="next">次 →</button>
  <strong id="title">loading…</strong>
  <span id="count"></span>
</header>
<main>
  <div class="stage"><canvas id="canvas"></canvas></div>
  <aside>
    <div class="hint">完全表示の場合は、紙の角を TL → TR → BR → BL の順で4点クリックします。青線は保存済み、黄線は編集中です。</div>
    <label>状態
      <select id="state">
        <option value="unlabeled">未ラベル</option>
        <option value="fully_visible">完全表示</option>
        <option value="partially_visible">一部画面外</option>
        <option value="no_document">文書なし</option>
      </select>
    </label>
    <label>失敗タグ（カンマ区切り）<input id="tags"></label>
    <label>メモ<textarea id="notes"></textarea></label>
    <div id="points"></div>
    <div class="row"><button id="undo">1点戻す</button><button id="reset">点を消す</button></div>
    <button id="save" class="primary">保存して次へ</button>
    <div id="status"></div>
    <div class="hint">キー: S 保存、N/P 次/前、U 1点戻す、R リセット</div>
  </aside>
</main>
<script>
const canvas = document.querySelector('#canvas');
const ctx = canvas.getContext('2d');
const image = new Image();
let samples = [];
let index = 0;
let points = [];

function current() { return samples[index]; }
function setStatus(value, error=false) {
  const el = document.querySelector('#status'); el.textContent = value; el.style.color = error ? '#ef9a9a' : '#80cbc4';
}
function render() {
  if (!image.complete || !image.naturalWidth) return;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(image, 0, 0);
  if (points.length) {
    ctx.strokeStyle = '#ffd54f'; ctx.fillStyle = '#ffd54f'; ctx.lineWidth = Math.max(2, canvas.width / 400);
    ctx.beginPath();
    points.forEach((p, i) => { const x=p[0]*canvas.width, y=p[1]*canvas.height; if(i===0)ctx.moveTo(x,y); else ctx.lineTo(x,y); });
    if (points.length === 4) ctx.closePath();
    ctx.stroke();
    points.forEach((p, i) => {
      const x=p[0]*canvas.width, y=p[1]*canvas.height;
      ctx.beginPath(); ctx.arc(x,y,Math.max(5,canvas.width/160),0,Math.PI*2); ctx.fill();
      ctx.fillStyle='#111'; ctx.font=`${Math.max(12,canvas.width/60)}px sans-serif`; ctx.fillText(String(i+1),x+7,y-7); ctx.fillStyle='#ffd54f';
    });
  }
  document.querySelector('#points').textContent = points.map((p,i)=>`${i+1}: ${p[0].toFixed(5)}, ${p[1].toFixed(5)}`).join('\n') || '点なし';
}
function loadSample(nextIndex) {
  index = (nextIndex + samples.length) % samples.length;
  const sample = current();
  points = sample.corners ? sample.corners.map(p => [...p]) : [];
  document.querySelector('#title').textContent = sample.id;
  document.querySelector('#count').textContent = `${index+1} / ${samples.length}`;
  document.querySelector('#state').value = sample.document_state || 'unlabeled';
  document.querySelector('#tags').value = (sample.failure_tags || []).join(', ');
  document.querySelector('#notes').value = sample.notes || '';
  image.onload = () => { canvas.width=image.naturalWidth; canvas.height=image.naturalHeight; render(); };
  image.src = `/api/image?id=${encodeURIComponent(sample.id)}&v=${Date.now()}`;
  setStatus('');
}
canvas.addEventListener('click', event => {
  if (document.querySelector('#state').value !== 'fully_visible') return;
  const rect = canvas.getBoundingClientRect();
  if (points.length >= 4) points = [];
  points.push([(event.clientX-rect.left)/rect.width, (event.clientY-rect.top)/rect.height]);
  render();
});
async function save(advance=true) {
  const state = document.querySelector('#state').value;
  if (state === 'fully_visible' && points.length !== 4) { setStatus('完全表示は4点必要です', true); return; }
  const payload = {
    id: current().id,
    document_state: state,
    corners: state === 'fully_visible' ? points : null,
    failure_tags: document.querySelector('#tags').value.split(',').map(v=>v.trim()).filter(Boolean),
    notes: document.querySelector('#notes').value.trim()
  };
  const response = await fetch('/api/save', {method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify(payload)});
  const result = await response.json();
  if (!response.ok) { setStatus(result.error || '保存失敗', true); return; }
  Object.assign(current(), payload); setStatus('保存しました'); if (advance) loadSample(index+1);
}
document.querySelector('#prev').onclick=()=>loadSample(index-1);
document.querySelector('#next').onclick=()=>loadSample(index+1);
document.querySelector('#undo').onclick=()=>{points.pop();render();};
document.querySelector('#reset').onclick=()=>{points=[];render();};
document.querySelector('#save').onclick=()=>save(true);
document.querySelector('#state').onchange=event=>{ if(event.target.value!=='fully_visible') points=[]; render(); };
document.addEventListener('keydown', event => {
  if (['INPUT','TEXTAREA','SELECT'].includes(event.target.tagName)) return;
  const key=event.key.toLowerCase();
  if(key==='s')save(true); else if(key==='n')loadSample(index+1); else if(key==='p')loadSample(index-1); else if(key==='u'){points.pop();render();} else if(key==='r'){points=[];render();}
});
fetch('/api/samples').then(r=>r.json()).then(data=>{ samples=data.samples; if(!samples.length) throw new Error('samples are empty'); loadSample(0); }).catch(error=>setStatus(error.message,true));
</script>
</body>
</html>"""


def _safe_id(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-") or "sample"


class ManifestStore:
    def __init__(self, manifest_path: Path):
        self.path = manifest_path
        if not manifest_path.exists():
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "coordinate_space": "normalized_top_left",
                        "samples": [],
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n"
            )
        self.payload = json.loads(manifest_path.read_text())
        load_manifests([manifest_path])

    @property
    def samples(self) -> list[dict]:
        return self.payload.setdefault("samples", [])

    def by_id(self, sample_id: str) -> dict:
        for sample in self.samples:
            if sample.get("id") == sample_id:
                return sample
        raise KeyError(sample_id)

    def save_annotation(self, update: dict) -> None:
        sample = self.by_id(str(update.get("id", "")))
        state = str(update.get("document_state", "unlabeled"))
        if state not in VALID_DOCUMENT_STATES:
            raise ValueError(f"unsupported document_state: {state}")
        sample["document_state"] = state
        sample["corners"] = update.get("corners") if state == "fully_visible" else None
        sample["failure_tags"] = [str(value) for value in update.get("failure_tags", [])]
        notes = str(update.get("notes", "")).strip()
        if notes:
            sample["notes"] = notes
        else:
            sample.pop("notes", None)
        parse_sample(sample, self.path)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        temporary.write_text(json.dumps(self.payload, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(self.path)

    def discover_report_finders(self) -> int:
        existing_paths = {str(sample.get("image")) for sample in self.samples}
        added = 0
        pattern = "report_server/reports/report-*/debug/*paper-detection_finder*/01_input.png"
        for image_path in sorted(REPO_ROOT.glob(pattern)):
            relative = str(image_path.relative_to(REPO_ROOT))
            if relative in existing_paths:
                continue
            report_id = next(part for part in image_path.parts if part.startswith("report-"))
            session_id = image_path.parent.name
            self.samples.append(
                {
                    "id": _safe_id(f"{report_id}-{session_id}"),
                    "image": relative,
                    "source": "app_finder_report",
                    "split": "test",
                    "session_id": session_id,
                    "document_id": report_id,
                    "background_id": report_id,
                    "document_state": "unlabeled",
                    "corners": None,
                    "failure_tags": [],
                }
            )
            existing_paths.add(relative)
            added += 1
        if added:
            temporary = self.path.with_suffix(self.path.suffix + ".tmp")
            temporary.write_text(json.dumps(self.payload, ensure_ascii=False, indent=2) + "\n")
            temporary.replace(self.path)
        return added


def make_handler(store: ManifestStore):
    class Handler(BaseHTTPRequestHandler):
        def _json(self, payload: dict, status: HTTPStatus = HTTPStatus.OK) -> None:
            data = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json; charset=utf-8")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path == "/":
                data = ANNOTATION_HTML.encode()
                self.send_response(HTTPStatus.OK)
                self.send_header("content-type", "text/html; charset=utf-8")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if parsed.path == "/api/samples":
                self._json({"samples": store.samples})
                return
            if parsed.path == "/api/image":
                sample_id = parse_qs(parsed.query).get("id", [""])[0]
                try:
                    sample = store.by_id(sample_id)
                    path = (REPO_ROOT / str(sample["image"])).resolve()
                    path.relative_to(REPO_ROOT)
                    data = path.read_bytes()
                except (KeyError, OSError, ValueError):
                    self.send_error(HTTPStatus.NOT_FOUND)
                    return
                self.send_response(HTTPStatus.OK)
                self.send_header("content-type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_error(HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:  # noqa: N802
            if urlparse(self.path).path != "/api/save":
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            try:
                length = int(self.headers.get("content-length", "0"))
                payload = json.loads(self.rfile.read(length))
                store.save_annotation(payload)
            except (KeyError, ValueError, json.JSONDecodeError) as exc:
                self._json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
                return
            self._json({"ok": True})

        def log_message(self, format: str, *args) -> None:
            return

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description="Annotate finder frames with document corners")
    parser.add_argument("--manifest", default="docs/document-detection-eval.local.json")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--discover-report-finders", action="store_true")
    args = parser.parse_args()
    store = ManifestStore(Path(args.manifest))
    if args.discover_report_finders:
        print(f"added {store.discover_report_finders()} finder report sample(s)")
    server = ThreadingHTTPServer((args.host, args.port), make_handler(store))
    print(f"annotation UI: http://{args.host}:{args.port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
