/**
 * Behavioral tests for the typed stale-safe control-plane canvas client.
 *
 * Written first (strict TDD red phase) against the external behavior
 * contract of :file:`src/api/client.ts` (KCC x Superpowers Hybrid
 * Framework Plan 06, Task 2; Design Spec v1.2; plan Global Constraints
 * on stale-state discipline):
 *
 * * every HTTP 409 (``STALE_STATE`` / ``STALE_CONTRACT``) raises
 *   :class:`StaleProjectionError`;
 * * LOCK is NEVER auto-retried — a stale LOCK fails fast with one
 *   request;
 * * GETs are typed projections and commands are typed helpers that POST
 *   the command body (``expected_state``, plus ``tier1_hash`` for LOCK).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { LockRequest, RunProjection } from "../types";
import { ApiError, CanvasClient, StaleProjectionError } from "./client";

const TIER1_HASH = "a".repeat(64);

function lockRequest(): LockRequest {
  return { expected_state: "CONTRACT_REVIEW", tier1_hash: TIER1_HASH };
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function staleProjectionResponse(error: string, detail: string): Response {
  return jsonResponse(409, { error, detail });
}

const RUN: RunProjection = {
  run_id: "RUN-001",
  title: "canvas test run",
  created_at: "2026-01-02T12:00:00Z",
  state: "CONTRACT_REVIEW",
  contract_hash: null,
};

describe("CanvasClient stale-state discipline", () => {
  let fetchMock: ReturnType<typeof vi.fn<typeof fetch>>;
  let client: CanvasClient;

  beforeEach(() => {
    fetchMock = vi.fn<typeof fetch>();
    client = new CanvasClient("/api", fetchMock);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("raises StaleProjectionError when LOCK responds 409 STALE_CONTRACT", async () => {
    fetchMock.mockResolvedValue(
      staleProjectionResponse("STALE_CONTRACT", "tier1_hash does not match"),
    );

    const error = await client.lock(lockRequest()).catch((cause: unknown) => cause);

    expect(error).toBeInstanceOf(StaleProjectionError);
    const stale = error as StaleProjectionError;
    expect(stale.status).toBe(409);
    expect(stale.error).toBe("STALE_CONTRACT");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("raises StaleProjectionError when LOCK responds 409 STALE_STATE", async () => {
    fetchMock.mockResolvedValue(
      staleProjectionResponse("STALE_STATE", "run is BUILDING, expected CONTRACT_REVIEW"),
    );

    const error = await client.lock(lockRequest()).catch((cause: unknown) => cause);

    expect(error).toBeInstanceOf(StaleProjectionError);
    const stale = error as StaleProjectionError;
    expect(stale.status).toBe(409);
    expect(stale.error).toBe("STALE_STATE");
    expect(stale.detail).toContain("expected CONTRACT_REVIEW");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("never auto-retries LOCK when the server answers 409", async () => {
    vi.useFakeTimers();
    fetchMock.mockResolvedValue(
      staleProjectionResponse("STALE_CONTRACT", "tier1_hash does not match"),
    );

    const lock = client.lock(lockRequest());
    void lock.catch(() => undefined);
    await vi.runAllTimersAsync();

    await expect(lock).rejects.toBeInstanceOf(StaleProjectionError);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit | undefined];
    expect(url).toBe("/api/lock");
    expect(init?.method).toBe("POST");
    expect(JSON.parse(String(init?.body))).toEqual({
      expected_state: "CONTRACT_REVIEW",
      tier1_hash: TIER1_HASH,
    });
  });

  it("maps HTTP 409 on a typed GET to StaleProjectionError too", async () => {
    fetchMock.mockResolvedValue(
      staleProjectionResponse("STALE_STATE", "run record changed"),
    );

    const error = await client.getRun().catch((cause: unknown) => cause);

    expect(error).toBeInstanceOf(StaleProjectionError);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("resolves a successful LOCK to the typed CommandResult in one request", async () => {
    fetchMock.mockResolvedValue(
      jsonResponse(200, {
        command: "lock",
        accepted: true,
        run: { ...RUN, state: "LOCKED" },
      }),
    );

    const result = await client.lock(lockRequest());

    expect(result.accepted).toBe(true);
    expect(result.command).toBe("lock");
    expect(result.run.state).toBe("LOCKED");
    expect(result.run.run_id).toBe("RUN-001");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("mutates the run through the typed command helpers (h1/h2/pause/resume)", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse(200, { command: "h1", run: RUN }));
    fetchMock.mockResolvedValueOnce(jsonResponse(200, { command: "pause", run: RUN }));

    const h1 = await client.confirmH1({ expected_state: "DISCOVERY" });
    const pause = await client.pause({ expected_state: "BUILDING" });

    expect(h1.command).toBe("h1");
    expect(pause.command).toBe("pause");
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const pauseCall = fetchMock.mock.calls[1] as [string, RequestInit | undefined];
    expect(pauseCall[0]).toBe("/api/pause");
    expect(JSON.parse(String(pauseCall[1]?.body))).toEqual({ expected_state: "BUILDING" });
  });

  it("raises ApiError (not StaleProjectionError) for a non-409 failure", async () => {
    fetchMock.mockResolvedValue(jsonResponse(400, { error: "INVALID_REQUEST", detail: "bad" }));

    const error = await client.getContract().catch((cause: unknown) => cause);

    expect(error).toBeInstanceOf(ApiError);
    const apiError = error as ApiError;
    expect(apiError.status).toBe(400);
    expect(apiError.error).toBe("INVALID_REQUEST");
  });
});
