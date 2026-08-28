/**
 * Deterministic fixture-backed control-plane server for the canvas E2E.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 5.  The server is
 * seeded from ``.KCC/runtime/tests/fixtures/canvas_ready_run.json`` (a
 * ready CONTRACT_REVIEW run: zero readiness blockers, current evidence,
 * lockable two-tier Build Contract, canonical Tier-1 hash, clickable
 * prototype reference) and serves the exact control-plane surface the
 * canvas talks to:
 *
 * * GET ``/api/run`` ``/api/trace`` ``/api/readiness`` ``/api/contract``
 *   — projections typed against ``src/types.ts`` (the readiness /
 *   trace evaluation mirrors the runtime fail-closed rules);
 * * POST ``/api/h1`` ``/api/h2`` ``/api/lock`` ``/api/pause``
 *   ``/api/resume`` — every command carries ``expected_state`` and
 *   ``/lock`` additionally carries ``tier1_hash``; a stale state or a
 *   stale Tier-1 hash responds HTTP 409 ``STALE_STATE`` /
 *   ``STALE_CONTRACT`` exactly like the production adapter;
 * * the built canvas (``dist/``) and the clickable prototype
 *   (``e2e/prototype/``, the H2 walkthrough target) over static HTTP.
 *
 * Determinism rules:
 *
 * * one in-memory state machine per server process — the E2E scenario
 *   drives the prescribed transitions CONTRACT_REVIEW --LOCK-->
 *   BUILDING --PAUSE--> PAUSED --RESUME--> BUILDING (the LOCK hop
 *   collapses the controller's LOCKED -> BUILDING advance into the one
 *   deterministic transition the canvas observes, per the task
 *   contract);
 * * the fixture's authoring instant (``meta.now``) is shifted to server
 *   start, so evidence keeps exactly the authored age — current
 *   (never stale/future) — and ``readiness.ready`` stays true for the
 *   whole run; every evaluation uses one fixed instant;
 * * command counters are exposed for the scenario's no-retry /
 *   no-extra-gate assertions; the server never mints timestamps,
 *   random ids or protocol details.
 */
import { existsSync, readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { dirname, extname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import type {
  CommandResult,
  ContractProjection,
  LifecycleState,
  NodeKind,
  ReadinessItemProjection,
  ReadinessProjection,
  ReadinessStatus,
  RunProjection,
  TraceCoverageResult,
  TraceProjection,
} from "../src/types";

// ---------------------------------------------------------------------------
// Fixture shapes (raw model JSON as dumped by the runtime models)
// ---------------------------------------------------------------------------

type FixtureRun = RunProjection;
type FixtureTrace = NonNullable<ContractProjection["trace"]>;
type FixtureReadinessPack = NonNullable<ContractProjection["readiness"]>;
type FixtureReadinessItem = FixtureReadinessPack["items"][number];
type FixtureEvidenceRecord = FixtureReadinessItem["evidence"][number];
type FixtureContract = Omit<ContractProjection, "present" | "tier1_hash">;

interface FixtureFile {
  meta: { id: string; purpose: string; now: string; evidence_ttl: string };
  run: FixtureRun;
  trace: FixtureTrace;
  readiness: FixtureReadinessPack;
  contract: FixtureContract;
  tier1_hash: string;
}

// ---------------------------------------------------------------------------
// Server surface (consumed by the spec)
// ---------------------------------------------------------------------------

export interface ServerMetrics {
  /** H1/H2 command posts (the canvas never posts them — no extra gate). */
  h1Posts: number;
  h2Posts: number;
  /** LOCK posts (the canvas never auto-retries: exactly one per run). */
  lockPosts: number;
  pausePosts: number;
  resumePosts: number;
}

export interface FixtureServer {
  /** ``http://127.0.0.1:<port>`` the canvas was served from. */
  readonly baseUrl: string;
  /** The canonical Tier-1 hash the fixture contract proves at LOCK. */
  readonly tier1Hash: string;
  readonly metrics: ServerMetrics;
  /** The ``tier1_hash`` of the last accepted LOCK (null until then). */
  lastLockTier1Hash(): string | null;
  close(): void;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const E2E_DIR = dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = join(
  E2E_DIR,
  "..",
  "..",
  "runtime",
  "tests",
  "fixtures",
  "canvas_ready_run.json",
);
const DIST_DIR = join(E2E_DIR, "..", "dist");
const PROTOTYPE_DIR = join(E2E_DIR, "prototype");
const API_PREFIX = "/api/";

const MIME_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".map": "application/json; charset=utf-8",
};

/** Parse a fixture ISO-8601 duration (``PT4H``) into milliseconds. */
function parseIsoDuration(value: string): number {
  const match = /^P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/.exec(value);
  if (match === null) {
    throw new Error(`unsupported ISO-8601 duration in fixture: ${value}`);
  }
  const days = Number(match[1] ?? "0");
  const hours = Number(match[2] ?? "0");
  const minutes = Number(match[3] ?? "0");
  const seconds = Number(match[4] ?? "0");
  return (((days * 24 + hours) * 60 + minutes) * 60 + seconds) * 1000;
}

function loadFixture(): FixtureFile {
  const raw = readFileSync(FIXTURE_PATH, "utf8");
  return JSON.parse(raw) as FixtureFile;
}

// ---------------------------------------------------------------------------
// Deterministic control-plane server
// ---------------------------------------------------------------------------

class StaleStateError extends Error {
  constructor(actual: LifecycleState, expected: LifecycleState) {
    super(`run ${actual} does not match the expected ${expected}`);
    this.name = "StaleStateError";
  }
}

class FixtureControlPlane implements FixtureServer {
  private readonly fixture: FixtureFile;
  private readonly server: Server;
  /** One fixed instant per server run: all evaluations share it. */
  private readonly nowMs: number;
  /** Shift from the fixture authoring instant to server start. */
  private readonly deltaMs: number;
  private state: LifecycleState;
  private contractHash: string | null;
  private lastLockTier1HashValue: string | null = null;
  readonly metrics: ServerMetrics = {
    h1Posts: 0,
    h2Posts: 0,
    lockPosts: 0,
    pausePosts: 0,
    resumePosts: 0,
  };

  private constructor(fixture: FixtureFile) {
    this.fixture = fixture;
    this.state = fixture.run.state;
    this.contractHash = fixture.run.contract_hash;
    this.nowMs = Date.now();
    this.deltaMs = this.nowMs - Date.parse(fixture.meta.now);
    this.server = createServer((request, response) => {
      void this.handle(request, response);
    });
  }

  static async start(): Promise<FixtureControlPlane> {
    const fixture = loadFixture();
    if (fixture.run.state !== "CONTRACT_REVIEW") {
      throw new Error(`fixture run must be CONTRACT_REVIEW, is ${fixture.run.state}`);
    }
    if (!/^[0-9a-f]{64}$/.test(fixture.tier1_hash)) {
      throw new Error(`fixture tier1_hash must be a 64-char sha256, is ${fixture.tier1_hash}`);
    }
    const distEntry = join(DIST_DIR, "index.html");
    if (!existsSync(distEntry)) {
      throw new Error(
        `the production canvas build is missing (${distEntry}) — run "npm run build" before "npm run test:e2e"`,
      );
    }
    const plane = new FixtureControlPlane(fixture);
    await new Promise<void>((resolve, reject) => {
      plane.server.on("error", reject);
      plane.server.listen(0, "127.0.0.1", resolve);
    });
    return plane;
  }

  get baseUrl(): string {
    const address = this.server.address();
    if (address === null) {
      throw new Error("fixture server is not listening");
    }
    return `http://127.0.0.1:${address.port}`;
  }

  get tier1Hash(): string {
    return this.fixture.tier1_hash;
  }

  lastLockTier1Hash(): string | null {
    return this.lastLockTier1HashValue;
  }

  close(): void {
    this.server.close();
  }

  // -- projections ---------------------------------------------------------

  /** Evidence timestamps re-based onto the server instant (ages preserved). */
  private shiftedCheckedAt(value: string): string {
    return new Date(Date.parse(value) + this.deltaMs).toISOString();
  }

  private isCurrent(record: FixtureEvidenceRecord, ttlMs: number): boolean {
    const age = this.nowMs - (Date.parse(record.checked_at) + this.deltaMs);
    return age >= 0 && age <= ttlMs;
  }

  private itemEvidenceCurrent(item: FixtureReadinessItem): boolean {
    const ttlMs = parseIsoDuration(item.evidence_ttl);
    return item.required_kinds.every((kind) =>
      item.evidence.some((record) => record.kind === kind && this.isCurrent(record, ttlMs)),
    );
  }

  /** Mirror of the runtime item evaluation (freshest current record wins). */
  private evaluateItem(item: FixtureReadinessItem): { status: ReadinessStatus; reasons: string[] } {
    if (item.status !== "READY") {
      const status = item.status;
      const reason =
        status === "BLOCKER"
          ? "declared blocker"
          : `declared ${status.toLowerCase().replaceAll("_", " ")}`;
      return { status, reasons: [reason] };
    }
    const ttlMs = parseIsoDuration(item.evidence_ttl);
    const missing: string[] = [];
    for (const kind of item.required_kinds) {
      const current = item.evidence.filter(
        (record) => record.kind === kind && this.isCurrent(record, ttlMs),
      );
      if (current.length === 0) {
        missing.push(kind);
        continue;
      }
      // On an exact timestamp tie the non-pass record wins (fail closed).
      const latest = current.reduce((best, record) => {
        const bestAt = Date.parse(best.checked_at);
        const recordAt = Date.parse(record.checked_at);
        if (recordAt > bestAt) {
          return record;
        }
        if (recordAt === bestAt && record.result !== "pass" && best.result === "pass") {
          return record;
        }
        return best;
      });
      if (latest.result !== "pass") {
        missing.push(kind);
      }
    }
    if (missing.length > 0) {
      return {
        status: "BLOCKER",
        reasons: [`missing fresh pass evidence for: ${missing.join(", ")}`],
      };
    }
    return {
      status: "READY",
      reasons: [`fresh pass evidence for: ${item.required_kinds.join(", ")}`],
    };
  }

  private runProjection(): RunProjection {
    return {
      run_id: this.fixture.run.run_id,
      title: this.fixture.run.title,
      created_at: this.fixture.run.created_at,
      state: this.state,
      contract_hash: this.contractHash,
    };
  }

  /**
   * Mirror of the runtime reachability rule
   * (``kcc_autobuild.trace.validate_trace_coverage``, Design Spec v1.2
   * sections 10 / 10.3): a requirement is covered only when forward
   * traversal reaches BOTH an ``acceptance`` node and a
   * ``production_validation`` node through forward edges; otherwise it
   * is an orphan requirement and blocks LOCK.
   *
   * The mirror must behave exactly like the runtime — the canvas
   * renders this server-owned coverage (orphans get the BLOCKER badge)
   * and the ready fixture must show zero orphans.  In particular a
   * requirement is NOT classified by its direct edge targets (REQ-001
   * -> IMPL-01 arrives at AC-001 / PROD-001 transitively), so coverage
   * is the same forward-transitive BFS the runtime performs.
   */
  private traceCoverage(): TraceCoverageResult {
    const trace = this.fixture.trace;
    const adjacency = new Map<string, string[]>();
    for (const edge of trace.edges) {
      const children = adjacency.get(edge.source) ?? [];
      children.push(edge.target);
      adjacency.set(edge.source, children);
    }
    const kindById = new Map(trace.nodes.map((node) => [node.id, node.kind]));
    const covered: string[] = [];
    const orphans: string[] = [];
    for (const node of trace.nodes) {
      if (node.kind !== "requirement") {
        continue;
      }
      const reached = new Set<NodeKind>([node.kind]);
      const seen = new Set<string>([node.id]);
      const queue: string[] = [node.id];
      while (queue.length > 0) {
        const current = queue.shift() as string;
        for (const child of adjacency.get(current) ?? []) {
          if (seen.has(child)) {
            continue;
          }
          seen.add(child);
          const kind = kindById.get(child);
          if (kind !== undefined) {
            reached.add(kind);
          }
          queue.push(child);
        }
      }
      if (reached.has("acceptance") && reached.has("production_validation")) {
        covered.push(node.id);
      } else {
        orphans.push(node.id);
      }
    }
    return { covered: covered.sort(), orphans: orphans.sort() };
  }

  private traceProjection(): TraceProjection {
    const trace = this.fixture.trace;
    return {
      run_id: trace.run_id,
      nodes: trace.nodes,
      edges: trace.edges,
      coverage: this.traceCoverage(),
    };
  }

  private readinessProjection(): ReadinessProjection {
    const pack = this.fixture.readiness;
    const outcomes = pack.items
      .slice()
      .sort((left, right) => left.id.localeCompare(right.id))
      .map((item) => ({ item, outcome: this.evaluateItem(item) }));
    const items: ReadinessItemProjection[] = outcomes.map(({ item, outcome }) => ({
      item_id: item.id,
      status: outcome.status,
      reasons: outcome.reasons,
      evidence: item.evidence.map((record) => ({
        ...record,
        checked_at: this.shiftedCheckedAt(record.checked_at),
      })),
      fallbacks: item.fallbacks,
      evidence_current: this.itemEvidenceCurrent(item),
    }));
    const blockers = outcomes
      .filter(({ outcome }) => outcome.status === "BLOCKER")
      .map(({ item }) => item.id)
      .sort();
    const openRedTeamFindings = pack.red_team_findings
      .filter((finding) => finding.disposition === "OPEN")
      .map((finding) => finding.id)
      .sort();
    const coverageOk = pack.items.length > 0;
    return {
      ready: coverageOk && blockers.length === 0 && openRedTeamFindings.length === 0,
      coverage_ok: coverageOk,
      blockers,
      open_red_team_findings: openRedTeamFindings,
      evidence_stale: items.some((item) => !item.evidence_current),
      items,
    };
  }

  private contractProjection(): ContractProjection {
    const contract = this.fixture.contract;
    return {
      present: true,
      contract_version: contract.contract_version,
      tier1_hash: this.fixture.tier1_hash,
      tier1: contract.tier1,
      tier2: contract.tier2,
      trace: contract.trace,
      readiness: contract.readiness,
      resume: contract.resume,
      locked_at: contract.locked_at,
      contract_hash: contract.contract_hash,
      tier2_hash: contract.tier2_hash,
    };
  }

  // -- commands ------------------------------------------------------------

  private commandResult(command: string): CommandResult {
    return { command, accepted: true, run: this.runProjection() };
  }

  private requireState(expected: LifecycleState): void {
    if (this.state !== expected) {
      throw new StaleStateError(this.state, expected);
    }
  }

  /** Apply the prescribed deterministic transitions. */
  private advance(command: "h1" | "h2" | "lock" | "pause" | "resume"): void {
    switch (command) {
      case "h1":
        this.requireState("DISCOVERY");
        this.state = "PROTOTYPE_REVIEW";
        break;
      case "h2":
        this.requireState("PROTOTYPE_REVIEW");
        this.state = "ARCHITECTURE";
        break;
      case "lock":
        this.requireState("CONTRACT_REVIEW");
        // The deterministic transition the canvas observes: the lock is
        // accepted and the controller moves the run straight into build
        // (LOCKED -> BUILDING collapses into this one hop per the task
        // contract).
        this.state = "BUILDING";
        this.contractHash = this.fixture.tier1_hash;
        break;
      case "pause":
        this.requireState("BUILDING");
        this.state = "PAUSED";
        break;
      case "resume":
        this.requireState("PAUSED");
        // PAUSED -> RESUMING -> BUILDING collapses into the one
        // deterministic transition the canvas observes.
        this.state = "BUILDING";
        break;
    }
  }

  // -- HTTP ----------------------------------------------------------------

  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    try {
      const method = request.method ?? "GET";
      const pathname = (request.url ?? "/").split("?")[0] ?? "/";
      if (pathname.startsWith(API_PREFIX)) {
        if (method === "GET") {
          this.serveProjection(pathname, response);
          return;
        }
        if (method === "POST") {
          await this.serveCommand(request, pathname, response);
          return;
        }
        this.writeJson(response, 405, {
          error: "METHOD_NOT_ALLOWED",
          detail: `method ${method} is not allowed for ${pathname}`,
        });
        return;
      }
      if (method === "GET") {
        this.serveStatic(pathname, response);
        return;
      }
      this.writeJson(response, 405, {
        error: "METHOD_NOT_ALLOWED",
        detail: `method ${method} is not allowed for ${pathname}`,
      });
    } catch (error) {
      this.writeJson(response, 500, {
        error: "INTERNAL",
        detail: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private serveProjection(pathname: string, response: ServerResponse): void {
    const projections: Record<string, () => object> = {
      "/api/run": () => this.runProjection(),
      "/api/trace": () => this.traceProjection(),
      "/api/readiness": () => this.readinessProjection(),
      "/api/contract": () => this.contractProjection(),
    };
    const projection = projections[pathname];
    if (projection === undefined) {
      this.writeJson(response, 404, { error: "NOT_FOUND", detail: `no route GET ${pathname}` });
      return;
    }
    this.writeJson(response, 200, projection());
  }

  private async serveCommand(
    request: IncomingMessage,
    pathname: string,
    response: ServerResponse,
  ): Promise<void> {
    let command: "h1" | "h2" | "lock" | "pause" | "resume";
    switch (pathname) {
      case "/api/h1":
        command = "h1";
        this.metrics.h1Posts += 1;
        break;
      case "/api/h2":
        command = "h2";
        this.metrics.h2Posts += 1;
        break;
      case "/api/lock":
        command = "lock";
        this.metrics.lockPosts += 1;
        break;
      case "/api/pause":
        command = "pause";
        this.metrics.pausePosts += 1;
        break;
      case "/api/resume":
        command = "resume";
        this.metrics.resumePosts += 1;
        break;
      default:
        this.writeJson(response, 404, {
          error: "NOT_FOUND",
          detail: `no route POST ${pathname}`,
        });
        return;
    }

    const payload = await this.readJsonBody(request);
    if (payload === null) {
      this.writeJson(response, 400, {
        error: "INVALID_JSON",
        detail: "command body was not readable",
      });
      return;
    }
    if (typeof payload.expected_state !== "string") {
      this.writeJson(response, 400, {
        error: "INVALID_REQUEST",
        detail: "expected_state is required",
      });
      return;
    }
    try {
      this.requireState(payload.expected_state as LifecycleState);
    } catch (error) {
      if (error instanceof StaleStateError) {
        this.writeJson(response, 409, { error: "STALE_STATE", detail: error.message });
        return;
      }
      throw error;
    }
    if (command === "lock") {
      const tier1Hash = payload.tier1_hash;
      if (tier1Hash !== this.fixture.tier1_hash) {
        this.writeJson(response, 409, {
          error: "STALE_CONTRACT",
          detail: `tier1_hash ${String(tier1Hash)} does not match the current contract hash ${this.fixture.tier1_hash}`,
        });
        return;
      }
      this.lastLockTier1HashValue = this.tier1Hash;
    }
    this.advance(command);
    this.writeJson(response, 200, this.commandResult(command));
  }

  private readJsonBody(request: IncomingMessage): Promise<Record<string, unknown> | null> {
    return new Promise((resolve, reject) => {
      const chunks: unknown[] = [];
      let settled = false;
      request.on("data", (chunk: unknown) => {
        if (!settled) {
          chunks.push(chunk);
        }
      });
      request.on("end", () => {
        settled = true;
        const raw = chunks.map((chunk) => String(chunk)).join("");
        try {
          const parsed: unknown = JSON.parse(raw);
          if (typeof parsed !== "object" || parsed === null) {
            resolve(null);
            return;
          }
          resolve(parsed as Record<string, unknown>);
        } catch {
          resolve(null);
        }
      });
      request.on("error", reject);
    });
  }

  private writeJson(response: ServerResponse, status: number, payload: object): void {
    response.writeHead(status, {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    });
    response.end(JSON.stringify(payload));
  }

  private serveStatic(pathname: string, response: ServerResponse): void {
    let decoded: string;
    try {
      decoded = decodeURIComponent(pathname);
    } catch {
      this.writeJson(response, 400, { error: "INVALID_PATH", detail: "path is not URI-encoded" });
      return;
    }
    if (decoded === "/" || decoded === "") {
      this.serveFile(join(DIST_DIR, "index.html"), response);
      return;
    }
    const underPrototype = decoded.startsWith("/prototype/");
    const root = underPrototype ? PROTOTYPE_DIR : DIST_DIR;
    const rel = underPrototype ? decoded.slice("/prototype/".length) : decoded.slice(1);
    const filePath = join(root, rel);
    const safe = relative(root, filePath);
    if (safe.startsWith("..") || safe === "") {
      this.writeJson(response, 404, { error: "NOT_FOUND", detail: "path escapes the static root" });
      return;
    }
    this.serveFile(filePath, response);
  }

  private serveFile(filePath: string, response: ServerResponse): void {
    if (!existsSync(filePath)) {
      this.writeJson(response, 404, { error: "NOT_FOUND", detail: `no file ${filePath}` });
      return;
    }
    // Byte-exact: text MIME types are declared with a charset, but
    // binary assets (png/woff/woff2/ttf/ico) must not pass through a
    // UTF-8 decode — a string round-trip would corrupt them.
    const mime = MIME_TYPES[extname(filePath)] ?? "application/octet-stream";
    response.writeHead(200, { "Content-Type": mime, "Cache-Control": "no-store" });
    response.end(readFileSync(filePath));
  }
}

/** Start the deterministic fixture-backed control-plane server. */
export async function startFixtureServer(): Promise<FixtureServer> {
  return FixtureControlPlane.start();
}
