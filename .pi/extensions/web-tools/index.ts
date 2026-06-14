/**
 * Web Tools Extension
 *
 * Adds two tools analogous to Claude Code's web capabilities:
 *
 *   web_fetch  — fetch a URL and return readable text (strips HTML)
 *   web_search — search the web with no API key, via DuckDuckGo
 *                (default) or a SearXNG instance
 *
 * Configuration (optional — search works with no configuration):
 *   SEARXNG_URL — base URL of a SearXNG instance, e.g. https://searx.example.
 *                 When set, search uses its JSON API instead of DuckDuckGo.
 *                 The instance must have the `json` format enabled
 *                 (search.formats in its settings.yml). This is the most
 *                 reliable keyless option — DuckDuckGo rate-limits
 *                 datacenter IPs, so it can fail inside a sandbox.
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

// ---------------------------------------------------------------------------
// HTML entity decoding (named + numeric, no external deps)
// ---------------------------------------------------------------------------
const NAMED_ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'",
  nbsp: " ", ensp: " ", emsp: " ",
  lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”",
  mdash: "—", ndash: "–",
  copy: "©", reg: "®", trade: "™",
  hellip: "…", middot: "·", bull: "•",
  laquo: "«", raquo: "»",
  times: "×", divide: "÷", plusmn: "±", deg: "°",
  euro: "€", pound: "£", yen: "¥",
  larr: "←", rarr: "→", uarr: "↑", darr: "↓",
  frac12: "½", frac14: "¼", frac34: "¾",
};

function codePointToString(cp: number): string {
  // Skip control chars and invalid code points; fall back to empty.
  if (!Number.isFinite(cp) || cp < 0x20 || cp > 0x10ffff) return "";
  try {
    return String.fromCodePoint(cp);
  } catch {
    return "";
  }
}

function decodeEntities(text: string): string {
  return text
    .replace(/&#x([0-9a-fA-F]+);/g, (_m, hex) => codePointToString(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_m, dec) => codePointToString(parseInt(dec, 10)))
    .replace(/&([a-zA-Z][a-zA-Z0-9]*);/g, (m, name: string) =>
      Object.prototype.hasOwnProperty.call(NAMED_ENTITIES, name) ? NAMED_ENTITIES[name] : m);
}

// ---------------------------------------------------------------------------
// Main-content extraction — strip page chrome before conversion
// ---------------------------------------------------------------------------
function extractMainContent(html: string): string {
  const main = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i);
  if (main && main[1].trim()) return main[1];

  const article = html.match(/<article\b[^>]*>([\s\S]*?)<\/article>/i);
  if (article && article[1].trim()) return article[1];

  const roleMain = html.match(
    /<([a-zA-Z][\w-]*)\b[^>]*\brole=["']main["'][^>]*>([\s\S]*?)<\/\1>/i,
  );
  if (roleMain && roleMain[2].trim()) return roleMain[2];

  const body = html.match(/<body\b[^>]*>([\s\S]*?)<\/body>/i);
  if (body && body[1].trim()) return body[1];

  return html;
}

// ---------------------------------------------------------------------------
// HTML → plain text (no external deps needed)
// ---------------------------------------------------------------------------
// Block-level tags whose closings should force a line break.
const BLOCK_TAGS = [
  "p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "blockquote",
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
    // Remove non-content entirely (no space placeholder → no blank-line gaps).
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    // Explicit line breaks.
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<hr\s*\/?>/gi, "\n")
    // List items get a bullet prefix.
    .replace(/<li\b[^>]*>/gi, "\n• ")
    // Block closings and line-starting openings → newline.
    .replace(BLOCK_CLOSE_RE, "\n")
    .replace(/<(?:h[1-6]|tr|caption)\b[^>]*>/gi, "\n")
    // Space after any remaining closing tag so inline elements don't fuse.
    .replace(/<\/[a-zA-Z][^>]*>/g, " ")
    // Strip all remaining (opening / void) tags.
    .replace(/<[^>]+>/g, "");

  // Pass 2 — decode entities, then normalize whitespace.
  text = decodeEntities(text);

  return text
    .replace(/ /g, " ")          // NBSP → regular space
    .replace(/[ \t]+/g, " ")          // collapse spaces/tabs
    .replace(/ +([.,;:!?)])/g, "$1")  // drop space before punctuation
    .replace(/[ \t]+\n/g, "\n")       // trailing spaces
    .replace(/\n[ \t]+/g, "\n")       // leading spaces
    .replace(/\n{3,}/g, "\n\n")       // collapse blank lines
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
      "No API key required — uses DuckDuckGo by default, or a SearXNG " +
      "instance when SEARXNG_URL is set.",
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

      const provider = process.env.SEARXNG_URL ? "SearXNG" : "DuckDuckGo";
      onUpdate?.({ content: [{ type: "text", text: `Searching ${provider}: ${query} …` }] });

      let results: SearchResult[];
      try {
        results = process.env.SEARXNG_URL
          ? await searxngSearch(query, n, signal)
          : await duckDuckGoSearch(query, n, signal);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text", text: `Search error: ${msg}` }],
          isError: true,
          details: {},
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
