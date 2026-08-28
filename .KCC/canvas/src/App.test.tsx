/**
 * Behavioral tests for the canvas App stale-refresh wiring (KCC x
 * Superpowers Hybrid Framework Plan 06, Task 4; Design Spec v1.2
 * section 15; plan Global Constraints on stale-state discipline).
 *
 * Written first (strict TDD red phase), against the external behavior
 * contract of :file:`src/App.tsx`:
 *
 * * ``fetchProjections`` refetches exactly the LOCK surface inputs:
 *   run, readiness and contract (never the trace graph, which is
 *   server-owned display data);
 * * when LOCK (or PAUSE/RESUME) raises :class:`StaleProjectionError`
 *   the App refetches run/readiness/contract, hands the refreshed
 *   projection set to the surface, and NEVER auto-retries the command
 *   — the LOCK request is issued exactly once;
 * * the refreshed Lock surface is what the user sees: the LockBar is
 *   re-evaluated against the fresh run state, with the stale notice
 *   and the current gating reasons visible, before the user can press
 *   LOCK again;
 * * a successful command updates the run projection through the
 *   returned ``CommandResult`` without any refetch;
 * * a non-409 failure surfaces as an error without refetching;
 * * ``CanvasSession`` is the App's wiring holder: the initial load
 *   fetches run/readiness/contract and the trace graph independently
 *   (a trace failure never blanks the LOCK surface), a stale command
 *   publishes the refreshed projection set and the ``staleRefreshed``
 *   flag to exactly the state the surface renders, and LOCK is never
 *   auto-retried.
 *
 * The orchestration helpers are pure async functions over a minimal
 * command/projection source interface, exercised with fakes; ``App``
 * is a thin component over ``CanvasSession``, so the wiring tests
 * drive the session and render the exact state through
 * ``CanvasSurfaces`` (the DOM-free presentation contract). The
 * surfaces are rendered to static markup with ``react-dom/server``.
 */
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

import type {
  CommandRequest,
  CommandResult,
  ContractProjection,
  LockRequest,
  ReadinessProjection,
  RunProjection,
  TraceProjection,
} from "./types";
import { ApiError, StaleProjectionError } from "./api/client";
import {
  CanvasSession,
  CanvasSurfaces,
  fetchProjections,
  submitLock,
  submitPause,
  submitResume,
} from "./App";

const TIER1_HASH = "a".repeat(64);

const RUN: RunProjection = {
  run_id: "RUN-042",
  title: "canvas surfaces run",
  created_at: "2026-01-02T12:00:00Z",
  state: "CONTRACT_REVIEW",
  contract_hash: null,
};

const TRACE: TraceProjection = {
  run_id: "RUN-042",
  nodes: [
    { id: "REQ-042", kind: "requirement" },
    { id: "AC-042-1", kind: "acceptance" },
  ],
  edges: [{ source: "REQ-042", target: "AC-042-1" }],
  coverage: { covered: ["REQ-042"], orphans: [] },
};

const READINESS: ReadinessProjection = {
  ready: true,
  coverage_ok: true,
  blockers: [],
  open_red_team_findings: [],
  evidence_stale: false,
  items: [
    {
      item_id: "PROVIDER-A",
      status: "READY",
      reasons: ["quota confirmed"],
      evidence: [],
      fallbacks: [],
      evidence_current: true,
    },
  ],
};

const CONTRACT: ContractProjection = {
  present: true,
  contract_version: "1.0",
  tier1_hash: TIER1_HASH,
  tier1: {
    product_scope: "Canvas readiness and lock review surface",
    non_goals: [],
    primary_user_journeys: ["Review readiness then LOCK"],
    ux_direction: null,
    prototype_ref: "https://preview.example.test/prototype/run-042/",
    provider_whitelist: [{ provider: "example-provider", paid: false }],
    fallback_whitelist: [],
    auth_model: null,
    core_data_entities: ["run", "readiness"],
    security_constraints: [],
    authority: {
      auto_provision_status: "AUTO_PROVISION_AUTHORIZED",
      auto_provision_providers: ["example-provider"],
      approved_accounts: ["acct-042"],
      credential_refs: ["env://EXAMPLE_TOKEN"],
      dependency_installation: true,
      environment_creation: false,
      cicd_configuration: false,
      database_migration: false,
      dns_changes: false,
      approved_dns_zones: [],
      staging_deployment: false,
      production_deployment: false,
      rollback: false,
      monitoring_setup: false,
      secret_reference_usage: true,
      bounded_spend: true,
      auto_debug: false,
    },
    money: {
      hard_limits: true,
      currency: "USD",
      one_time_build_budget: null,
      per_provider_caps: {},
      monthly_infrastructure_cap: null,
      model_token_cap: null,
    },
    destructive_policy: [],
    production_target: null,
    rollout_class: null,
    definition_of_done:
      "A fresh lock surface is displayed after a stale projection.",
    definition_of_done_ids: ["AC-042-1"],
    requires_rollback_evidence: false,
  },
  tier2: null,
  trace: null,
  readiness: null,
  resume: null,
  locked_at: null,
  contract_hash: null,
  tier2_hash: null,
};

function commandResult(command: string, state: RunProjection["state"]): CommandResult {
  return { command, accepted: true, run: { ...RUN, state } };
}

function fakeClient() {
  const getRun = vi.fn<() => Promise<RunProjection>>(async () => ({ ...RUN }));
  const getReadiness = vi.fn<() => Promise<ReadinessProjection>>(async () => ({
    ...READINESS,
  }));
  const getContract = vi.fn<() => Promise<ContractProjection>>(async () => ({
    ...CONTRACT,
  }));
  const getTrace = vi.fn<() => Promise<TraceProjection>>(async () => ({ ...TRACE }));
  const lock = vi.fn<(request: LockRequest) => Promise<CommandResult>>(async () =>
    commandResult("lock", "LOCKED"),
  );
  const pause = vi.fn<(request: CommandRequest) => Promise<CommandResult>>(async () =>
    commandResult("pause", "PAUSED"),
  );
  const resume = vi.fn<(request: CommandRequest) => Promise<CommandResult>>(async () =>
    commandResult("resume", "BUILDING"),
  );
  return { getRun, getReadiness, getContract, getTrace, lock, pause, resume };
}

describe("fetchProjections", () => {
  it("refetches exactly run, readiness and contract (never the trace graph)", async () => {
    const client = fakeClient();
    const projections = await fetchProjections(client);

    expect(projections.run.run_id).toBe("RUN-042");
    expect(projections.readiness.ready).toBe(true);
    expect(projections.contract.tier1_hash).toBe(TIER1_HASH);
    expect(client.getRun).toHaveBeenCalledTimes(1);
    expect(client.getReadiness).toHaveBeenCalledTimes(1);
    expect(client.getContract).toHaveBeenCalledTimes(1);
    expect(client.getTrace).not.toHaveBeenCalled();
  });
});

describe("submitLock stale-state discipline", () => {
  it("refetches run/readiness/contract and never auto-retries a stale LOCK", async () => {
    const client = fakeClient();
    client.lock.mockRejectedValue(
      new StaleProjectionError(409, "STALE_STATE", "run is BUILDING, expected CONTRACT_REVIEW"),
    );

    const outcome = await submitLock(client, TIER1_HASH);

    expect(outcome.kind).toBe("stale");
    if (outcome.kind === "stale") {
      expect(outcome.projections.run.run_id).toBe("RUN-042");
      expect(outcome.projections.readiness).toBeTruthy();
      expect(outcome.projections.contract).toBeTruthy();
    }
    // Exactly one LOCK request: the stale command is failed fast, never retried.
    expect(client.lock).toHaveBeenCalledTimes(1);
    expect(client.lock).toHaveBeenCalledWith({
      expected_state: "CONTRACT_REVIEW",
      tier1_hash: TIER1_HASH,
    });
    // The refresh is the LOCK surface only: run/readiness/contract, no trace.
    expect(client.getRun).toHaveBeenCalledTimes(1);
    expect(client.getReadiness).toHaveBeenCalledTimes(1);
    expect(client.getContract).toHaveBeenCalledTimes(1);
    expect(client.getTrace).not.toHaveBeenCalled();
  });

  it("maps a stale Tier-1 contract proof to a refresh as well", async () => {
    const client = fakeClient();
    client.lock.mockRejectedValue(
      new StaleProjectionError(409, "STALE_CONTRACT", "tier1_hash does not match"),
    );

    const outcome = await submitLock(client, TIER1_HASH);

    expect(outcome.kind).toBe("stale");
    expect(client.lock).toHaveBeenCalledTimes(1);
    expect(client.getContract).toHaveBeenCalledTimes(1);
  });

  it("applies an accepted LOCK result without refetching anything", async () => {
    const client = fakeClient();
    const outcome = await submitLock(client, TIER1_HASH);

    expect(outcome.kind).toBe("accepted");
    if (outcome.kind === "accepted") {
      expect(outcome.result.command).toBe("lock");
      expect(outcome.result.run.state).toBe("LOCKED");
    }
    expect(client.getRun).not.toHaveBeenCalled();
    expect(client.getReadiness).not.toHaveBeenCalled();
    expect(client.getContract).not.toHaveBeenCalled();
  });

  it("surfaces a non-409 failure without refetching", async () => {
    const client = fakeClient();
    client.lock.mockRejectedValue(new ApiError(400, "INVALID_REQUEST", "bad tier1 hash"));

    const outcome = await submitLock(client, TIER1_HASH);

    expect(outcome.kind).toBe("error");
    if (outcome.kind === "error") {
      expect(outcome.message).toContain("INVALID_REQUEST");
    }
    expect(client.getRun).not.toHaveBeenCalled();
  });

  it("reports a failed refresh as an error (never a silent stale outcome)", async () => {
    const client = fakeClient();
    client.lock.mockRejectedValue(
      new StaleProjectionError(409, "STALE_STATE", "run moved on"),
    );
    client.getContract.mockRejectedValue(new Error("network down"));

    const outcome = await submitLock(client, TIER1_HASH);

    expect(outcome.kind).toBe("error");
    if (outcome.kind === "error") {
      expect(outcome.message).toContain("network down");
    }
  });
});

describe("submitPause / submitResume", () => {
  it("sends PAUSE with expected_state BUILDING only", async () => {
    const client = fakeClient();
    const outcome = await submitPause(client);

    expect(outcome.kind).toBe("accepted");
    expect(client.pause).toHaveBeenCalledWith({ expected_state: "BUILDING" });
    expect(client.lock).not.toHaveBeenCalled();
  });

  it("sends RESUME with expected_state PAUSED only", async () => {
    const client = fakeClient();
    const outcome = await submitResume(client);

    expect(outcome.kind).toBe("accepted");
    expect(client.resume).toHaveBeenCalledWith({ expected_state: "PAUSED" });
  });

  it("refetches the LOCK surface when PAUSE answers a stale projection (never retries)", async () => {
    const client = fakeClient();
    client.pause.mockRejectedValue(
      new StaleProjectionError(409, "STALE_STATE", "run is no longer BUILDING"),
    );

    const outcome = await submitPause(client);

    expect(outcome.kind).toBe("stale");
    expect(client.pause).toHaveBeenCalledTimes(1);
    expect(client.getRun).toHaveBeenCalledTimes(1);
  });
});

describe("CanvasSession stale-refresh wiring (integrated)", () => {
  it("load() populates run/readiness/contract and the trace graph from the client", async () => {
    const client = fakeClient();
    const session = new CanvasSession(client, () => {});
    await session.load();
    const state = session.getState();
    expect(state.run?.run_id).toBe("RUN-042");
    expect(state.run?.state).toBe("CONTRACT_REVIEW");
    expect(state.readiness?.ready).toBe(true);
    expect(state.contract?.tier1_hash).toBe(TIER1_HASH);
    expect(state.trace?.nodes).toHaveLength(2);
    expect(state.busy).toBe(false);
    expect(state.error).toBeNull();
    expect(state.traceError).toBeNull();
    expect(state.staleRefreshed).toBe(false);
    expect(client.getRun).toHaveBeenCalledTimes(1);
    expect(client.getReadiness).toHaveBeenCalledTimes(1);
    expect(client.getContract).toHaveBeenCalledTimes(1);
    expect(client.getTrace).toHaveBeenCalledTimes(1);
  });

  it("keeps the LOCK surface when only the trace graph fails to load", async () => {
    const client = fakeClient();
    client.getTrace.mockRejectedValue(new Error("trace service down"));
    const session = new CanvasSession(client, () => {});
    await session.load();
    const state = session.getState();
    // The projections still arrive: the canvas is never blanked by a
    // display-only trace failure.
    expect(state.run?.state).toBe("CONTRACT_REVIEW");
    expect(state.readiness).toBeTruthy();
    expect(state.contract).toBeTruthy();
    expect(state.trace).toBeNull();
    expect(state.traceError).toContain("trace service down");
    expect(state.error).toBeNull();

    // The user still sees the readiness/contract/LOCK surface, with a
    // distinct trace error in the graph area.
    const html = renderToStaticMarkup(
      <CanvasSurfaces
        run={state.run}
        trace={state.trace}
        readiness={state.readiness}
        contract={state.contract}
        busy={state.busy}
        error={state.error}
        staleRefreshed={state.staleRefreshed}
        traceError={state.traceError}
        onLock={vi.fn()}
        onPause={vi.fn()}
        onResume={vi.fn()}
      />,
    );
    expect(html).toContain("canvas-shell__trace-error");
    expect(html).toContain("trace service down");
    expect(html).toContain('data-ready="true"');
    expect(html).toContain("Canvas readiness and lock review surface");
    expect(html).toContain("LOCK &amp; BUILD");
  });

  it("refreshes run/readiness/contract on a stale LOCK and never auto-retries", async () => {
    const client = fakeClient();
    client.lock.mockRejectedValue(
      new StaleProjectionError(409, "STALE_STATE", "run is BUILDING, expected CONTRACT_REVIEW"),
    );
    const session = new CanvasSession(client, () => {});
    await session.load();
    await session.lock(TIER1_HASH);

    const state = session.getState();
    expect(state.staleRefreshed).toBe(true);
    expect(state.busy).toBe(false);
    expect(state.error).toBeNull();
    // Exactly one LOCK request: stale is failed fast, never retried.
    expect(client.lock).toHaveBeenCalledTimes(1);
    expect(client.lock).toHaveBeenCalledWith({
      expected_state: "CONTRACT_REVIEW",
      tier1_hash: TIER1_HASH,
    });
    // The refresh is the LOCK surface only: run/readiness/contract, no trace.
    expect(client.getRun).toHaveBeenCalledTimes(2);
    expect(client.getReadiness).toHaveBeenCalledTimes(2);
    expect(client.getContract).toHaveBeenCalledTimes(2);
    expect(client.getTrace).toHaveBeenCalledTimes(1);
  });

  it("renders exactly the refreshed lock surface before the user can re-enable LOCK", async () => {
    const client = fakeClient();
    // Initial load sees CONTRACT_REVIEW; the post-stale refresh reveals
    // that the server has already moved the run to BUILDING.
    client.getRun.mockResolvedValueOnce({ ...RUN });
    client.getRun.mockResolvedValueOnce({ ...RUN, state: "BUILDING" });
    client.lock.mockRejectedValue(
      new StaleProjectionError(409, "STALE_STATE", "run is BUILDING"),
    );
    const session = new CanvasSession(client, () => {});
    await session.load();
    await session.lock(TIER1_HASH);

    const state = session.getState();
    expect(state.run?.state).toBe("BUILDING");
    const html = renderToStaticMarkup(
      <CanvasSurfaces
        run={state.run}
        trace={state.trace}
        readiness={state.readiness}
        contract={state.contract}
        busy={state.busy}
        error={state.error}
        staleRefreshed={state.staleRefreshed}
        traceError={state.traceError}
        onLock={vi.fn()}
        onPause={vi.fn()}
        onResume={vi.fn()}
      />,
    );
    expect(html).toContain("lock-bar__stale-notice");
    expect(html).toContain("LOCK expects CONTRACT_REVIEW (current: BUILDING)");
    expect(
      (/<button class="lock-bar__button"[^>]*>/.exec(html)?.[0] ?? "").includes("disabled"),
    ).toBe(true);
    // The refreshed run is BUILDING, so PAUSE is re-enabled on the
    // surface the user now reviews.
    expect(
      (/<button class="lock-bar__pause"[^>]*>/.exec(html)?.[0] ?? "").includes("disabled"),
    ).toBe(false);
  });

  it("applies an accepted LOCK result without refetching anything", async () => {
    const client = fakeClient();
    const session = new CanvasSession(client, () => {});
    await session.load();
    await session.lock(TIER1_HASH);

    const state = session.getState();
    expect(state.run?.state).toBe("LOCKED");
    expect(state.staleRefreshed).toBe(false);
    expect(state.busy).toBe(false);
    expect(state.error).toBeNull();
    expect(client.getRun).toHaveBeenCalledTimes(1);
    expect(client.getReadiness).toHaveBeenCalledTimes(1);
    expect(client.getContract).toHaveBeenCalledTimes(1);
  });

  it("surfaces a non-409 command failure without refetching", async () => {
    const client = fakeClient();
    client.lock.mockRejectedValue(
      new ApiError(400, "LOCK_DENIED", "readiness blockers: PROVIDER-B"),
    );
    const session = new CanvasSession(client, () => {});
    await session.load();
    await session.lock(TIER1_HASH);

    const state = session.getState();
    expect(state.error).toContain("LOCK_DENIED");
    expect(state.staleRefreshed).toBe(false);
    expect(state.run?.state).toBe("CONTRACT_REVIEW");
    expect(client.getRun).toHaveBeenCalledTimes(1);
    expect(client.getReadiness).toHaveBeenCalledTimes(1);
    expect(client.getContract).toHaveBeenCalledTimes(1);
  });
});

describe("CanvasSurfaces renders the refreshed Lock surface", () => {
  function surfacesHtml(
    run: RunProjection,
    staleRefreshed: boolean,
  ): string {
    return renderToStaticMarkup(
      <CanvasSurfaces
        run={run}
        trace={TRACE}
        readiness={READINESS}
        contract={CONTRACT}
        busy={false}
        error={null}
        staleRefreshed={staleRefreshed}
        onLock={vi.fn()}
        onPause={vi.fn()}
        onResume={vi.fn()}
      />,
    );
  }

  it("renders the timeline, trace graph, panels and gated lock bar together", () => {
    const html = surfacesHtml(RUN, false);
    expect(html).toContain('data-phase="CONTRACT_REVIEW"');
    expect(html).toContain('aria-current="step"');
    expect(html).toContain('data-testid="rf__node-REQ-042"');
    expect(html).toContain('sandbox="allow-forms allow-scripts"');
    expect(html).toContain('data-ready="true"');
    expect(html).toContain("Canvas readiness and lock review surface");
    const lockButton = /<button class="lock-bar__button"[^>]*>/.exec(html)?.[0] ?? "";
    expect(lockButton).not.toContain("disabled");
  });

  it("shows the refreshed state to the user before LOCK can be pressed again", () => {
    // After a stale projection the server says the run is already
    // BUILDING: the refreshed surface must disable LOCK and tell the
    // user why, and the stale refresh notice must be visible.
    const html = surfacesHtml({ ...RUN, state: "BUILDING" }, true);
    expect(html).toContain("lock-bar__stale-notice");
    expect(html).toContain("LOCK expects CONTRACT_REVIEW (current: BUILDING)");
    expect(
      (/<button class="lock-bar__button"[^>]*>/.exec(html)?.[0] ?? "").includes("disabled"),
    ).toBe(true);
    // The refreshed run state is PAUSE-capable, so PAUSE is re-enabled.
    expect(
      (/<button class="lock-bar__pause"[^>]*>/.exec(html)?.[0] ?? "").includes("disabled"),
    ).toBe(false);
  });

  it("renders a gated lock bar for a blocked readiness (with reasons listed)", () => {
    const html = renderToStaticMarkup(
      <CanvasSurfaces
        run={RUN}
        trace={TRACE}
        readiness={{ ...READINESS, blockers: ["PROVIDER-B"], ready: false }}
        contract={CONTRACT}
        busy={false}
        error={null}
        staleRefreshed={false}
        onLock={vi.fn()}
        onPause={vi.fn()}
        onResume={vi.fn()}
      />,
    );
    expect(html).toContain("1 blocker");
    expect(html).toContain("PROVIDER-B");
    expect(
      (/<button class="lock-bar__button"[^>]*>/.exec(html)?.[0] ?? "").includes("disabled"),
    ).toBe(true);
  });

  it("surfaces an initial load failure before any projection is available", () => {
    const html = renderToStaticMarkup(
      <CanvasSurfaces
        run={null}
        trace={null}
        readiness={null}
        contract={null}
        busy={false}
        error="failed to load run"
        staleRefreshed={false}
        onLock={vi.fn()}
        onPause={vi.fn()}
        onResume={vi.fn()}
      />,
    );
    expect(html).toContain("canvas-shell__error");
    expect(html).toContain('role="alert"');
    expect(html).toContain("failed to load run");
  });

  it("renders a distinct trace error without hiding the LOCK surface", () => {
    const html = renderToStaticMarkup(
      <CanvasSurfaces
        run={RUN}
        trace={null}
        readiness={READINESS}
        contract={CONTRACT}
        busy={false}
        error={null}
        staleRefreshed={false}
        traceError="the trace graph could not be loaded: trace service down"
        onLock={vi.fn()}
        onPause={vi.fn()}
        onResume={vi.fn()}
      />,
    );
    expect(html).toContain("canvas-shell__trace-error");
    expect(html).toContain("trace service down");
    expect(html).not.toContain("Trace graph is being loaded");
    expect(html).toContain('data-ready="true"');
    expect(html).toContain("LOCK &amp; BUILD");
  });
});
