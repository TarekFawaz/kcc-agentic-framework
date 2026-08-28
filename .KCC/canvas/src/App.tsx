/**
 * Autobuild discovery canvas shell + stale-safe command wiring.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 4 (Design Spec v1.2
 * section 15; plan Global Constraints on stale-state discipline):
 *
 * * the App owns the LOCK surface projections (run / readiness /
 *   contract) and the server-owned trace graph, and renders the
 *   discovery timeline, the trace graph, the prototype / readiness /
 *   contract panels and the gated LOCK bar;
 * * :class:`CanvasSession` is the App's wiring holder: ``load()``
 *   fetches run/readiness/contract and the trace graph independently,
 *   so a trace failure never blanks the LOCK surface (the trace graph
 *   is server-owned display data; the failure is reported in the
 *   graph area instead);
 * * every command (LOCK / PAUSE / RESUME) is single-shot.  When the
 *   control plane answers HTTP 409 (:class:`StaleProjectionError`),
 *   the command FAILS FAST and the session refetches exactly run,
 *   readiness and contract (:func:`fetchProjections`) and publishes
 *   the refreshed projection set with ``staleRefreshed`` set — the
 *   user sees the refreshed Lock surface (with the stale-refresh
 *   notice and the current gating reasons) and presses LOCK again
 *   explicitly.  LOCK is NEVER auto-retried anywhere;
 * * :func:`CanvasSurfaces` is the presentational surface: given the
 *   session state it renders the full canvas, so a refreshed
 *   projection set is exactly what the user sees.
 */
import { useEffect, useMemo, useState } from "react";

import type {
  CommandRequest,
  CommandResult,
  ContractProjection,
  LifecycleState,
  LockRequest,
  ReadinessProjection,
  RunProjection,
  TraceProjection,
} from "./types";
import { api, StaleProjectionError } from "./api/client";
import { ContractPanel } from "./components/ContractPanel";
import { DiscoveryTimeline } from "./components/DiscoveryTimeline";
import {
  LOCK_EXPECTED_STATE,
  LockBar,
  PAUSE_EXPECTED_STATE,
  RESUME_EXPECTED_STATE,
} from "./components/LockBar";
import { PrototypePanel } from "./components/PrototypePanel";
import { ReadinessPanel } from "./components/ReadinessPanel";
import { TraceGraph } from "./components/TraceGraph";

/** The minimal projection surface a canvas source must provide. */
export interface ProjectionSource {
  getRun(): Promise<RunProjection>;
  getReadiness(): Promise<ReadinessProjection>;
  getContract(): Promise<ContractProjection>;
}

/** The minimal command surface the canvas talks to (CanvasClient satisfies it). */
export interface CommandClient extends ProjectionSource {
  getTrace(): Promise<TraceProjection>;
  lock(request: LockRequest): Promise<CommandResult>;
  pause(request: CommandRequest): Promise<CommandResult>;
  resume(request: CommandRequest): Promise<CommandResult>;
}

/** The LOCK surface projections (exactly what a stale command refetches). */
export interface CanvasProjections {
  run: RunProjection;
  readiness: ReadinessProjection;
  contract: ContractProjection;
}

export type CommandOutcome =
  | { kind: "accepted"; result: CommandResult }
  | { kind: "stale"; projections: CanvasProjections }
  | { kind: "error"; message: string };

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

/**
 * Refetch exactly the LOCK surface: run, readiness and contract.
 *
 * The trace graph is server-owned display data and is deliberately
 * NOT part of the refresh — the surface inputs that gate LOCK are the
 * three projections above.
 */
export async function fetchProjections(
  source: ProjectionSource,
): Promise<CanvasProjections> {
  const [run, readiness, contract] = await Promise.all([
    source.getRun(),
    source.getReadiness(),
    source.getContract(),
  ]);
  return { run, readiness, contract };
}

/**
 * Single-shot command execution: fail fast on a stale projection and
 * hand back a refreshed LOCK surface.  There is NO retry path here —
 * a stale command is never re-issued.
 */
async function submitStateChange(
  client: CommandClient,
  send: (request: CommandRequest) => Promise<CommandResult>,
  expectedState: LifecycleState,
): Promise<CommandOutcome> {
  try {
    const result = await send({ expected_state: expectedState });
    return { kind: "accepted", result };
  } catch (cause) {
    if (cause instanceof StaleProjectionError) {
      try {
        const projections = await fetchProjections(client);
        return { kind: "stale", projections };
      } catch (refreshCause) {
        return {
          kind: "error",
          message: `refreshing the command surface failed: ${errorMessage(refreshCause)}`,
        };
      }
    }
    return { kind: "error", message: errorMessage(cause) };
  }
}

/** LOCK & BUILD: prove the canonical Tier-1 hash, fail fast on 409. */
export function submitLock(
  client: CommandClient,
  tier1Hash: string,
): Promise<CommandOutcome> {
  return submitStateChange(
    client,
    (request) =>
      client.lock({
        expected_state: request.expected_state,
        tier1_hash: tier1Hash,
      }),
    LOCK_EXPECTED_STATE,
  );
}

/** PAUSE a BUILDING run. */
export function submitPause(client: CommandClient): Promise<CommandOutcome> {
  return submitStateChange(
    client,
    (request) => client.pause(request),
    PAUSE_EXPECTED_STATE,
  );
}

/** RESUME a PAUSED run. */
export function submitResume(client: CommandClient): Promise<CommandOutcome> {
  return submitStateChange(
    client,
    (request) => client.resume(request),
    RESUME_EXPECTED_STATE,
  );
}

/** The renderable canvas state — exactly what the surface consumes. */
export interface CanvasState {
  run: RunProjection | null;
  trace: TraceProjection | null;
  readiness: ReadinessProjection | null;
  contract: ContractProjection | null;
  busy: boolean;
  error: string | null;
  staleRefreshed: boolean;
  /** Trace-only failure: the graph could not be loaded (LOCK surface stays). */
  traceError: string | null;
}

/** Empty canvas state before the first load completes. */
export const INITIAL_CANVAS_STATE: CanvasState = {
  run: null,
  trace: null,
  readiness: null,
  contract: null,
  busy: false,
  error: null,
  staleRefreshed: false,
  traceError: null,
};

/**
 * The App's wiring holder: load the canvas once, apply single-shot
 * commands, and on a stale projection refetch run/readiness/contract
 * so the user re-reviews the refreshed Lock surface before pressing
 * LOCK again.  Every state change is published through ``onState``
 * (the React setter); ``getState`` exposes the current snapshot for
 * tests and rendering.
 *
 * ``cancel`` invalidates in-flight work when the App unmounts or the
 * client changes (StrictMode effects mount twice in development, so
 * in-flight work is tracked by generation, not by a disposed flag).
 */
export class CanvasSession {
  private state: CanvasState;
  private generation = 0;

  constructor(
    private readonly client: CommandClient,
    private readonly onState: (state: CanvasState) => void,
  ) {
    this.state = { ...INITIAL_CANVAS_STATE };
  }

  /** The current snapshot (also delivered through ``onState`` on every change). */
  getState(): CanvasState {
    return this.state;
  }

  /** Invalidate in-flight work (unmount or client change). */
  cancel(): void {
    this.generation += 1;
  }

  /**
   * Initial canvas load. run/readiness/contract and the trace graph
   * are fetched independently: a trace failure must never blank the
   * LOCK surface — the projections render and the graph area reports
   * the failure.
   */
  async load(): Promise<void> {
    const generation = ++this.generation;
    const [projections, trace] = await Promise.allSettled([
      fetchProjections(this.client),
      this.client.getTrace(),
    ]);
    if (generation !== this.generation) {
      return;
    }
    const next: CanvasState = { ...this.state };
    if (projections.status === "fulfilled") {
      next.run = projections.value.run;
      next.readiness = projections.value.readiness;
      next.contract = projections.value.contract;
    } else {
      next.error = errorMessage(projections.reason);
    }
    if (trace.status === "fulfilled") {
      next.trace = trace.value;
    } else {
      next.traceError = `the trace graph could not be loaded: ${errorMessage(trace.reason)}`;
    }
    this.publish(next);
  }

  /** LOCK & BUILD: single-shot, stale projects refresh, never retried. */
  lock(tier1Hash: string): Promise<void> {
    return this.runCommand(() => submitLock(this.client, tier1Hash));
  }

  /** PAUSE a BUILDING run (single-shot). */
  pause(): Promise<void> {
    return this.runCommand(() => submitPause(this.client));
  }

  /** RESUME a PAUSED run (single-shot). */
  resume(): Promise<void> {
    return this.runCommand(() => submitResume(this.client));
  }

  private async runCommand(submit: () => Promise<CommandOutcome>): Promise<void> {
    const generation = this.generation;
    this.publish({
      ...this.state,
      busy: true,
      error: null,
      staleRefreshed: false,
    });
    const outcome = await submit();
    if (generation !== this.generation) {
      return;
    }
    const next: CanvasState = { ...this.state, busy: false };
    if (outcome.kind === "accepted") {
      next.run = outcome.result.run;
    } else if (outcome.kind === "stale") {
      // The refreshed LOCK surface is what the user sees before
      // pressing LOCK again — never an automatic re-issue.
      next.run = outcome.projections.run;
      next.readiness = outcome.projections.readiness;
      next.contract = outcome.projections.contract;
      next.staleRefreshed = true;
    } else {
      next.error = outcome.message;
    }
    this.publish(next);
  }

  private publish(next: CanvasState): void {
    this.state = next;
    this.onState(next);
  }
}

export interface CanvasSurfacesProps {
  run: RunProjection | null;
  trace: TraceProjection | null;
  readiness: ReadinessProjection | null;
  contract: ContractProjection | null;
  busy: boolean;
  error: string | null;
  staleRefreshed: boolean;
  traceError?: string | null;
  onLock: (tier1Hash: string) => void;
  onPause: () => void;
  onResume: () => void;
}

/**
 * The presentational canvas: given projections (fresh from the control
 * plane), render the timeline, trace graph and the four approval
 * surfaces.  The LOCK bar is gated from the given projections, so a
 * refreshed set is exactly the surface the user re-reviews.
 */
export function CanvasSurfaces(props: CanvasSurfacesProps) {
  const tier1Hash = props.contract?.tier1_hash ?? null;
  return (
    <main className="canvas-shell">
      <h1>Autobuild Discovery Canvas</h1>
      {props.error !== null && props.run === null ? (
        <p className="canvas-shell__error" role="alert">
          {props.error}
        </p>
      ) : null}
      {props.run !== null ? (
        <>
          <p className="canvas-shell__run" data-run-id={props.run.run_id}>
            {props.run.title} ({props.run.state})
          </p>
          <DiscoveryTimeline state={props.run.state} />
        </>
      ) : null}
      {props.trace !== null ? (
        <TraceGraph projection={props.trace} />
      ) : props.traceError !== null ? (
        <p className="canvas-shell__trace-error" role="alert">
          {props.traceError}
        </p>
      ) : (
        <p className="canvas-shell__empty">Trace graph is being loaded…</p>
      )}
      {props.run !== null ? (
        <PrototypePanel
          prototypeRef={props.contract?.tier1?.prototype_ref ?? null}
        />
      ) : null}
      {props.readiness !== null ? (
        <ReadinessPanel readiness={props.readiness} />
      ) : null}
      {props.contract !== null ? (
        <ContractPanel contract={props.contract} />
      ) : null}
      {props.run !== null ? (
        <LockBar
          state={props.run.state}
          readiness={props.readiness}
          tier1Hash={tier1Hash}
          busy={props.busy}
          error={props.error}
          staleRefreshed={props.staleRefreshed}
          onLock={props.onLock}
          onPause={props.onPause}
          onResume={props.onResume}
        />
      ) : null}
    </main>
  );
}

/**
 * The canvas App: a thin component over :class:`CanvasSession` — the
 * session loads the projections and trace graph once, applies
 * single-shot commands, and on a stale projection refetches
 * run/readiness/contract so the user re-reviews the refreshed Lock
 * surface before pressing LOCK again.
 */
export function App({ client = api }: { client?: CommandClient }) {
  const [state, setState] = useState<CanvasState>(INITIAL_CANVAS_STATE);
  const session = useMemo(() => new CanvasSession(client, setState), [client]);

  useEffect(() => {
    void session.load();
    return () => session.cancel();
  }, [session]);

  return (
    <CanvasSurfaces
      run={state.run}
      trace={state.trace}
      readiness={state.readiness}
      contract={state.contract}
      busy={state.busy}
      error={state.error}
      staleRefreshed={state.staleRefreshed}
      traceError={state.traceError}
      onLock={(tier1Hash) => void session.lock(tier1Hash)}
      onPause={() => void session.pause()}
      onResume={() => void session.resume()}
    />
  );
}
