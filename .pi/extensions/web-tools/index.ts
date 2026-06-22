/**
 * Web Tools Extension
 *
 * Adds two tools analogous to Claude Code's web capabilities:
 *
 *   web_fetch  — fetch a URL and return readable text (strips HTML)
 *   web_search — search the web, preferring a stable keyed provider and
 *                falling back to keyless options
 *
 * Search providers are tried in priority order; the first one that is
 * configured is used (Serper > Brave > SearXNG > DuckDuckGo). DuckDuckGo is
 * the keyless last resort — it rate-limits datacenter IPs, so it routinely
 * fails inside a sandbox; configure one of the others for reliability.
 *
 * Configuration (optional — search falls back to DuckDuckGo with none):
 *   SERPER_API_KEY — Serper.dev API key. Google results via a fast, cheap
 *                 REST API that works from datacenter IPs. Get one at
 *                 https://serper.dev.
 *   BRAVE_SEARCH_API_KEY — Brave Search API key. An independent index, also
 *                 datacenter-friendly. Get one at https://brave.com/search/api/.
 *   SEARXNG_URL — base URL of a SearXNG instance, e.g. https://searx.example.
 *                 The instance must have the `json` format enabled
 *                 (search.formats in its settings.yml). Keyless, but you
 *                 operate the instance.
 *
 * Placement:
 *   Project-local: .pi/extensions/web-tools/index.ts   ← this file
 *   Global:        ~/.pi/agent/extensions/web-tools/index.ts
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// A browser-like User-Agent — plain/script UAs are refused by some hosts.
const BROWSER_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'",
  nbsp: " ", ensp: " ", emsp: " ",
  lsquo: "\u2018", rsquo: "\u2019", ldquo: "\u201c", rdquo: "\u201d",
  mdash: "\u2014", ndash: "\u2013",
  copy: "\u00a9", reg: "\u00ae", trade: "\u2122",
  hellip: "\u2026", middot: "\u00b7", bull: "\u2022",
  laquo: "\u00ab", raquo: "\u00bb",
  times: "\u00d7", divide: "\u00f7", plusmn: "\u00b1", deg: "\u00b0",
  euro: "\u20ac", pound: "\u00a3", yen: "\u00a5",
  larr: "\u2190", rarr: "\u2192", uarr: "\u2191", darr: "\u2193",
  frac12: "\u00bd", frac14: "\u00bc", frac34: "\u00be",
};

function codePointToString(cp: number): string {
  // Skip control chars (except tab, newline, CR) and invalid code points.
  if (!Number.isFinite(cp) || cp < 0x09 || (cp > 0x0d && cp < 0x20) || cp > 0x10ffff) return "";
  return String.fromCodePoint(cp);
}

function decodeEntities(text: string): string {
  return text
    .replace(/&#x([0-9a-fA-F]+);/g, (_m, hex) => codePointToString(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_m, dec) => codePointToString(parseInt(dec, 10)))
    .replace(/&([a-zA-Z][a-zA-Z0-9]*);/g, (m, name: string) =>
      Object.prototype.hasOwnProperty.call(NAMED_ENTITIES, name) ? NAMED_ENTITIES[name] : m);
}

// Extract likely main content before conversion — a cheap heuristic, not a
// real DOM. This whole file is a zero-dependency converter because pi
// extensions are single-file with no bundler; the upgrade path is
// Readability + Turndown if pi ever bundles a DOM (see PR #93 discussion).
function extractMainContent(html: string): string {
  const main = html.match(/<main\b[^>]*>([\s\S]*)<\/main>/i);
  if (main && main[1].trim()) return main[1];

  const article = html.match(/<article\b[^>]*>([\s\S]*)<\/article>/i);
  if (article && article[1].trim()) return article[1];

  const roleMain = html.match(
    /<([a-zA-Z][\w-]*)\b[^>]*\brole=["']main["'][^>]*>([\s\S]*)<\/\1>/i,
  );
  if (roleMain && roleMain[2].trim()) return roleMain[2];

  const body = html.match(/<body\b[^>]*>([\s\S]*)<\/body>/i);
  if (body && body[1].trim()) return body[1];

  return html;
}

// HTML → plain text
//
// Entities are decoded *after* tag-stripping so a decoded '</' can't be
// re-parsed as a closing tag — that ordering is load-bearing.
const BLOCK_TAGS = [
  "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "blockquote",
  "pre", "section", "article", "nav", "header", "footer", "aside", "main",
  "ul", "ol", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "figure",
  "figcaption", "form", "fieldset", "details", "summary", "menu", "address",
  "caption", "colgroup",
].join("|");
const BLOCK_CLOSE_RE = new RegExp(`</(?:${BLOCK_TAGS})>`, "gi");

function htmlToText(html: string): string {
  // Pass 1 — structural: drop non-content, turn structure into newlines,
  // and keep inline boundaries from fusing adjacent words.
  let text = html
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<hr\s*\/?>/gi, "\n")
    .replace(/<li\b[^>]*>/gi, "\n\u2022 ")
    .replace(BLOCK_CLOSE_RE, "\n")
    .replace(/<(?:h[1-6]|tr|caption)\b[^>]*>/gi, "\n")
    .replace(/<\/[a-zA-Z][^>]*>/g, " ")
    .replace(/<[^>]+>/g, "");

  // Pass 2 — decode entities, then normalize whitespace.
  text = decodeEntities(text);

  return text
    .replace(/[\u00A0 \t]+/g, " ")
    .replace(/ +([.,;:!?)])/g, "$1")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n[ \t]+/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// ---------------------------------------------------------------------------
// Truncate to a character limit with a visible marker
// ---------------------------------------------------------------------------
function truncate(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text;
  return text.slice(0, maxChars) + `\n\n[… truncated at ${maxChars} chars]`;
}

// ---------------------------------------------------------------------------
// Search providers — all keyless
// ---------------------------------------------------------------------------

interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

// DuckDuckGo wraps result links in a redirector:
// //duckduckgo.com/l/?uddg=<encoded real url>&rut=… — unwrap it.
function resolveDuckDuckGoUrl(href: string): string {
  const wrapped = href.match(/[?&]uddg=([^&]+)/);
  if (wrapped) {
    try {
      return decodeURIComponent(wrapped[1]);
    } catch {
      return "";
    }
  }
  return href.startsWith("//") ? `https:${href}` : href;
}

// Scrape the no-JS DuckDuckGo HTML endpoint. Its result blocks carry
// `result__a` (title link) and `result__snippet` anchors; each snippet
// belongs to the nearest preceding link.
function parseDuckDuckGoHtml(html: string): SearchResult[] {
  const links: Array<{ pos: number; href: string; title: string }> = [];
  const linkRe =
    /<a\b[^>]*class="[^"]*\bresult__a\b[^"]*"[^>]*\bhref="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi;
  for (let m = linkRe.exec(html); m; m = linkRe.exec(html)) {
    links.push({ pos: m.index, href: m[1], title: htmlToText(m[2]) });
  }

  const snippets: Array<{ pos: number; text: string }> = [];
  const snippetRe =
    /<a\b[^>]*class="[^"]*\bresult__snippet\b[^"]*"[^>]*>([\s\S]*?)<\/a>/gi;
  for (let m = snippetRe.exec(html); m; m = snippetRe.exec(html)) {
    snippets.push({ pos: m.index, text: htmlToText(m[1]) });
  }

  return links
    .map((link, i) => {
      const nextPos = links[i + 1]?.pos ?? Number.POSITIVE_INFINITY;
      const snippet = snippets.find((s) => s.pos > link.pos && s.pos < nextPos);
      return {
        title: link.title,
        url: resolveDuckDuckGoUrl(link.href),
        snippet: snippet?.text ?? "",
      };
    })
    .filter((r) => /^https?:\/\//i.test(r.url) && r.title.length > 0);
}

async function duckDuckGoSearch(
  query: string,
  count: number,
  signal: AbortSignal,
): Promise<SearchResult[]> {
  const res = await fetch("https://html.duckduckgo.com/html/", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": BROWSER_UA,
      Accept: "text/html",
    },
    body: new URLSearchParams({ q: query }).toString(),
    signal,
    redirect: "follow",
  });

  // 202 is DuckDuckGo's bot-challenge response — common from datacenter IPs.
  if (res.status === 202) {
    throw new Error(
      "DuckDuckGo declined the request (it rate-limits this IP — common in " +
        "datacenter/sandbox environments). Set SEARXNG_URL to a SearXNG " +
        "instance for reliable keyless search.",
    );
  }
  if (!res.ok) throw new Error(`DuckDuckGo HTTP ${res.status}`);

  const results = parseDuckDuckGoHtml(await res.text());
  if (results.length === 0) {
    throw new Error(
      "DuckDuckGo returned no parseable results — it may be rate-limiting, " +
        "or its page layout changed. Set SEARXNG_URL for a reliable alternative.",
    );
  }
  return results.slice(0, count);
}

async function searxngSearch(
  query: string,
  count: number,
  signal: AbortSignal,
): Promise<SearchResult[]> {
  const base = process.env.SEARXNG_URL as string;
  const url = new URL("/search", base);
  url.searchParams.set("q", query);
  url.searchParams.set("format", "json");

  const res = await fetch(url.toString(), {
    headers: { Accept: "application/json", "User-Agent": BROWSER_UA },
    signal,
  });
  if (!res.ok) {
    throw new Error(
      `SearXNG HTTP ${res.status} at ${base} — the instance may have the ` +
        "JSON format disabled (enable `json` under search.formats in its settings.yml).",
    );
  }

  const data = (await res.json().catch(() => null)) as {
    results?: Array<{ title?: string; url?: string; content?: string }>;
  } | null;
  if (!data) {
    throw new Error(
      `SearXNG at ${base} did not return JSON — the instance likely has the ` +
        "JSON format disabled.",
    );
  }

  return (data.results ?? []).slice(0, count).map((r) => ({
    title: r.title ?? "",
    url: r.url ?? "",
    snippet: r.content ?? "",
  }));
}

async function serperSearch(
  query: string,
  count: number,
  signal: AbortSignal,
): Promise<SearchResult[]> {
  const res = await fetch("https://google.serper.dev/search", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-KEY": process.env.SERPER_API_KEY as string,
    },
    body: JSON.stringify({ q: query, num: count }),
    signal,
  });
  if (res.status === 401 || res.status === 403) {
    throw new Error(
      `Serper rejected the API key (HTTP ${res.status}) — check SERPER_API_KEY.`,
    );
  }
  if (res.status === 429) {
    throw new Error("Serper rate limit / credits exhausted (HTTP 429).");
  }
  if (!res.ok) throw new Error(`Serper HTTP ${res.status}`);

  const data = (await res.json().catch(() => null)) as {
    organic?: Array<{ title?: string; link?: string; snippet?: string }>;
  } | null;

  return (data?.organic ?? []).slice(0, count).map((r) => ({
    title: r.title ?? "",
    url: r.link ?? "",
    snippet: r.snippet ?? "",
  }));
}

async function braveSearch(
  query: string,
  count: number,
  signal: AbortSignal,
): Promise<SearchResult[]> {
  const url = new URL("https://api.search.brave.com/res/v1/web/search");
  url.searchParams.set("q", query);
  url.searchParams.set("count", String(count));

  const res = await fetch(url.toString(), {
    headers: {
      Accept: "application/json",
      "Accept-Encoding": "gzip",
      "X-Subscription-Token": process.env.BRAVE_SEARCH_API_KEY as string,
    },
    signal,
  });
  if (res.status === 401 || res.status === 403) {
    throw new Error(
      `Brave Search rejected the API key (HTTP ${res.status}) — check BRAVE_SEARCH_API_KEY.`,
    );
  }
  if (res.status === 429) {
    throw new Error("Brave Search rate limit reached (HTTP 429) — try again shortly.");
  }
  if (!res.ok) throw new Error(`Brave Search HTTP ${res.status}`);

  const data = (await res.json().catch(() => null)) as {
    web?: { results?: Array<{ title?: string; url?: string; description?: string }> };
  } | null;

  return (data?.web?.results ?? []).slice(0, count).map((r) => ({
    title: r.title ?? "",
    url: r.url ?? "",
    snippet: r.description ?? "",
  }));
}

// Ordered by reliability: a configured keyed/self-hosted provider first,
// the keyless DuckDuckGo scraper last. Each turn uses the first provider
// whose config is present.
function selectSearchProviders(): Array<{
  name: string;
  run: (q: string, n: number, s: AbortSignal) => Promise<SearchResult[]>;
}> {
  const providers = [];
  if (process.env.SERPER_API_KEY) providers.push({ name: "Serper", run: serperSearch });
  if (process.env.BRAVE_SEARCH_API_KEY) providers.push({ name: "Brave", run: braveSearch });
  if (process.env.SEARXNG_URL) providers.push({ name: "SearXNG", run: searxngSearch });
  providers.push({ name: "DuckDuckGo", run: duckDuckGoSearch });
  return providers;
}

// ---------------------------------------------------------------------------
// Extension entry point
// ---------------------------------------------------------------------------
export default function webToolsExtension(pi: ExtensionAPI) {

  // ─── web_fetch ────────────────────────────────────────────────────────────
  pi.registerTool({
    name: "web_fetch",
    label: "Web Fetch",
    description:
      "Fetch the content of a URL and return it as readable plain text. " +
      "Strips HTML tags. Useful for reading documentation, articles, or any public web page.",
    promptSnippet: "Fetch and read a web page by URL",
    promptGuidelines: [
      "Use web_fetch to read a web page when given a URL or when you need up-to-date online content.",
    ],
    parameters: Type.Object({
      url: Type.String({
        description: "The URL to fetch (must start with http:// or https://)",
      }),
      max_chars: Type.Optional(
        Type.Number({
          description:
            "Maximum characters to return (default 20000). " +
            "Increase for long documents.",
        }),
      ),
    }),

    async execute(_toolCallId, params, signal, onUpdate) {
      const { url, max_chars = 20_000 } = params;

      if (!/^https?:\/\//i.test(url)) {
        return {
          content: [{ type: "text", text: `Error: URL must start with http:// or https://` }],
          isError: true,
          details: {},
        };
      }

      onUpdate?.({ content: [{ type: "text", text: `Fetching ${url} …` }] });

      let res: Response;
      try {
        res = await fetch(url, {
          headers: {
            "User-Agent": BROWSER_UA,
            Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.7",
          },
          signal,
          redirect: "follow",
        });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `Fetch error: ${msg}` }],
          isError: true,
          details: {},
        };
      }

      if (!res.ok) {
        return {
          content: [{ type: "text", text: `HTTP ${res.status} ${res.statusText} — ${url}` }],
          isError: true,
          details: { status: res.status },
        };
      }

      const contentType = res.headers.get("content-type") ?? "";
      const raw = await res.text();

      let text: string;
      if (contentType.includes("text/html") || raw.trimStart().startsWith("<")) {
        text = htmlToText(extractMainContent(raw));
      } else {
        text = raw; // JSON, plain text, markdown, etc.
      }

      const output = truncate(text, max_chars);
      const details = {
        url,
        status: res.status,
        content_type: contentType,
        chars_returned: output.length,
      };

      return {
        content: [{ type: "text", text: output }],
        details,
      };
    },
  });

  // ─── web_search ───────────────────────────────────────────────────────────
  pi.registerTool({
    name: "web_search",
    label: "Web Search",
    description:
      "Search the web and return the top results (title, URL, snippet). " +
      "Uses Serper (SERPER_API_KEY) or Brave (BRAVE_SEARCH_API_KEY) when set, " +
      "a SearXNG instance when SEARXNG_URL is set, or keyless DuckDuckGo as a fallback.",
    promptSnippet: "Search the web for current information",
    promptGuidelines: [
      "Use web_search when the user asks about recent events, news, or anything that may have changed after your training cutoff.",
      "Prefer web_search over web_fetch when you need to discover relevant URLs first.",
    ],
    parameters: Type.Object({
      query: Type.String({
        description: "The search query",
      }),
      count: Type.Optional(
        Type.Number({
          description: "Number of results to return (default 5, max 10)",
        }),
      ),
    }),

    async execute(_toolCallId, params, signal, onUpdate) {
      const { query, count = 5 } = params;
      const n = Math.min(Math.max(count, 1), 10);

      // Try providers in priority order; fall through to the next only when
      // one errors, so a flaky keyless fallback can still rescue the turn.
      const providers = selectSearchProviders();
      let results: SearchResult[] | null = null;
      let provider = providers[0].name;
      const failures: string[] = [];
      for (const candidate of providers) {
        provider = candidate.name;
        onUpdate?.({ content: [{ type: "text", text: `Searching ${provider}: ${query} …` }] });
        try {
          results = await candidate.run(query, n, signal);
          break;
        } catch (err: unknown) {
          failures.push(`${candidate.name}: ${err instanceof Error ? err.message : String(err)}`);
        }
      }

      if (results === null) {
        return {
          content: [{ type: "text", text: `Search error — all providers failed:\n${failures.join("\n")}` }],
          isError: true,
          details: { query, failures },
        };
      }

      if (results.length === 0) {
        return {
          content: [{ type: "text", text: `No results found for: ${query}` }],
          details: { query, provider, count: 0 },
        };
      }

      const lines = results.map(
        (r, i) => `[${i + 1}] ${r.title}\n    ${r.url}\n    ${r.snippet}`,
      );
      const text = `Search results for "${query}" (via ${provider}):\n\n` + lines.join("\n\n");

      return {
        content: [{ type: "text", text }],
        details: { query, provider, count: results.length, results },
      };
    },
  });
}
