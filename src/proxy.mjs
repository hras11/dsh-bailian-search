#!/usr/bin/env node
/**
 * anthropic-search-proxy — injects the Aliyun Bailian billing header that
 * enables Anthropic server-side `web_search` on DSH's web-search requests.
 *
 * Why this exists: Aliyun's Anthropic-compatible gateway silently ignores the
 * `web_search_20250305` server tool unless the request carries
 *   x-anthropic-billing-header: cc_entrypoint=cli;
 * inside the `system` field. DSH's @deepseek-ai/dsh-web-search-deepseek never
 * sends a `system` field, so search returned HTTP 200 with no results. This
 * proxy adds that field and forwards everything else untouched.
 *
 * The gateway address is intentionally hardcoded (it is stable), and the
 * listener binds to loopback only. Credentials are passed through verbatim and
 * are never logged or persisted.
 *
 * Run:  node anthropic-search-proxy.mjs
 */

import http from "node:http";

/**
 * Aliyun Bailian workspace gateway, Anthropic-compatible Messages base.
 * Always supplied by install.sh via the unit's Environment= (it reads the
 * gateway out of your DSH config), so no workspace ID is baked into the repo.
 * A placeholder default keeps direct `node src/proxy.mjs` runs from crashing
 * with a confusing error.
 */
const UPSTREAM_BASE = (process.env.UPSTREAM_BASE_URL ?? "https://REPLACE-WITH-YOUR-WORKSPACE.cn-beijing.maas.aliyuncs.com/apps/anthropic/v1").replace(/\/+$/, "");

const LISTEN_HOST = "127.0.0.1";
const LISTEN_PORT = Number.parseInt(process.env.PROXY_PORT ?? "8787", 10);

/** The marker Aliyun requires; without it the server tool is dropped. */
const BILLING_HEADER = { type: "text", text: "x-anthropic-billing-header: cc_entrypoint=cli;" };

/**
 * Merge the billing marker into a Messages request body.
 * An existing `system` value is preserved: a string becomes a text block, and
 * an existing block array is prepended to rather than replaced.
 * @param {unknown} body - the parsed request body
 * @returns {{body: unknown, changed: boolean}} the body to forward, and whether the marker was added
 */
function withBillingHeader(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return { body, changed: false };
  if (!("tools" in body)) return { body, changed: false };

  const existing = body.system;
  let system;
  if (existing === undefined || existing === null) {
    system = [BILLING_HEADER];
  } else if (typeof existing === "string") {
    system = [BILLING_HEADER, { type: "text", text: existing }];
  } else if (Array.isArray(existing)) {
    const already = existing.some((b) => b && typeof b === "object" && typeof b.text === "string" && b.text.includes("x-anthropic-billing-header"));
    if (already) return { body, changed: false };
    system = [BILLING_HEADER, ...existing];
  } else {
    return { body, changed: false };
  }
  return { body: { ...body, system }, changed: true };
}

/**
 * Collect a request stream into a Buffer.
 * @param {import("node:http").IncomingMessage} req
 * @returns {Promise<Buffer>}
 */
function readBody(req) {
  return new Promise((resolve, reject) => {
    /** @type {Buffer[]} */
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

/**
 * Forward one request to the upstream Messages endpoint.
 * @param {import("node:http").IncomingMessage} req
 * @param {import("node:http").ServerResponse} res
 * @param {string} path - request path, e.g. "/v1/messages"
 */
async function handle(req, res, path) {
  const raw = await readBody(req);

  // Forward auth and protocol headers; recompute length because we may edit the body.
  const headers = {};
  for (const [key, value] of Object.entries(req.headers)) {
    const k = key.toLowerCase();
    if (k === "host" || k === "content-length" || k === "connection") continue;
    if (typeof value === "string") headers[k] = value;
  }

  let outBody = raw;
  let injected = false;

  if (raw.length > 0 && (req.headers["content-type"] ?? "").includes("application/json")) {
    try {
      const parsed = JSON.parse(raw.toString("utf8"));
      const { body, changed } = withBillingHeader(parsed);
      injected = changed;
      if (changed) outBody = Buffer.from(JSON.stringify(body), "utf8");
    } catch {
      // Not JSON we can parse: forward it unchanged rather than break the call.
    }
  }
  headers["content-length"] = String(outBody.length);

  const target = `${UPSTREAM_BASE}${path.replace(/^\/v1/, "")}`;
  const searchTool = injected ? "injected" : "passthrough";
  console.log(`[proxy] ${req.method} ${path} -> ${target} (${searchTool}, ${outBody.length}B)`);

  let upstream;
  try {
    upstream = await fetch(target, {
      method: req.method,
      headers,
      body: req.method === "GET" || req.method === "HEAD" ? undefined : outBody,
    });
  } catch (error) {
    console.error(`[proxy] upstream fetch failed: ${String(error)}`);
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { type: "proxy_error", message: `Upstream unreachable: ${String(error)}` } }));
    return;
  }

  const buf = Buffer.from(await upstream.arrayBuffer());

  // Pass through only protocol-relevant headers; the plugin reads status + body.
  const outHeaders = {};
  for (const name of ["content-type", "request-id", "anthropic-version"]) {
    const v = upstream.headers.get(name);
    if (v !== null) outHeaders[name] = v;
  }

  let note = "";
  if (upstream.ok) {
    try {
      const d = JSON.parse(buf.toString("utf8"));
      const blocks = Array.isArray(d?.content) ? d.content : [];
      const searches = d?.usage?.server_tool_use?.web_search_requests;
      const hasResult = blocks.some((b) => b?.type === "web_search_tool_result");
      note = hasResult ? `search=OK reqs=${searches ?? "?"}` : "WARN no web_search_tool_result";
    } catch {
      note = "unparseable body";
    }
  }
  console.log(`[proxy] <- HTTP ${upstream.status} ${note}`);

  res.writeHead(upstream.status, outHeaders);
  res.end(buf);
}

const server = http.createServer((req, res) => {
  const path = (req.url ?? "/").split("?")[0];
  if (path === "/healthz") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, upstream: UPSTREAM_BASE }));
    return;
  }
  handle(req, res, path).catch((error) => {
    console.error(`[proxy] handler error: ${String(error)}`);
    if (!res.headersSent) res.writeHead(500, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { type: "proxy_error", message: String(error) } }));
  });
});

// Fail loudly on a placeholder upstream: otherwise every search would fail with
// an opaque DNS error instead of telling the operator what to fix.
if (UPSTREAM_BASE.includes("REPLACE-WITH-YOUR-WORKSPACE")) {
  console.error("[proxy] UPSTREAM_BASE_URL is not set to a real gateway.");
  console.error("[proxy] Install with ./install.sh (it reads your DSH config), or run:");
  console.error("[proxy]   UPSTREAM_BASE_URL=https://<WorkspaceId>.<region>.maas.aliyuncs.com/apps/anthropic/v1 node src/proxy.mjs");
  process.exit(1);
}
if (!URL.canParse(UPSTREAM_BASE)) {
  console.error(`[proxy] UPSTREAM_BASE_URL is not a valid URL: ${UPSTREAM_BASE}`);
  process.exit(1);
}

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`[proxy] listening on http://${LISTEN_HOST}:${LISTEN_PORT}`);
  console.log(`[proxy] upstream ${UPSTREAM_BASE}`);
  console.log(`[proxy] injecting: ${BILLING_HEADER.text.trim()}`);
});