import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyPayload } from "../src/lock";
import { detectLimit, loadPatterns } from "../src/run/limits";

// Test round 03 was suspended because an architect summary said "rate-limit values are assumptions".
const root = mkdtempSync(join(tmpdir(), "kcc-lim-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("usage-limit detection ignores prose in a finished session", () => {
  applyPayload(root);
  const p = loadPatterns(root, "claude");
  const summary = ["The architecture pass is done.", "- Session lifetimes and rate-limit values are assumptions (A-004).", "", "Nothing was committed."];

  test("a session that exited 0 and mentions rate limits is not a limit", () => {
    expect(detectLimit(summary, 0, p).hit).toBe(false);
  });
  test("the harness's own limit notice on the last lines still counts, even with exit 0", () => {
    expect(detectLimit([...summary, "You've hit your session limit · resets 5pm (Europe/Berlin)"], 0, p).hit).toBe(true);
  });
  test("a failed session with limit wording is a limit", () => {
    expect(detectLimit(["API Error: rate limit exceeded"], 1, p).hit).toBe(true);
  });
});
