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
 * * every command (LOCK / PAUSE / RESUME) is single-shot.  When the
 *   control plane answers HTTP 409 (:class:`StaleProjectionError`),
 *   :func:`submitLock` / :func:`submitPause` / :func:`submitResume`
 *   FAIL FAST and the App refetches exactly run, readiness and
 *   contract (:func:`fetchProjections`) before re-rendering the
 *   surface — the user sees the refreshed Lock surface (with the
 *   stale-refresh notice and the current gating reasons) and presses
 *   LOCK again explicitly.  LOCK is NEVER auto-retried anywhere;
 * * :func:`CanvasSurfaces` is the presentational surface: given
 *   projections it renders the full canvas, so a refreshed projection
 *   set is exactly what the user sees.
 */
import { useEffect, useState } from "react";

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

export interface CanvasSurfacesProps {
  run: RunProjection | null;
  trace: TraceProjection | null;
  readiness: ReadinessProjection | null;
  contract: ContractProjection | null;
  busy: boolean;
  error: string | null;
  staleRefreshed: boolean;
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
 * The canvas App: loads the projections and trace graph once, applies
 * single-shot commands, and on a stale projection refetches
 * run/readiness/contract so the user re-reviews the refreshed Lock
 * surface before pressing LOCK again.
 */
export function App({ client = api }: { client?: CommandClient }) {
  const [run, setRun] = useState<RunProjection | null>(null);
  const [trace, setTrace] = useState<TraceProjection | null>(null);
  const [readiness, setReadiness] = useState<ReadinessProjection | null>(null);
  const [contract, setContract] = useState<ContractProjection | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [staleRefreshed, setStaleRefreshed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const [projections, traceProjection] = await Promise.all([
          fetchProjections(client),
          client.getTrace(),
        ]);
        if (!cancelled) {
          setRun(projections.run);
          setReadiness(projections.readiness);
          setContract(projections.contract);
          setTrace(traceProjection);
        }
      } catch (cause) {
        if (!cancelled) {
          setError(errorMessage(cause));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [client]);

  function applyOutcome(outcome: CommandOutcome): void {
    if (outcome.kind === "accepted") {
      setRun(outcome.result.run);
    } else if (outcome.kind === "stale") {
      // The refreshed LOCK surface is what the user sees before
      // pressing LOCK again — never an automatic re-issue.
      setRun(outcome.projections.run);
      setReadiness(outcome.projections.readiness);
      setContract(outcome.projections.contract);
      setStaleRefreshed(true);
    } else {
      setError(outcome.message);
    }
  }

  async function handleLock(tier1Hash: string): Promise<void> {
    setBusy(true);
    setError(null);
    setStaleRefreshed(false);
    applyOutcome(await submitLock(client, tier1Hash));
    setBusy(false);
  }

  async function handlePause(): Promise<void> {
    setBusy(true);
    setError(null);
    setStaleRefreshed(false);
    applyOutcome(await submitPause(client));
    setBusy(false);
  }

  async function handleResume(): Promise<void> {
    setBusy(true);
    setError(null);
    setStaleRefreshed(false);
    applyOutcome(await submitResume(client));
    setBusy(false);
  }

  return (
    <CanvasSurfaces
      run={run}
      trace={trace}
      readiness={readiness}
      contract={contract}
      busy={busy}
      error={error}
      staleRefreshed={staleRefreshed}
      onLock={handleLock}
      onPause={handlePause}
      onResume={handleResume}
    />
  );
}
