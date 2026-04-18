import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createServer } from "node:http";
import express from "express";
import multer from "multer";
import QRCode from "qrcode";
import AdmZip from "adm-zip";
import { Server as SocketIOServer } from "socket.io";
import chokidar from "chokidar";

// ── Config ──

const app = express();
const httpServer = createServer(app);
const io = new SocketIOServer(httpServer);

app.set("trust proxy", true);

const port = Number.parseInt(process.env.PORT ?? "3030", 10);
const reportToken = process.env.REPORT_SERVER_TOKEN ?? crypto.randomBytes(24).toString("hex");
const reportsDir = path.resolve("reports");
const iosIpaPath = path.resolve("..", "iosapp", "build", "adhoc", "export", "CamScanShare.ipa");
const iosArchiveInfoPath = path.resolve("..", "iosapp", "build", "adhoc", "CamScanShare.xcarchive", "Info.plist");
const androidApkPath = path.resolve("..", "androidapp", "app", "build", "outputs", "apk", "debug", "app-debug.apk");

fs.mkdirSync(reportsDir, { recursive: true });

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 100 * 1024 * 1024 },
});

app.use(express.urlencoded({ extended: false }));

// ── Page Routes ──

app.get("/", (_req, res) => res.redirect("/reports"));

app.get("/reports", (req, res) => {
  res.set("Cache-Control", "no-store");
  const reports = loadReportIndex();
  const defaultUrl = inferDefaultPublicBaseUrl(req);
  res.send(renderMainPage(reports, defaultUrl));
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

app.get("/reports/:reportId", (req, res) => {
  const detail = loadReportDetail(req.params.reportId);
  if (!detail) {
    res.status(404).send(renderSimpleMessagePage("レポートが見つかりませんでした。", "/reports", "レポート一覧へ戻る"));
    return;
  }

  res.send(renderReportDetailPage(detail));
});

// ── App Download Routes ──

app.get("/app", async (req, res) => {
  res.set("Cache-Control", "no-store");
  const host = resolveAppHost(req);
  if (!host) {
    res.send(renderAppHostInputPage());
    return;
  }

  const baseUrl = `https://${host}`;
  const manifestUrl = `${baseUrl}/app/ios/manifest.plist`;
  const iosInstallUrl = `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestUrl)}`;
  const androidInstallUrl = `${baseUrl}/app/android/app.apk`;

  const [iosQr, androidQr] = await Promise.all([
    QRCode.toDataURL(iosInstallUrl, { errorCorrectionLevel: "M", margin: 2, width: 320 }),
    QRCode.toDataURL(androidInstallUrl, { errorCorrectionLevel: "M", margin: 2, width: 320 }),
  ]);

  const iosAvailable = fs.existsSync(iosIpaPath);
  const androidAvailable = fs.existsSync(androidApkPath);

  res.send(renderAppDownloadPage({
    host, iosInstallUrl, androidInstallUrl, iosQr, androidQr, iosAvailable, androidAvailable,
  }));
});

app.get("/app/ios/manifest.plist", (req, res) => {
  const host = resolveAppHost(req);
  if (!host) {
    res.status(400).send("host required");
    return;
  }
  const ipaUrl = `https://${host}/app/ios/app.ipa`;
  const info = loadIosAppInfo();
  res.set("Content-Type", "application/xml; charset=utf-8");
  res.send(renderIosManifestPlist({ ipaUrl, ...info }));
});

app.get("/app/ios/app.ipa", (_req, res) => {
  if (!fs.existsSync(iosIpaPath)) {
    res.status(404).send("ipa not found. Build the iOS ad-hoc archive first.");
    return;
  }
  res.set("Content-Type", "application/octet-stream");
  res.sendFile(iosIpaPath);
});

app.get("/app/android/app.apk", (_req, res) => {
  if (!fs.existsSync(androidApkPath)) {
    res.status(404).send("apk not found. Run `./gradlew assembleDebug` first.");
    return;
  }
  res.set("Content-Type", "application/vnd.android.package-archive");
  res.sendFile(androidApkPath);
});

// ── API Routes ──

app.get("/api/reports", (_req, res) => {
  res.json(loadReportIndex());
});

app.post("/api/qr", express.json(), async (req, res) => {
  const ngrokUrl = (req.body?.ngrokUrl ?? "").trim();
  if (!ngrokUrl) {
    res.status(400).json({ error: "ngrok の URL を入力してください。" });
    return;
  }

  let reportEndpoint;
  try {
    const normalizedUrl = normalizePublicBaseUrl(ngrokUrl);
    reportEndpoint = `${normalizedUrl}/reports`;
  } catch (error) {
    res.status(400).json({
      error: error instanceof Error ? error.message : "ngrok URL の形式が不正です。",
    });
    return;
  }

  const qrPayload = buildQrPayload(reportEndpoint, reportToken);
  const qrDataUrl = await QRCode.toDataURL(qrPayload, {
    errorCorrectionLevel: "M",
    margin: 2,
    width: 320,
  });

  res.json({ qrDataUrl, qrPayload });
});

// ── Upload Route ──

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

// ── Filesystem Watcher ──

const watcher = chokidar.watch(reportsDir, {
  ignoreInitial: true,
  depth: 1,
});

let debounceTimer = null;
function notifyReportsChanged() {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    io.emit("reports:update", loadReportIndex());
  }, 500);
}

watcher.on("addDir", notifyReportsChanged);
watcher.on("unlinkDir", notifyReportsChanged);
watcher.on("add", notifyReportsChanged);
watcher.on("unlink", notifyReportsChanged);

// ── Start ──

httpServer.listen(port, () => {
  console.log(`CamScanShare report server listening on http://localhost:${port}`);
  console.log(`Access token: ${reportToken}`);
});

// ── Auth / URL Helpers ──

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

function isLocalhostHost(host) {
  if (!host) return true;
  const hostname = host.replace(/:\d+$/, "").replace(/^\[(.*)\]$/, "$1").toLowerCase();
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
}

function normalizeInputHost(value) {
  const trimmed = String(value ?? "").trim();
  if (!trimmed) return "";
  if (/^https?:\/\//i.test(trimmed)) {
    try {
      return new URL(trimmed).host;
    } catch {
      return "";
    }
  }
  return trimmed.replace(/\/.*$/, "");
}

function resolveAppHost(req) {
  const hostParam = normalizeInputHost(req.query.host);
  if (hostParam && !isLocalhostHost(hostParam)) return hostParam;
  const reqHost = (req.get("host") ?? "").trim();
  if (!isLocalhostHost(reqHost)) return reqHost;
  return "";
}

function loadIosAppInfo() {
  const defaults = {
    bundleIdentifier: "io.github.yusukeiwaki.camscanshare",
    bundleVersion: "1.0.0",
    title: "CamScanShare",
  };
  if (!fs.existsSync(iosArchiveInfoPath)) return defaults;
  try {
    const xml = fs.readFileSync(iosArchiveInfoPath, "utf8");
    const get = (key) => {
      const m = new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`).exec(xml);
      return m ? m[1] : null;
    };
    return {
      bundleIdentifier: get("CFBundleIdentifier") || defaults.bundleIdentifier,
      bundleVersion: get("CFBundleShortVersionString") || defaults.bundleVersion,
      title: defaults.title,
    };
  } catch {
    return defaults;
  }
}

function renderIosManifestPlist({ ipaUrl, bundleIdentifier, bundleVersion, title }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>assets</key>
            <array>
                <dict>
                    <key>kind</key>
                    <string>software-package</string>
                    <key>url</key>
                    <string>${escapeXml(ipaUrl)}</string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key>
                <string>${escapeXml(bundleIdentifier)}</string>
                <key>bundle-version</key>
                <string>${escapeXml(bundleVersion)}</string>
                <key>kind</key>
                <string>software</string>
                <key>title</key>
                <string>${escapeXml(title)}</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>`;
}

function escapeXml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("'", "&apos;")
    .replaceAll('"', "&quot;");
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

// ── Report Directory Helpers ──

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

// ── HTML Helpers ──

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function safeJsonEmbed(data) {
  return JSON.stringify(data).replace(/</g, "\\u003c").replace(/>/g, "\\u003e");
}

function renderMetaItem(label, value) {
  return `
    <div class="meta-item">
      <span class="meta-label">${escapeHtml(label)}</span>
      <span>${escapeHtml(value)}</span>
    </div>
  `;
}

// ── Main Page ──

function renderMainPage(reports, defaultUrl) {
  return `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CamScanShare 改善レポート</title>
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
      flex-wrap: wrap;
    }
    h1 { margin: 0 0 6px; font-size: 28px; }
    .lead { margin: 0; color: var(--muted); line-height: 1.6; }
    .grid { display: grid; gap: 16px; }
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
    .report-id { font-size: 18px; font-weight: 700; color: var(--primary); text-decoration: none; }
    .report-id:hover { text-decoration: underline; }
    .meta {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 10px 16px;
      margin-bottom: 12px;
    }
    .meta-item { font-size: 14px; line-height: 1.5; }
    .meta-label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 2px; }
    .comment {
      padding: 12px 14px;
      border-radius: 14px;
      background: #f7f9fc;
      border: 1px solid var(--line);
      font-size: 24px;
      line-height: 1.6;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .empty { padding: 28px; text-align: center; color: var(--muted); }

    /* Buttons */
    .primary-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 42px;
      padding: 0 20px;
      border: none;
      border-radius: 12px;
      background: var(--primary);
      color: white;
      font-size: 14px;
      font-weight: 700;
      cursor: pointer;
      white-space: nowrap;
    }
    .primary-btn:hover { background: #1258c0; }
    .primary-btn:disabled { opacity: 0.6; cursor: default; }
    .secondary-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 42px;
      padding: 0 20px;
      border: 1px solid var(--line);
      border-radius: 12px;
      background: white;
      color: var(--text);
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      white-space: nowrap;
    }
    .secondary-btn:hover { background: #f7f9fc; }
    .full-width { width: 100%; }

    /* Dialog */
    dialog {
      border: none;
      border-radius: 20px;
      padding: 0;
      max-width: 560px;
      width: calc(100% - 40px);
      box-shadow: 0 24px 48px rgba(0, 0, 0, 0.18);
      overflow: hidden;
    }
    dialog::backdrop {
      background: rgba(0, 0, 0, 0.4);
      backdrop-filter: blur(4px);
    }
    dialog[open] {
      animation: dialog-show 0.2s ease-out;
    }
    @keyframes dialog-show {
      from { opacity: 0; transform: scale(0.96); }
      to { opacity: 1; transform: scale(1); }
    }
    .dialog-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 20px 24px;
      border-bottom: 1px solid var(--line);
    }
    .dialog-header h2 { margin: 0; font-size: 18px; }
    .close-btn {
      width: 36px;
      height: 36px;
      border: none;
      background: none;
      font-size: 24px;
      color: var(--muted);
      cursor: pointer;
      border-radius: 8px;
      display: flex;
      align-items: center;
      justify-content: center;
      line-height: 1;
    }
    .close-btn:hover { background: #f0f3f7; }
    .dialog-body { padding: 24px; }
    .dialog-lead { margin: 0 0 20px; font-size: 14px; color: var(--muted); line-height: 1.6; }
    .field { margin-bottom: 20px; }
    .field:last-child { margin-bottom: 0; }
    label { display: block; margin-bottom: 8px; font-size: 14px; font-weight: 700; }
    input[type="text"] {
      width: 100%;
      height: 48px;
      padding: 0 14px;
      border: 1px solid var(--line);
      border-radius: 14px;
      font-size: 15px;
      background: white;
      color: var(--text);
    }
    input[readonly] { background: #eef3fb; color: #35465a; }
    .hint { margin-top: 6px; font-size: 13px; color: var(--muted); line-height: 1.5; }
    .error {
      margin-bottom: 20px;
      padding: 14px 16px;
      border-radius: 14px;
      background: var(--danger-bg);
      color: var(--danger-text);
      font-size: 14px;
      line-height: 1.5;
    }
    .qr-center { display: flex; justify-content: center; margin-bottom: 20px; }
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
    .btn-row { margin-top: 20px; }
  </style>
</head>
<body>
  <main class="wrap">
    <div class="header">
      <div>
        <h1>改善レポート</h1>
        <p class="lead">受信した改善レポートを表示します。</p>
      </div>
      <button id="qr-btn" class="primary-btn">QR</button>
    </div>
    <section id="report-list" class="grid"></section>
  </main>

  <dialog id="qr-dialog">
    <div class="dialog-header">
      <h2>QR コード作成</h2>
      <button id="qr-close" class="close-btn" aria-label="閉じる">&times;</button>
    </div>
    <div id="qr-form-view" class="dialog-body">
      <p class="dialog-lead">ngrok で公開した URL を入力し、アクセストークン入りの QR コードを作成します。</p>
      <div id="qr-error" class="error" style="display:none"></div>
      <form id="qr-form">
        <div class="field">
          <label for="qr-url">ngrok の URL</label>
          <input id="qr-url" type="text" placeholder="https://xxxx.ngrok-free.app" autocomplete="off">
          <div class="hint">末尾に <code>/reports</code> は不要です。</div>
        </div>
        <div class="field">
          <label>アクセストークン</label>
          <input id="qr-token" type="text" readonly>
          <div class="hint">サーバー起動中は固定。環境変数 <code>REPORT_SERVER_TOKEN</code> で上書き可能。</div>
        </div>
        <button id="qr-submit" type="submit" class="primary-btn full-width">QR コード作成</button>
      </form>
    </div>
    <div id="qr-result-view" class="dialog-body" style="display:none">
      <div class="qr-center">
        <div class="qr-box"><img id="qr-img" src="" alt="QR コード" width="320" height="320"></div>
      </div>
      <div class="field">
        <label>カスタム URI</label>
        <div class="payload" id="qr-payload"></div>
      </div>
      <div class="btn-row">
        <button id="qr-back" class="secondary-btn full-width">別の URL で作成</button>
      </div>
    </div>
  </dialog>

  <script src="/socket.io/socket.io.js"></script>
  <script>
  (function() {
    var REPORTS = ${safeJsonEmbed(reports)};
    var DEFAULT_URL = ${safeJsonEmbed(defaultUrl)};
    var TOKEN = ${safeJsonEmbed(reportToken)};

    // ── Helpers ──

    function esc(s) {
      return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    function metaHtml(label, value) {
      return '<div class="meta-item"><span class="meta-label">' + esc(label) + '</span><span>' + esc(value) + '</span></div>';
    }

    function reportCardHtml(r) {
      var s = r.summary || {};
      return '<article class="card">' +
        '<div class="card-top">' +
        '<a class="report-id" href="/reports/' + encodeURIComponent(r.reportId) + '">' + esc(r.reportId) + '</a>' +
        '<div>' + esc(String(r.fileCount)) + ' files</div>' +
        '</div>' +
        '<div class="meta">' +
        metaHtml('日時 (JST)', s.timestampJst || '-') +
        metaHtml('アプリ版', s.appVersion || '-') +
        metaHtml('ビルド番号', s.buildNumber || '-') +
        metaHtml('ページID', s.pageId || '-') +
        metaHtml('現在フィルタ', s.currentFilter || '-') +
        '</div>' +
        '<div class="comment">' + esc(s.comment || '(comment not found)') + '</div>' +
        '</article>';
    }

    // ── Report List ──

    var listEl = document.getElementById('report-list');

    function renderReportList(reports) {
      if (reports.length === 0) {
        listEl.innerHTML = '<div class="card empty">まだレポートはありません。</div>';
        return;
      }
      listEl.innerHTML = reports.map(reportCardHtml).join('');
    }

    renderReportList(REPORTS);

    // ── Socket.IO ──

    var socket = io();
    var wasConnected = false;

    socket.on('connect', function() {
      if (wasConnected) {
        fetch('/api/reports')
          .then(function(r) { return r.json(); })
          .then(renderReportList)
          .catch(function() {});
      }
      wasConnected = true;
    });

    socket.on('reports:update', renderReportList);

    // ブラウザバック時に最新データを取得（bfcache・HTTPキャッシュ両対応）
    window.addEventListener('pageshow', function(e) {
      if (!e.persisted) return;
      fetch('/api/reports')
        .then(function(r) { return r.json(); })
        .then(renderReportList)
        .catch(function() {});
      if (socket.disconnected) socket.connect();
    });
    window.addEventListener('visibilitychange', function() {
      if (document.visibilityState !== 'visible') return;
      fetch('/api/reports')
        .then(function(r) { return r.json(); })
        .then(renderReportList)
        .catch(function() {});
      if (socket.disconnected) socket.connect();
    });

    // ── QR Modal ──

    var dialog = document.getElementById('qr-dialog');
    var formView = document.getElementById('qr-form-view');
    var resultView = document.getElementById('qr-result-view');
    var errorEl = document.getElementById('qr-error');
    var urlInput = document.getElementById('qr-url');
    var submitBtn = document.getElementById('qr-submit');

    document.getElementById('qr-token').value = TOKEN;
    if (DEFAULT_URL) urlInput.value = DEFAULT_URL;

    function submitQrForm() {
      errorEl.style.display = 'none';
      submitBtn.disabled = true;
      submitBtn.textContent = '生成中...';

      fetch('/api/qr', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ngrokUrl: urlInput.value.trim() })
      })
      .then(function(res) {
        return res.json().then(function(data) { return { ok: res.ok, data: data }; });
      })
      .then(function(result) {
        if (!result.ok) {
          errorEl.textContent = result.data.error || 'エラーが発生しました。';
          errorEl.style.display = '';
          formView.style.display = '';
          resultView.style.display = 'none';
          return;
        }
        document.getElementById('qr-img').src = result.data.qrDataUrl;
        document.getElementById('qr-payload').textContent = result.data.qrPayload;
        formView.style.display = 'none';
        resultView.style.display = '';
      })
      .catch(function() {
        errorEl.textContent = '通信エラーが発生しました。';
        errorEl.style.display = '';
        formView.style.display = '';
        resultView.style.display = 'none';
      })
      .finally(function() {
        submitBtn.disabled = false;
        submitBtn.textContent = 'QR コード作成';
      });
    }

    document.getElementById('qr-btn').addEventListener('click', function() {
      formView.style.display = '';
      resultView.style.display = 'none';
      errorEl.style.display = 'none';
      dialog.showModal();
      if (DEFAULT_URL) {
        submitQrForm();
      }
    });

    document.getElementById('qr-close').addEventListener('click', function() {
      dialog.close();
    });

    dialog.addEventListener('click', function(e) {
      if (e.target === dialog) dialog.close();
    });

    document.getElementById('qr-form').addEventListener('submit', function(e) {
      e.preventDefault();
      submitQrForm();
    });

    document.getElementById('qr-back').addEventListener('click', function() {
      formView.style.display = '';
      resultView.style.display = 'none';
      errorEl.style.display = 'none';
    });
  })();
  </script>
</body>
</html>`;
}

// ── Report Detail Page ──

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
    h1 { margin: 0 0 6px; font-size: 28px; }
    .lead { margin: 0; color: var(--muted); line-height: 1.6; }
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
    .stack { display: grid; gap: 16px; }
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
    .meta-item { font-size: 14px; line-height: 1.5; }
    .meta-label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 2px; }
    .comment {
      padding: 14px 16px;
      border-radius: 14px;
      background: #f7f9fc;
      border: 1px solid var(--line);
      font-size: 32px;
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
    .file-list { margin: 0; padding-left: 18px; line-height: 1.8; }
    .file-list a { color: inherit; }
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

// ── App Download Pages ──

function renderAppHostInputPage() {
  return `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CamScanShare アプリダウンロード</title>
  <style>
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: #f5f7fb;
      color: #17212c;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    .card {
      background: white;
      border: 1px solid #d9e1ec;
      border-radius: 20px;
      padding: 28px;
      width: calc(100% - 40px);
      max-width: 480px;
      box-shadow: 0 12px 28px rgba(19, 36, 64, 0.05);
    }
    h1 { margin: 0 0 8px; font-size: 22px; }
    p { margin: 0 0 20px; color: #526173; line-height: 1.6; font-size: 14px; }
    label { display: block; margin-bottom: 8px; font-size: 14px; font-weight: 700; }
    input[type="text"] {
      width: 100%;
      height: 48px;
      padding: 0 14px;
      border: 1px solid #d9e1ec;
      border-radius: 14px;
      font-size: 15px;
      background: white;
      color: #17212c;
    }
    .hint { margin: 6px 0 20px; font-size: 13px; color: #526173; line-height: 1.5; }
    button {
      width: 100%;
      height: 48px;
      border: none;
      border-radius: 14px;
      background: #1769e0;
      color: white;
      font-size: 15px;
      font-weight: 700;
      cursor: pointer;
    }
    button:hover { background: #1258c0; }
  </style>
</head>
<body>
  <div class="card">
    <h1>CamScanShare アプリダウンロード</h1>
    <p>ngrok などで公開したホスト名を入力してください。入力先を使用してインストール用 QR コードを表示します。</p>
    <form method="get" action="/app">
      <label for="host-input">ホスト名</label>
      <input id="host-input" name="host" type="text" placeholder="xxxx.ngrok-free.app" autocomplete="off" required>
      <div class="hint">スキーム (https://) や末尾のパスは自動で取り除かれます。</div>
      <button type="submit">続行</button>
    </form>
  </div>
</body>
</html>`;
}

function renderAppDownloadPage({ host, iosInstallUrl, androidInstallUrl, iosQr, androidQr, iosAvailable, androidAvailable }) {
  return `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CamScanShare アプリダウンロード</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f7fb;
      --card: #ffffff;
      --line: #d9e1ec;
      --text: #17212c;
      --muted: #526173;
      --primary: #1769e0;
      --warn-bg: #fff6e0;
      --warn-text: #7a5200;
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
      flex-wrap: wrap;
    }
    h1 { margin: 0 0 6px; font-size: 28px; }
    .lead { margin: 0; color: var(--muted); line-height: 1.6; }
    .host-pill {
      display: inline-flex;
      align-items: center;
      padding: 8px 14px;
      border-radius: 999px;
      background: #eef3fb;
      color: #35465a;
      font-family: ui-monospace, SFMono-Regular, monospace;
      font-size: 13px;
    }
    .columns {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 16px;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 24px;
      box-shadow: 0 12px 28px rgba(19, 36, 64, 0.05);
      display: flex;
      flex-direction: column;
      align-items: center;
    }
    .card h2 { margin: 0 0 8px; font-size: 20px; }
    .sub { margin: 0 0 20px; font-size: 13px; color: var(--muted); }
    .qr-box {
      padding: 12px;
      border-radius: 16px;
      background: white;
      border: 1px solid var(--line);
      margin-bottom: 16px;
    }
    .qr-box img { display: block; width: 280px; height: 280px; }
    .install-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      height: 44px;
      padding: 0 20px;
      border-radius: 12px;
      background: var(--primary);
      color: white;
      text-decoration: none;
      font-weight: 700;
      font-size: 14px;
    }
    .install-btn:hover { background: #1258c0; }
    .url {
      width: 100%;
      margin-top: 16px;
      padding: 12px 14px;
      border-radius: 12px;
      background: #f7f9fc;
      border: 1px solid var(--line);
      font-family: ui-monospace, SFMono-Regular, monospace;
      font-size: 12px;
      word-break: break-all;
      line-height: 1.6;
    }
    .notice {
      margin-top: 12px;
      padding: 10px 12px;
      border-radius: 10px;
      background: var(--warn-bg);
      color: var(--warn-text);
      font-size: 13px;
      line-height: 1.5;
      text-align: center;
    }
    .link {
      margin-top: 16px;
      font-size: 13px;
    }
    .link a { color: var(--primary); text-decoration: none; font-weight: 600; }
    .link a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <main class="wrap">
    <div class="header">
      <div>
        <h1>CamScanShare アプリダウンロード</h1>
        <p class="lead">スマートフォンで QR コードを読み取ってインストールできます。</p>
      </div>
      <span class="host-pill">${escapeHtml(host)}</span>
    </div>
    <section class="columns">
      <article class="card">
        <h2>iOS</h2>
        <p class="sub">Ad-Hoc ビルド (itms-services)</p>
        <div class="qr-box"><img src="${escapeHtml(iosQr)}" alt="iOS インストール QR"></div>
        <a class="install-btn" href="${escapeHtml(iosInstallUrl)}">iPhone で直接インストール</a>
        <div class="url">${escapeHtml(iosInstallUrl)}</div>
        ${iosAvailable ? "" : `<div class="notice">IPA ファイルが見つかりません。iOS の Ad-Hoc アーカイブをビルドしてください。</div>`}
      </article>
      <article class="card">
        <h2>Android</h2>
        <p class="sub">app-debug.apk</p>
        <div class="qr-box"><img src="${escapeHtml(androidQr)}" alt="Android インストール QR"></div>
        <a class="install-btn" href="${escapeHtml(androidInstallUrl)}">APK をダウンロード</a>
        <div class="url">${escapeHtml(androidInstallUrl)}</div>
        ${androidAvailable ? "" : `<div class="notice">APK ファイルが見つかりません。<code>./gradlew assembleDebug</code> を実行してください。</div>`}
      </article>
    </section>
    <p class="link"><a href="/app">別のホスト名で表示</a></p>
  </main>
</body>
</html>`;
}

// ── Simple Message Page ──

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
    a { color: #1769e0; text-decoration: none; font-weight: 700; }
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
