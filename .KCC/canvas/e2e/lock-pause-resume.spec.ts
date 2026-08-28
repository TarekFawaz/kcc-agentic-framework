/**
 * Deterministic H2 -> LOCK -> PAUSE -> RESUME end-to-end spec.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 5 (Design Spec v1.2
 * sections 9.6 / 15 / 16.1; plan Global Constraints on stale-state
 * discipline).  The first entry of the discovery-canvas E2E suite, run
 * against the fixture-backed deterministic control plane
 * (:mod:`./fixture-server`), which is seeded from
 * ``.KCC/runtime/tests/fixtures/canvas_ready_run.json`` — a ready
 * CONTRACT_REVIEW run (zero readiness blockers, current evidence,
 * lockable two-tier Build Contract, canonical Tier-1 hash, clickable
 * prototype reference).
 *
 * Scenario:
 *
 * 1. **Ready surface** — the canvas shows the CONTRACT_REVIEW run, the
 *    discovery timeline marks CONTRACT_REVIEW, readiness is READY with
 *    0 blocker(s) and current evidence, the Build Contract panel shows
 *    the canonical Tier-1 hash the canvas proves at LOCK, and the
 *    clickable prototype is embedded with EXACTLY
 *    ``allow-forms allow-scripts`` (never same-origin).
 * 2. **H2 — prototype walkthrough** — the user walks the prototype's
 *    primary journey inside the sandboxed frame (entry screen -> upload
 *    -> result), i.e. the H2 validation step of the approved autobuild
 *    sequence; LOCK is enabled while the walkthrough surface is on
 *    screen (no extra confirmation gates, Plan-02 ruling R10).
 * 3. **LOCK** — the user presses LOCK & BUILD; the deterministic server
 *    moves the run CONTRACT_REVIEW -> BUILDING (the controller-collapsed
 *    transition the canvas sees: LOCKED then straight into build); the
 *    LOCK bar re-gates: LOCK disabled, PAUSE enabled, RESUME disabled,
 *    the run has left the discovery timeline.
 * 4. **No approval dialog after LOCK** — the post-lock behavioral rule
 *    (spec 16.1: no routine questions, no approval prompts, progress is
 *    telemetry): no ``role="dialog"``, no text matching
 *    ``approve milestone`` / ``continue build``, and no native dialog
 *    (``confirm``/``alert``) fired at all.
 * 5. **PAUSE / RESUME** — PAUSE moves BUILDING -> PAUSED (RESUME is the
 *    only enabled command), RESUME moves PAUSED -> BUILDING again.
 *
 * Determinism: the server keeps a single in-memory state machine, the
 * fixture's authoring instant is shifted to server start so evidence is
 * current (same ages as authored), and the scenario asserts exactly one
 * LOCK was posted (the client never auto-retries a command) and that
 * the served Tier-1 hash is the one the canvas proved.
 */
import { expect, test } from "@playwright/test";

import { startFixtureServer, type FixtureServer } from "./fixture-server";

test.describe("autobuild canvas lock/pause/resume", () => {
  let server: FixtureServer;

  test.beforeAll(async () => {
    server = await startFixtureServer();
  });

  test.afterAll(async () => {
    await server.close();
  });

  test("H2 walkthrough, then LOCK & BUILD with no approval dialog, then PAUSE and RESUME", async ({
    page,
  }) => {
    const dialogs: string[] = [];
    const pageErrors: string[] = [];
    page.on("dialog", (dialog) => {
      dialogs.push(dialog.message());
      void dialog.dismiss();
    });
    page.on("pageerror", (error) => pageErrors.push(error.message));

    await page.goto(server.baseUrl);

    // -- ready CONTRACT_REVIEW surface -----------------------------------
    await expect(
      page.getByRole("heading", { name: "Autobuild Discovery Canvas" }),
    ).toBeVisible();
    const runLine = page.locator(".canvas-shell__run");
    await expect(runLine).toHaveAttribute("data-run-id", "RUN-001");
    await expect(runLine).toContainText("(CONTRACT_REVIEW)");

    await expect(
      page.locator('li[data-phase="CONTRACT_REVIEW"][aria-current="step"]'),
    ).toBeVisible();

    await expect(page.locator(".readiness-panel__verdict")).toHaveText("READY");
    await expect(page.locator(".readiness-panel__blocker-count")).toHaveText(
      "0 blocker(s)",
    );
    await expect(
      page.locator('.readiness-panel__item[data-status="READY"]'),
    ).toHaveCount(2);
    await expect(
      page.locator('.readiness-panel__item[data-evidence-current="true"]'),
    ).toHaveCount(2);

    await expect(page.locator(".contract-panel__tier1-hash")).toHaveText(
      server.tier1Hash,
    );

    const lock = page.locator("button.lock-bar__button");
    const pause = page.locator("button.lock-bar__pause");
    const resume = page.locator("button.lock-bar__resume");
    await expect(lock).toBeEnabled();
    await expect(lock).toHaveText("LOCK & BUILD");
    await expect(pause).toBeDisabled();
    await expect(resume).toBeDisabled();
    await expect(page.locator(".lock-bar__reasons")).toHaveCount(0);

    // -- H2: prototype walkthrough inside the sandboxed frame ------------
    const prototype = page.locator("iframe.prototype-panel__frame");
    await expect(prototype).toHaveAttribute("sandbox", "allow-forms allow-scripts");
    const frame = page.frameLocator("iframe.prototype-panel__frame");
    await expect(frame.getByRole("heading", { name: "Upload analysis" })).toBeVisible();
    await frame.getByRole("button", { name: "Start upload" }).click();
    await expect(frame.getByRole("heading", { name: "Upload in progress" })).toBeVisible();
    await frame.getByRole("button", { name: "Process file" }).click();
    await expect(frame.getByRole("heading", { name: "Analysis summary" })).toBeVisible();

    // -- LOCK & BUILD: CONTRACT_REVIEW -> BUILDING ------------------------
    await lock.click();
    await expect(runLine).toContainText("(BUILDING)");
    await expect(lock).toBeDisabled();
    await expect(pause).toBeEnabled();
    await expect(resume).toBeDisabled();
    await expect(
      page.locator('li[data-phase="CONTRACT_REVIEW"][aria-current="step"]'),
    ).toHaveCount(0);
    expect(server.metrics.lockPosts).toBe(1);
    expect(server.lastLockTier1Hash()).toBe(server.tier1Hash);

    // -- NO approve-milestone / continue-build dialog after LOCK ----------
    expect(server.metrics.h2Posts).toBe(0);
    await expect(page.locator('[role="dialog"]')).toHaveCount(0);
    await expect(page.locator("body")).not.toContainText(
      /approve milestone|continue build/i,
    );
    expect(dialogs).toEqual([]);

    // -- PAUSE: BUILDING -> PAUSED ----------------------------------------
    await pause.click();
    await expect(runLine).toContainText("(PAUSED)");
    await expect(lock).toBeDisabled();
    await expect(pause).toBeDisabled();
    await expect(resume).toBeEnabled();

    // -- RESUME: PAUSED -> BUILDING ---------------------------------------
    await resume.click();
    await expect(runLine).toContainText("(BUILDING)");
    await expect(lock).toBeDisabled();
    await expect(pause).toBeEnabled();
    await expect(resume).toBeDisabled();

    await expect(page.locator('[role="dialog"]')).toHaveCount(0);
    await expect(page.locator("body")).not.toContainText(
      /approve milestone|continue build/i,
    );
    expect(dialogs).toEqual([]);
    expect(pageErrors).toEqual([]);
  });
});
