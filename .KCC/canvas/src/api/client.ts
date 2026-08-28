/**
 * Typed stale-safe client for the autobuild discovery control-plane API.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 2 (Design Spec v1.2;
 * plan Global Constraints on stale-state discipline):
 *
 * * ``StaleProjectionError`` is raised for EVERY HTTP 409 — both
 *   ``STALE_STATE`` and ``STALE_CONTRACT`` — and carries the server's
 *   error code and detail;
 * * the client NEVER auto-retries LOCK: every command is a single-shot
 *   request and a stale LOCK fails fast;
 * * GETs are typed projections (``/run`` ``/trace`` ``/readiness``
 *   ``/contract``); command helpers POST the command body
 *   (``expected_state``, plus ``tier1_hash`` for LOCK).
 *
 * Non-409 failures surface as :class:`ApiError` so the two cases are
 * distinguishable by the caller (the canvas refetches projections on a
 * stale projection; it never treats a stale LOCK as recoverable).
 */
import type {
  ApiErrorPayload,
  CommandRequest,
  CommandResult,
  ContractProjection,
  LockRequest,
  ReadinessProjection,
  RunProjection,
  TraceProjection,
} from "../types";

/** A response the control-plane API answered with HTTP 409 (stale state/projection). */
export class StaleProjectionError extends Error {
  readonly status: number;
  readonly error: string;
  readonly detail: string;

  constructor(status: number, error: string, detail: string) {
    super(`stale projection: ${error}${detail === "" ? "" : ` - ${detail}`}`);
    this.name = "StaleProjectionError";
    this.status = status;
    this.error = error;
    this.detail = detail;
  }
}

/** Any non-409 failure response from the control-plane API. */
export class ApiError extends Error {
  readonly status: number;
  readonly error: string;
  readonly detail: string;

  constructor(status: number, error: string, detail: string) {
    super(`${status} ${error}${detail === "" ? "" : ` - ${detail}`}`);
    this.name = "ApiError";
    this.status = status;
    this.error = error;
    this.detail = detail;
  }
}

const DEFAULT_BASE_URL: string = import.meta.env.VITE_CONTROL_PLANE_URL ?? "/api";

/**
 * Typed facade over the discovery API routes.
 *
 * There is no retry logic anywhere in this class: project through the
 * control plane, fail fast on 409, and let the caller refetch fresh
 * projections (the canvas never re-issues a stale LOCK).
 */
export class CanvasClient {
  private readonly baseUrl: string;
  private readonly fetchImpl: typeof fetch;

  constructor(baseUrl: string = DEFAULT_BASE_URL, fetchImpl: typeof fetch = fetch) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.fetchImpl = fetchImpl;
  }

  getRun(): Promise<RunProjection> {
    return this.get<RunProjection>("/run");
  }

  getTrace(): Promise<TraceProjection> {
    return this.get<TraceProjection>("/trace");
  }

  getReadiness(): Promise<ReadinessProjection> {
    return this.get<ReadinessProjection>("/readiness");
  }

  getContract(): Promise<ContractProjection> {
    return this.get<ContractProjection>("/contract");
  }

  confirmH1(request: CommandRequest): Promise<CommandResult> {
    return this.post<CommandResult>("/h1", request);
  }

  confirmH2(request: CommandRequest): Promise<CommandResult> {
    return this.post<CommandResult>("/h2", request);
  }

  lock(request: LockRequest): Promise<CommandResult> {
    return this.post<CommandResult>("/lock", request);
  }

  pause(request: CommandRequest): Promise<CommandResult> {
    return this.post<CommandResult>("/pause", request);
  }

  resume(request: CommandRequest): Promise<CommandResult> {
    return this.post<CommandResult>("/resume", request);
  }

  private get<T>(path: string): Promise<T> {
    return this.fetchJson<T>(path, {
      method: "GET",
      headers: { Accept: "application/json" },
    });
  }

  private post<T>(path: string, body: unknown): Promise<T> {
    return this.fetchJson<T>(path, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(body),
    });
  }

  /** Single-shot request: a stale projection raises, never retries. */
  private async fetchJson<T>(path: string, init: RequestInit): Promise<T> {
    const response = await this.fetchImpl(`${this.baseUrl}${path}`, init);
    if (response.status === 409) {
      const payload = await this.readErrorPayload(response);
      throw new StaleProjectionError(response.status, payload.error, payload.detail);
    }
    if (!response.ok) {
      const payload = await this.readErrorPayload(response);
      throw new ApiError(response.status, payload.error, payload.detail);
    }
    return (await response.json()) as T;
  }

  private async readErrorPayload(response: Response): Promise<ApiErrorPayload> {
    try {
      const body: unknown = await response.json();
      if (typeof body === "object" && body !== null) {
        const record = body as Record<string, unknown>;
        const error = record["error"];
        const detail = record["detail"];
        return {
          error: typeof error === "string" ? error : "UNKNOWN_ERROR",
          detail: typeof detail === "string" ? detail : "",
        };
      }
    } catch {
      // The error body was not JSON: fall through to the defaults.
    }
    return { error: "UNKNOWN_ERROR", detail: "" };
  }
}

/** Shared client instance (base URL from VITE_CONTROL_PLANE_URL, default /api). */
export const api: CanvasClient = new CanvasClient();
