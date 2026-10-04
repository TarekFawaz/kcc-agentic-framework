import { gunzipSync } from "node:zlib";
import { PAYLOAD_GZ_B64, PAYLOAD_VERSION } from "./generated/payload";

export interface PayloadFile {
  /** Path relative to `.KCC/`, forward slashes. */
  rel: string;
  data: Buffer;
}

let cache: Map<string, Buffer> | undefined;

/** The `.KCC/` tree embedded in this binary. */
export function payloadFiles(): Map<string, Buffer> {
  if (cache) return cache;
  const raw = gunzipSync(Buffer.from(PAYLOAD_GZ_B64, "base64")).toString("utf8");
  const parsed = JSON.parse(raw) as { files: Record<string, { t?: string; b?: string }> };
  cache = new Map();
  for (const [rel, f] of Object.entries(parsed.files)) {
    cache.set(rel, f.t !== undefined ? Buffer.from(f.t, "utf8") : Buffer.from(f.b ?? "", "base64"));
  }
  return cache;
}

export const payloadVersion = PAYLOAD_VERSION;

/** Files the project owns once written: never overwritten, never a conflict. */
export function isUserOwned(rel: string): boolean {
  return rel === "settings.json";
}

/** Scripts and git hooks must be executable on macOS and Linux. */
export function isExecutable(rel: string): boolean {
  return rel.endsWith(".sh") || rel.startsWith("tools/hooks/");
}
