import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import express from "express";
import multer from "multer";
import QRCode from "qrcode";
import AdmZip from "adm-zip";

const app = express();
app.set("trust proxy", true);
const port = Number.parseInt(process.env.PORT ?? "3030", 10);
const reportToken = process.env.REPORT_SERVER_TOKEN ?? crypto.randomBytes(24).toString("hex");
const reportsDir = path.resolve("reports");

fs.mkdirSync(reportsDir, { recursive: true });

const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 100 * 1024 * 1024,
  },
});

app.use(express.urlencoded({ extended: false }));

app.get("/", (_req, res) => {
  res.redirect("/qr");
});

app.get("/qr", async (req, res) => {
  res.send(await renderQrPage({
    ngrokUrl: inferDefaultPublicBaseUrl(req),
    qrDataUrl: null,
    qrPayload: null,
    errorMessage: null,
  }));
});

app.get("/reports", async (_req, res) => {
  const reports = loadReportIndex();
  res.send(renderReportsIndexPage(reports));
});

app.get("/reports/:reportId/files/:fileName", (req, res) => {
  const { reportId, fileName } = req.params;
  const reportDir = resolveReportDirectory(reportId);
  if (!reportDir) {
    res.status(404).send("report not found");
    return;
  }

  const safeFileName = path.basename(fileName);
  const filePath = path.join(reportDir, safeFileName);
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    res.status(404).send("file not found");
    return;
  }

  res.sendFile(filePath);
});

app.get("/reports/:reportId", async (req, res) => {
  const detail = loadReportDetail(req.params.reportId);
  if (!detail) {
    res.status(404).send(renderSimpleMessagePage("レポートが見つかりませんでした。", "/reports", "レポート一覧へ戻る"));
    return;
  }

  res.send(renderReportDetailPage(detail));
});

app.post("/qr", async (req, res) => {
  const ngrokUrlInput = (req.body.ngrokUrl ?? "").trim();
  if (!ngrokUrlInput) {
    res.status(400).send(await renderQrPage({
      ngrokUrl: "",
      qrDataUrl: null,
      qrPayload: null,
      errorMessage: "ngrok の URL を入力してください。",
    }));
    return;
  }

  let reportEndpoint;
  try {
    const normalizedUrl = normalizePublicBaseUrl(ngrokUrlInput);
    reportEndpoint = `${normalizedUrl}/reports`;
  } catch (error) {
    res.status(400).send(await renderQrPage({
      ngrokUrl: ngrokUrlInput,
      qrDataUrl: null,
      qrPayload: null,
      errorMessage: error instanceof Error ? error.message : "ngrok URL の形式が不正です。",
    }));
    return;
  }

  const qrPayload = buildQrPayload(reportEndpoint, reportToken);
  const qrDataUrl = await QRCode.toDataURL(qrPayload, {
    errorCorrectionLevel: "M",
    margin: 2,
    width: 320,
  });

  res.send(await renderQrPage({
    ngrokUrl: ngrokUrlInput,
    qrDataUrl,
    qrPayload,
    errorMessage: null,
  }));
});

app.post("/reports", upload.single("archive"), async (req, res) => {
  if (!isAuthorized(req)) {
    res.status(401).json({ error: "invalid_token" });
    return;
  }

  if (!req.file) {
    res.status(400).json({ error: "archive_required" });
    return;
  }

  const comment = String(req.body.comment ?? "").trim();
  if (!comment) {
    res.status(400).json({ error: "comment_required" });
    return;
  }

  const reportDir = createReportDirectory();
  try {
    extractZipBuffer(req.file.buffer, reportDir);
    writeSummary(reportDir, {
      comment,
      appVersion: String(req.body.appVersion ?? "").trim(),
      buildNumber: String(req.body.buildNumber ?? "").trim(),
      timestampJst: String(req.body.timestampJst ?? "").trim(),
      pageId: String(req.body.pageId ?? "").trim(),
      currentFilter: String(req.body.currentFilter ?? "").trim(),
    });
  } catch (error) {
    fs.rmSync(reportDir, { recursive: true, force: true });
    res.status(500).json({
      error: "report_extract_failed",
      message: error instanceof Error ? error.message : "レポート展開に失敗しました。",
    });
    return;
  }

  res.status(201).json({
    ok: true,
    reportDirectory: path.basename(reportDir),
  });
});

app.listen(port, () => {
  console.log(`CamScanShare report server listening on http://localhost:${port}`);
  console.log(`Access token: ${reportToken}`);
});

function isAuthorized(req) {
  const authHeader = req.get("authorization") ?? "";
  const bearerToken = authHeader.startsWith("Bearer ") ? authHeader.slice("Bearer ".length).trim() : "";
  const headerToken = (req.get("x-report-token") ?? "").trim();
  return bearerToken === reportToken || headerToken === reportToken;
}

function normalizePublicBaseUrl(value) {
  const parsed = new URL(value);
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    throw new Error("ngrok URL は http または https で始めてください。");
  }
  parsed.pathname = "";
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString().replace(/\/$/, "");
}

function inferDefaultPublicBaseUrl(req) {
  const host = (req.get("host") ?? "").trim();
  if (!host) return "";

  const hostname = host
    .replace(/:\d+$/, "")
    .replace(/^\[(.*)\]$/, "$1")
    .toLowerCase();

  if (hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1") {
    return "";
  }

  return `${req.protocol}://${host}`;
}

function buildQrPayload(reportEndpoint, token) {
  const params = new URLSearchParams({
    u: reportEndpoint,
    t: token,
  });
  return `camscanshare://bug-report-config?${params.toString()}`;
}

function createReportDirectory() {
  const now = new Date();
  const baseName = [
    now.getFullYear(),
    pad2(now.getMonth() + 1),
    pad2(now.getDate()),
  ].join("-") + "_" + [
    pad2(now.getHours()),
    pad2(now.getMinutes()),
    pad2(now.getSeconds()),
  ].join("-");

  let directoryName = `report-${baseName}`;
  let sequence = 1;
  let candidate = path.join(reportsDir, directoryName);
  while (fs.existsSync(candidate)) {
    directoryName = `report-${baseName}-${String(sequence).padStart(2, "0")}`;
    candidate = path.join(reportsDir, directoryName);
    sequence += 1;
  }
  fs.mkdirSync(candidate, { recursive: false });
  return candidate;
}

function extractZipBuffer(buffer, destinationDir) {
  const zip = new AdmZip(buffer);
  const usedNames = new Set();

  for (const entry of zip.getEntries()) {
    if (entry.isDirectory) continue;

    const sanitizedName = sanitizeEntryName(entry.entryName, usedNames);
    const outputPath = path.join(destinationDir, sanitizedName);
    fs.writeFileSync(outputPath, entry.getData());
  }
}

function sanitizeEntryName(entryName, usedNames) {
  const parsedName = path.basename(entryName).replace(/[^A-Za-z0-9._-]/g, "_");
  const fallbackName = parsedName.length > 0 ? parsedName : "file";

  let candidate = fallbackName;
  let index = 1;
  while (usedNames.has(candidate)) {
    const ext = path.extname(fallbackName);
    const base = fallbackName.slice(0, Math.max(0, fallbackName.length - ext.length)) || "file";
    candidate = `${base}-${index}${ext}`;
    index += 1;
  }

  usedNames.add(candidate);
  return candidate;
}

function writeSummary(reportDir, fields) {
  const lines = [
    `comment: ${fields.comment}`,
    `appVersion: ${fields.appVersion || "-"}`,
    `buildNumber: ${fields.buildNumber || "-"}`,
    `timestampJst: ${fields.timestampJst || "-"}`,
    `pageId: ${fields.pageId || "-"}`,
    `currentFilter: ${fields.currentFilter || "-"}`,
  ];
  fs.writeFileSync(path.join(reportDir, "summary.txt"), `${lines.join("\n")}\n`, "utf8");
}

function pad2(value) {
  return String(value).padStart(2, "0");
}

function resolveReportDirectory(reportId) {
  const safeId = path.basename(reportId);
  const reportDir = path.join(reportsDir, safeId);
  if (!reportDir.startsWith(reportsDir)) return null;
  if (!fs.existsSync(reportDir) || !fs.statSync(reportDir).isDirectory()) return null;
  return reportDir;
}

function loadReportIndex() {
  return fs.readdirSync(reportsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("report-"))
    .map((entry) => {
      const reportId = entry.name;
      const reportDir = path.join(reportsDir, reportId);
      const summary = readSummaryFile(reportDir);
      const fileCount = fs.readdirSync(reportDir, { withFileTypes: true }).filter((child) => child.isFile()).length;
      const stat = fs.statSync(reportDir);
      return {
        reportId,
        summary,
        fileCount,
        createdAt: stat.birthtimeMs || stat.mtimeMs,
      };
    })
    .sort((a, b) => b.createdAt - a.createdAt);
}

function loadReportDetail(reportId) {
  const reportDir = resolveReportDirectory(reportId);
  if (!reportDir) return null;

  const files = fs.readdirSync(reportDir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .sort((a, b) => {
      if (a === "summary.txt") return -1;
      if (b === "summary.txt") return 1;
      return a.localeCompare(b);
    });

  const summary = readSummaryFile(reportDir);
  return {
    reportId,
    summary,
    files: files.map((fileName) => ({
      fileName,
      url: `/reports/${encodeURIComponent(reportId)}/files/${encodeURIComponent(fileName)}`,
      isImage: /\.(png|jpe?g|gif|webp)$/i.test(fileName),
      isSummary: fileName === "summary.txt",
    })),
  };
}

function readSummaryFile(reportDir) {
  const summaryPath = path.join(reportDir, "summary.txt");
  if (!fs.existsSync(summaryPath)) {
    return {};
  }

  const text = fs.readFileSync(summaryPath, "utf8");
  const fields = {};
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const separatorIndex = line.indexOf(":");
    if (separatorIndex < 0) continue;
    const key = line.slice(0, separatorIndex).trim();
    const value = line.slice(separatorIndex + 1).trim();
    fields[key] = value;
  }
  return fields;
}

async function renderQrPage({ ngrokUrl, qrDataUrl, qrPayload, errorMessage }) {
  return `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CamScanShare 改善レポート QR 発行</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f7fb;
      --card: #ffffff;
      --line: #d9e1ec;
      --text: #17212c;
      --muted: #526173;
      --primary: #1769e0;
      --danger-bg: #fdecec;
      --danger-text: #b3261e;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    .wrap {
      max-width: 1080px;
      margin: 0 auto;
      padding: 32px 20px 48px;
    }
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 24px;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 18px 20px;
      box-shadow: 0 12px 28px rgba(19, 36, 64, 0.05);
    }
    h1 {
      margin: 0 0 6px;
      font-size: 28px;
    }
    .lead {
      margin: 0;
      color: var(--muted);
      line-height: 1.6;
    }
    label {
      display: block;
      margin-bottom: 8px;
      font-size: 14px;
      font-weight: 700;
    }
    input {
      width: 100%;
      height: 48px;
      padding: 0 14px;
      border: 1px solid var(--line);
      border-radius: 14px;
      font-size: 15px;
    }
    input[readonly] {
      background: #eef3fb;
      color: #35465a;
    }
    .field {
      margin-bottom: 20px;
    }
    .hint {
      margin-top: 6px;
      font-size: 13px;
      color: var(--muted);
      line-height: 1.5;
    }
    button {
      height: 48px;
      padding: 0 20px;
      border: none;
      border-radius: 14px;
      background: var(--primary);
      color: white;
      font-size: 15px;
      font-weight: 700;
      cursor: pointer;
    }
    .error {
      margin-bottom: 20px;
      padding: 14px 16px;
      border-radius: 14px;
      background: var(--danger-bg);
      color: var(--danger-text);
      font-size: 14px;
      line-height: 1.5;
    }
    .result {
      display: grid;
      gap: 16px;
      margin-top: 16px;
    }
    .grid {
      display: grid;
      gap: 16px;
    }
    .form-card {
      max-width: 720px;
    }
    .qr-box {
      display: inline-flex;
      padding: 16px;
      border-radius: 18px;
      background: white;
      border: 1px solid var(--line);
    }
    .payload {
      padding: 14px 16px;
      border-radius: 14px;
      background: #f7f9fc;
      border: 1px solid var(--line);
      word-break: break-all;
      font-family: ui-monospace, SFMono-Regular, monospace;
      font-size: 13px;
      line-height: 1.6;
    }
    .result-link {
      margin-top: 4px;
      font-size: 14px;
    }
    .result-link a {
      color: var(--primary);
      text-decoration: none;
      font-weight: 600;
    }
    .result-link a:hover {
      text-decoration: underline;
    }
  </style>
</head>
<body>
  <main class="wrap">
    <div class="header">
      <div>
        <h1>改善レポート QR 発行</h1>
        <p class="lead">Android / iOS アプリが読み取る QR コードを生成します。ngrok で公開した URL を入力し、アクセストークン入りのカスタム URI を発行します。</p>
      </div>
    </div>
    <section class="grid">
      <section class="card form-card">
        ${errorMessage ? `<div class="error">${escapeHtml(errorMessage)}</div>` : ""}
      <form method="post" action="/qr">
        <div class="field">
          <label for="ngrokUrl">ngrok の URL</label>
          <input id="ngrokUrl" name="ngrokUrl" type="text" value="${escapeHtml(ngrokUrl)}" placeholder="https://xxxx.ngrok-free.app" autocomplete="off">
          <div class="hint">手入力。末尾に <code>/reports</code> は不要です。</div>
        </div>
        <div class="field">
          <label for="token">アクセストークン</label>
          <input id="token" type="text" value="${escapeHtml(reportToken)}" readonly>
          <div class="hint">サーバー起動中は固定です。必要なら環境変数 <code>REPORT_SERVER_TOKEN</code> で上書きできます。</div>
        </div>
        <button type="submit">QRコード作成</button>
      </form>
      </section>
      ${qrDataUrl ? `
        <section class="card">
          <div class="result">
            <div>
              <label>生成された QR コード</label>
              <div class="qr-box"><img src="${qrDataUrl}" alt="改善レポート送信用 QR コード" width="320" height="320"></div>
            </div>
            <div>
              <label>カスタム URI</label>
              <div class="payload">${escapeHtml(qrPayload ?? "")}</div>
            </div>
            <div class="result-link"><a href="/reports">レポート一覧へ</a></div>
          </div>
        </section>
      ` : ""}
    </section>
  </main>
</body>
</html>`;
}

function renderReportsIndexPage(reports) {
  return `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CamScanShare 改善レポート一覧</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f7fb;
      --card: #ffffff;
      --line: #d9e1ec;
      --text: #17212c;
      --muted: #526173;
      --primary: #1769e0;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    .wrap {
      max-width: 1080px;
      margin: 0 auto;
      padding: 32px 20px 48px;
    }
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 24px;
    }
    .header-links {
      display: flex;
      gap: 12px;
      flex-wrap: wrap;
    }
    .link-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 42px;
      padding: 0 16px;
      border-radius: 12px;
      border: 1px solid var(--line);
      background: white;
      color: var(--text);
      text-decoration: none;
      font-weight: 600;
    }
    h1 {
      margin: 0 0 6px;
      font-size: 28px;
    }
    .lead {
      margin: 0;
      color: var(--muted);
      line-height: 1.6;
    }
    .grid {
      display: grid;
      gap: 16px;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 18px 20px;
      box-shadow: 0 12px 28px rgba(19, 36, 64, 0.05);
    }
    .card-top {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 12px;
      flex-wrap: wrap;
    }
    .report-id {
      font-size: 18px;
      font-weight: 700;
    }
    .meta {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 10px 16px;
      margin-bottom: 12px;
    }
    .meta-item {
      font-size: 14px;
      line-height: 1.5;
    }
    .meta-label {
      display: block;
      font-size: 12px;
      color: var(--muted);
      margin-bottom: 2px;
    }
    .comment {
      padding: 12px 14px;
      border-radius: 14px;
      background: #f7f9fc;
      border: 1px solid var(--line);
      font-size: 14px;
      line-height: 1.6;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .empty {
      padding: 28px;
      text-align: center;
      color: var(--muted);
    }
  </style>
</head>
<body>
  <main class="wrap">
    <div class="header">
      <div>
        <h1>改善レポート一覧</h1>
        <p class="lead">POST /reports で受信したレポートを新しい順に表示します。各カードから詳細へ移動できます。</p>
      </div>
      <div class="header-links">
        <a class="link-btn" href="/qr">QR 発行画面</a>
      </div>
    </div>
    <section class="grid">
      ${reports.length === 0 ? `
        <div class="card empty">まだレポートはありません。</div>
      ` : reports.map((report) => `
        <article class="card">
          <div class="card-top">
            <a class="report-id" href="/reports/${encodeURIComponent(report.reportId)}">${escapeHtml(report.reportId)}</a>
            <div>${escapeHtml(report.fileCount)} files</div>
          </div>
          <div class="meta">
            ${renderMetaItem("日時 (JST)", report.summary.timestampJst ?? "-")}
            ${renderMetaItem("アプリ版", report.summary.appVersion ?? "-")}
            ${renderMetaItem("ビルド番号", report.summary.buildNumber ?? "-")}
            ${renderMetaItem("ページID", report.summary.pageId ?? "-")}
            ${renderMetaItem("現在フィルタ", report.summary.currentFilter ?? "-")}
          </div>
          <div class="comment">${escapeHtml(report.summary.comment ?? "(comment not found)")}</div>
        </article>
      `).join("")}
    </section>
  </main>
</body>
</html>`;
}

function renderReportDetailPage(detail) {
  const imageFiles = detail.files.filter((file) => file.isImage);
  const otherFiles = detail.files.filter((file) => !file.isImage && !file.isSummary);
  return `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(detail.reportId)} | CamScanShare 改善レポート</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f7fb;
      --card: #ffffff;
      --line: #d9e1ec;
      --text: #17212c;
      --muted: #526173;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    .wrap {
      max-width: 1180px;
      margin: 0 auto;
      padding: 32px 20px 48px;
    }
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      flex-wrap: wrap;
      margin-bottom: 24px;
    }
    h1 {
      margin: 0 0 6px;
      font-size: 28px;
    }
    .lead {
      margin: 0;
      color: var(--muted);
      line-height: 1.6;
    }
    .link-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 42px;
      padding: 0 16px;
      border-radius: 12px;
      border: 1px solid var(--line);
      background: white;
      color: var(--text);
      text-decoration: none;
      font-weight: 600;
    }
    .stack {
      display: grid;
      gap: 16px;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 20px;
      box-shadow: 0 12px 28px rgba(19, 36, 64, 0.05);
    }
    .meta {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 12px 16px;
      margin-bottom: 16px;
    }
    .meta-item {
      font-size: 14px;
      line-height: 1.5;
    }
    .meta-label {
      display: block;
      font-size: 12px;
      color: var(--muted);
      margin-bottom: 2px;
    }
    .comment {
      padding: 14px 16px;
      border-radius: 14px;
      background: #f7f9fc;
      border: 1px solid var(--line);
      line-height: 1.7;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .gallery {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 16px;
    }
    .image-card {
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 14px;
      background: #fcfdff;
    }
    .image-card img {
      width: 100%;
      height: auto;
      display: block;
      border-radius: 12px;
      background: white;
      border: 1px solid var(--line);
    }
    .image-title {
      margin: 0 0 10px;
      font-size: 14px;
      font-weight: 700;
      word-break: break-all;
    }
    .file-list {
      margin: 0;
      padding-left: 18px;
      line-height: 1.8;
    }
    .file-list a {
      color: inherit;
    }
  </style>
</head>
<body>
  <main class="wrap">
    <div class="header">
      <div>
        <h1>${escapeHtml(detail.reportId)}</h1>
        <p class="lead">summary.txt の内容と、展開された画像ファイルを確認できます。</p>
      </div>
      <a class="link-btn" href="/reports">レポート一覧へ戻る</a>
    </div>
    <section class="stack">
      <article class="card">
        <div class="meta">
          ${renderMetaItem("日時 (JST)", detail.summary.timestampJst ?? "-")}
          ${renderMetaItem("アプリ版", detail.summary.appVersion ?? "-")}
          ${renderMetaItem("ビルド番号", detail.summary.buildNumber ?? "-")}
          ${renderMetaItem("ページID", detail.summary.pageId ?? "-")}
          ${renderMetaItem("現在フィルタ", detail.summary.currentFilter ?? "-")}
        </div>
        <div class="comment">${escapeHtml(detail.summary.comment ?? "(comment not found)")}</div>
      </article>
      <article class="card">
        <h2>画像</h2>
        <div class="gallery">
          ${imageFiles.map((file) => `
            <section class="image-card">
              <div class="image-title">${escapeHtml(file.fileName)}</div>
              <a href="${file.url}" target="_blank" rel="noopener">
                <img src="${file.url}" alt="${escapeHtml(file.fileName)}">
              </a>
            </section>
          `).join("") || `<div>画像ファイルはありません。</div>`}
        </div>
      </article>
      <article class="card">
        <h2>その他のファイル</h2>
        <ul class="file-list">
          ${otherFiles.map((file) => `<li><a href="${file.url}" target="_blank" rel="noopener">${escapeHtml(file.fileName)}</a></li>`).join("") || `<li>なし</li>`}
        </ul>
      </article>
    </section>
  </main>
</body>
</html>`;
}

function renderSimpleMessagePage(message, href, linkLabel) {
  return `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CamScanShare report server</title>
  <style>
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: #f5f7fb;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    .card {
      padding: 24px;
      border-radius: 20px;
      background: white;
      border: 1px solid #d9e1ec;
      max-width: 420px;
      text-align: center;
    }
    a {
      color: #1769e0;
      text-decoration: none;
      font-weight: 700;
    }
  </style>
</head>
<body>
  <div class="card">
    <p>${escapeHtml(message)}</p>
    <a href="${href}">${escapeHtml(linkLabel)}</a>
  </div>
</body>
</html>`;
}

function renderMetaItem(label, value) {
  return `
    <div class="meta-item">
      <span class="meta-label">${escapeHtml(label)}</span>
      <span>${escapeHtml(value)}</span>
    </div>
  `;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
