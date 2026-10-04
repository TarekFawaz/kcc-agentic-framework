import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { listFiles } from "../fsutil";
import { payloadFiles } from "../payload";

/**
 * Framework content for the MCP server: the workspace's own `.KCC/` when
 * there is one (so tailoring and local edits are honoured), otherwise the
 * copy embedded in the binary.
 */
export class Content {
  constructor(private readonly root: string | undefined) {}

  private list(prefix: string): string[] {
    if (this.root) return listFiles(join(this.root, ".KCC", prefix), prefix);
    return [...payloadFiles().keys()].filter((r) => r.startsWith(prefix + "/"));
  }

  read(rel: string): string | undefined {
    if (this.root) {
      const p = join(this.root, ".KCC", rel);
      return existsSync(p) ? readFileSync(p, "utf8") : undefined;
    }
    return payloadFiles().get(rel)?.toString("utf8");
  }

  private names(prefix: string, deep = false): string[] {
    return this.list(prefix)
      .filter((r) => deep || !r.slice(prefix.length + 1).includes("/"))
      .map((r) => r.slice(prefix.length + 1));
  }

  agents(): string[] {
    return this.names("capabilities/agents").filter((n) => n.endsWith(".md")).map((n) => basename(n, ".md"));
  }

  skills(): string[] {
    return this.names("capabilities/skills").filter((n) => n.endsWith(".md")).map((n) => basename(n, ".md"));
  }

  /** Every addressable document as `[uri, path relative to .KCC, description]`. */
  catalog(): [string, string, string][] {
    const out: [string, string, string][] = [];
    for (const n of this.names("kernel/protocols")) if (n.endsWith(".md")) out.push([`kcc://protocol/${basename(n, ".md")}`, `kernel/protocols/${n}`, "KCC protocol"]);
    for (const n of this.names("kernel/protocols/dialects")) if (n.endsWith(".md")) out.push([`kcc://dialect/${basename(n, ".md")}`, `kernel/protocols/dialects/${n}`, "KCC development dialect"]);
    for (const n of this.names("kernel/contracts")) if (n.endsWith(".md")) out.push([`kcc://contract/${basename(n, ".md")}`, `kernel/contracts/${n}`, "KCC contract"]);
    for (const n of this.names("kernel/templates", true)) out.push([`kcc://template/${n}`, `kernel/templates/${n}`, "KCC template"]);
    const agents = this.agents().sort((a, b) => b.length - a.length);
    for (const n of this.names("capabilities/agents/refs")) {
      const stem = basename(n, ".md");
      const agent = agents.find((a) => stem.startsWith(a + "-"));
      if (agent) out.push([`kcc://agent/${agent}/ref/${stem.slice(agent.length + 1)}`, `capabilities/agents/refs/${n}`, `On-demand reference for the ${agent} agent`]);
    }
    return out;
  }
}

export function slug(heading: string): string {
  return heading.toLowerCase().replace(/[`*_]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

export function headings(text: string): { level: number; title: string; line: number }[] {
  const out: { level: number; title: string; line: number }[] = [];
  const lines = text.split("\n");
  let fence = false;
  let front = lines[0]?.trim() === "---";
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i] ?? "";
    if (front) {
      if (i > 0 && l.trim() === "---") front = false;
      continue;
    }
    if (/^(```|~~~)/.test(l)) fence = !fence;
    if (fence) continue;
    const m = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(l);
    if (m) out.push({ level: (m[1] ?? "").length, title: m[2] ?? "", line: i });
  }
  return out;
}

/** One section: the heading line through the line before the next heading of the same or a higher level. */
export function section(text: string, wanted: string): string | undefined {
  const hs = headings(text);
  const key = slug(decodeURIComponent(wanted));
  const idx = hs.findIndex((h) => slug(h.title) === key);
  if (idx < 0) return undefined;
  const start = hs[idx];
  if (!start) return undefined;
  const next = hs.slice(idx + 1).find((h) => h.level <= start.level);
  const lines = text.split("\n");
  return lines.slice(start.line, next ? next.line : lines.length).join("\n").trimEnd() + "\n";
}

export interface SkillDoc {
  name: string;
  description: string;
  body: string;
  placeholder: string;
}

export function parseSkill(name: string, text: string): SkillDoc {
  const t = text.replace(/\r\n/g, "\n");
  const m = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/.exec(t);
  const front = m?.[1] ?? "";
  const body = (m?.[2] ?? t).trimStart();
  let description = "";
  const folded = /^description:\s*[>|][-+]?\s*\n((?:[ \t]+.*\n?)+)/m.exec(front);
  if (folded) description = (folded[1] ?? "").split("\n").map((l) => l.trim()).filter(Boolean).join(" ");
  else description = (/^description:\s*(.+)$/m.exec(front)?.[1] ?? "").replace(/^["']|["']$/g, "");
  const placeholder = /^argument-placeholder:\s*(.+)$/m.exec(front)?.[1]?.trim() ?? "<ARGS>";
  return { name, description, body, placeholder };
}
