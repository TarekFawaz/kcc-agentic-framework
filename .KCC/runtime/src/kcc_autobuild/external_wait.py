"""EXTERNAL_WAIT polling and rejection routing for external review waits.

Plan 05, Task 5 (EXTERNAL_WAIT polling / rejection routing): external
waiting states such as app-store review or third-party manual approval
are modeled as external waits rather than falsely reported as completed
autonomous work (spec 20.2), policy/identity/account blockers that the
user must resolve are batched into a single consolidated decision request
(spec 18.1), and a user-rejected review either sends the run back to the
build (non-Tier-1 impact) or halts it for re-contracting (Tier-1 impact).

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_external_wait.py`:

- :class:`ExternalReview` is one review outcome value: ``status``
  (``APPROVED`` / ``REJECTED`` / ``PENDING``), ``impacts_tier1`` and the
  ``reasons``. It validates itself fail closed: reasons must be
  non-blank, unique strings, and a Tier-1 rejection without at least one
  reason is rejected at construction (a HALTED verdict must always carry
  a batched decision request, spec 18.1).
- :func:`route_external_review` is the pure routing function (no I/O, no
  wall clock, byte-identical output for identical input): APPROVED =>
  ``PRODUCTION_VALIDATED`` (the wait resolves to the completed
  production validation, spec 20.2); REJECTED without Tier-1 impact =>
  ``BUILDING`` (the run resumes within the locked contract); REJECTED
  with Tier-1 impact => ``HALTED`` with the review reasons carried as
  the consolidated batch; any other status (a still-pending review) =>
  ``EXTERNAL_WAIT`` (the run stays on the external wait of spec 20.2).
- :class:`ExternalWaitState` is the durable per-run wait state: the
  review outcome, when the wait began, the next poll time
  (``next_check_at``) and the ``bug_attempts`` count captured when the
  wait began -- the state kept on disk, never in conversational memory
  (spec 22).
- :class:`ExternalWaitStore` persists exactly that state through
  :class:`~kcc_autobuild.store.RunStore` SQLite (one row per run in the
  ``external_wait_state`` table created by the repo migration
  :file:`.KCC/runtime/migrations/003_external_wait_state.sql`, schema
  version 3; the run row must exist -- a wait state for an unknown run
  is a caller bug and fails closed on the foreign key).
- :class:`ExternalWaitCoordinator` is the combined route + persist
  action: ``record_review`` persists the new state -- ``next_check_at``
  advanced by the poll interval while the review is still pending, and
  cleared once the wait resolves -- and **never increments BUG
  attempts**: elapsed waiting time is not a failure, so the count
  captured when the wait began is preserved across every poll, and is
  recaptured only when the run enters a fresh wait. Entering a fresh
  wait requires the caller's authoritative BUG attempt count (fail
  closed -- a silent 0 could launder attempts), the poll schedule is
  monotonic (a poll before the persisted ``next_check_at`` is rejected),
  and ``run_id`` must be canonical run identity (``RUN_ID_PATTERN``).
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from enum import Enum
from pathlib import Path

from pydantic import Field, ValidationInfo, field_validator, model_validator

from kcc_autobuild.models import RUN_ID_PATTERN, LifecycleState, StrictModel
from kcc_autobuild.store import RunStore

DEFAULT_POLL_INTERVAL = timedelta(hours=1)
"""Default delay between checks of a pending external review."""

MIGRATION_003 = (
    Path(__file__).resolve().parents[2] / "migrations" / "003_external_wait_state.sql"
)
"""Migration creating ``external_wait_state`` on the RunStore database."""


class ReviewStatus(str, Enum):
    """Outcome of the external review a paused run is waiting on.

    ``APPROVED`` resolves the wait to production validation; ``REJECTED``
    sends the run back to the build when the locked Tier-1 contract is
    unaffected and halts it (with batched reasons) when it is impacted;
    ``PENDING`` is the still-outstanding case that keeps the run on the
    external wait of spec 20.2.
    """

    APPROVED = "APPROVED"
    REJECTED = "REJECTED"
    PENDING = "PENDING"


def _require_run_id(value: object, name: str = "run_id") -> str:
    """Require canonical run identity (``RUN_ID_PATTERN``).

    A run id must start with ``RUN-`` followed by an alphanumeric
    character; separators and traversal paths are rejected before any
    coordination artifact exists (the same identity rule every other
    runtime model enforces).
    """
    if not isinstance(value, str):
        raise ValueError(
            f"{name} must be a string, got {type(value).__name__}"
        )
    if re.fullmatch(RUN_ID_PATTERN, value) is None:
        raise ValueError(f"{name} must match {RUN_ID_PATTERN}, got {value!r}")
    return value


def _require_aware(value: datetime | None, name: str) -> datetime | None:
    """Require timezone-aware timestamps (R7: unambiguous UTC discipline)."""
    if value is not None and (value.tzinfo is None or value.utcoffset() is None):
        raise ValueError(f"{name} must be timezone-aware")
    return value


def _as_utc(value: datetime, name: str) -> datetime:
    """Require timezone-aware input and normalize to UTC (R7 discipline)."""
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{name} must be timezone-aware")
    return value.astimezone(timezone.utc)


def _unique_strings(value: list[str], name: str) -> list[str]:
    for entry in value:
        if not isinstance(entry, str) or not entry.strip():
            raise ValueError(f"{name} entries must be non-blank strings")
    if len(value) != len(set(value)):
        raise ValueError(f"{name} must not contain duplicates")
    return value


class ExternalReview(StrictModel):
    """One external review outcome of a waiting run (spec 18.1, 20.2).

    ``status`` is the review decision, ``impacts_tier1`` whether the
    rejection would revise a locked Tier-1 invariant, and ``reasons`` the
    review's findings. Fail closed: a Tier-1 rejection without reasons is
    rejected at construction because it cannot be batched into the single
    consolidated decision request of spec 18.1 -- an empty halt batch is
    never produced.
    """

    status: ReviewStatus
    impacts_tier1: bool = False
    reasons: list[str] = Field(default_factory=list)

    @field_validator("reasons")
    @classmethod
    def _reasons_not_blank_or_duplicate(cls, value: list[str]) -> list[str]:
        return _unique_strings(value, "reasons")

    @model_validator(mode="after")
    def _tier1_rejection_batches_reasons(self) -> ExternalReview:
        if (
            self.status is ReviewStatus.REJECTED
            and self.impacts_tier1
            and not self.reasons
        ):
            raise ValueError(
                "a Tier-1 rejection must carry at least one reason so the "
                "consolidated decision request can be batched (spec 18.1)"
            )
        return self


class ExternalWaitVerdict(StrictModel):
    """Routing verdict for one review outcome.

    ``route`` is the lifecycle state the wait resolves to
    (``PRODUCTION_VALIDATED`` / ``BUILDING`` / ``HALTED`` /
    ``EXTERNAL_WAIT``); ``batched_reasons`` carries the consolidated
    decision request exactly when the run halts (spec 18.1) and is empty
    on every other route -- a HALTED verdict always shows the user why,
    and no other route pretends to.
    """

    route: LifecycleState
    batched_reasons: list[str] = Field(default_factory=list)

    @field_validator("batched_reasons")
    @classmethod
    def _batched_reasons_not_blank_or_duplicate(
        cls, value: list[str]
    ) -> list[str]:
        return _unique_strings(value, "batched_reasons")

    @model_validator(mode="after")
    def _halted_carries_the_batch(self) -> ExternalWaitVerdict:
        if self.route is LifecycleState.HALTED and not self.batched_reasons:
            raise ValueError(
                "a HALTED verdict must carry the batched review reasons"
            )
        if self.route is not LifecycleState.HALTED and self.batched_reasons:
            raise ValueError(
                "only a HALTED verdict carries batched reasons "
                f"(route is {self.route.value})"
            )
        return self


def route_external_review(review: ExternalReview) -> ExternalWaitVerdict:
    """Route one review outcome to its lifecycle state (pure).

    APPROVED => ``PRODUCTION_VALIDATED``; REJECTED without Tier-1 impact
    => ``BUILDING``; REJECTED with Tier-1 impact => ``HALTED`` carrying
    the review reasons as the consolidated batch; any other status (a
    still-pending review) => ``EXTERNAL_WAIT``. Stateless and
    deterministic: identical review values always yield an identical
    verdict.
    """
    if not isinstance(review, ExternalReview):
        raise TypeError(
            f"review must be an ExternalReview, got {type(review).__name__}"
        )
    if review.status is ReviewStatus.APPROVED:
        return ExternalWaitVerdict(route=LifecycleState.PRODUCTION_VALIDATED)
    if review.status is ReviewStatus.REJECTED:
        if review.impacts_tier1:
            return ExternalWaitVerdict(
                route=LifecycleState.HALTED,
                batched_reasons=list(review.reasons),
            )
        return ExternalWaitVerdict(route=LifecycleState.BUILDING)
    return ExternalWaitVerdict(route=LifecycleState.EXTERNAL_WAIT)


class ExternalWaitState(StrictModel):
    """Durable per-run state of an external review wait (spec 22).

    ``review`` is the recorded outcome; ``waiting_since`` when the
    current wait began; ``next_check_at`` the next poll time stored in
    durable run state (``None`` when no poll is pending -- the wait has
    resolved); ``bug_attempts`` the BUG attempt count captured when the
    wait began, which waiting time never increments.
    """

    run_id: str
    review: ExternalReview
    waiting_since: datetime | None = None
    next_check_at: datetime | None = None
    bug_attempts: int = 0

    @field_validator("run_id")
    @classmethod
    def _run_id_is_canonical_identity(cls, value: str) -> str:
        return _require_run_id(value)

    @field_validator("waiting_since", "next_check_at")
    @classmethod
    def _timestamps_aware(
        cls, value: datetime | None, info: ValidationInfo
    ) -> datetime | None:
        return _require_aware(value, info.field_name)

    @field_validator("bug_attempts")
    @classmethod
    def _bug_attempts_non_negative(cls, value: int) -> int:
        if isinstance(value, bool) or not isinstance(value, int):
            raise TypeError(
                f"bug_attempts must be an int, got {type(value).__name__}"
            )
        if value < 0:
            raise ValueError(f"bug_attempts must not be negative, got {value}")
        return value


class ExternalWaitStore:
    """SQLite persistence of the durable external-wait state.

    One row per run in ``external_wait_state`` on the
    :class:`~kcc_autobuild.store.RunStore` database, created by the repo
    migration :file:`.KCC/runtime/migrations/003_external_wait_state.sql`
    (schema version 3) which the store applies idempotently. The row
    references ``runs(run_id)``: persisting wait state for an unknown run
    fails closed on the foreign key instead of silently inventing run
    state.
    """

    def __init__(self, store: RunStore) -> None:
        if not isinstance(store, RunStore):
            raise TypeError(
                f"store must be a RunStore, got {type(store).__name__}"
            )
        self._conn = store.conn
        self._ensure_migrations()

    def _ensure_migrations(self) -> None:
        """Apply migration 003 once (idempotent) on this database.

        Probes the table so a partially migrated database is healed by
        re-running the idempotent script rather than being silently left
        unloadable. A database created before this migration existed
        (table present, no schema_version row) only needs the version
        bookkeeping recorded, so it is recorded explicitly.
        """
        present = self._conn.execute(
            "SELECT name FROM sqlite_master"
            " WHERE type = 'table' AND name = 'external_wait_state'"
        ).fetchone()
        if present is None:
            self._conn.executescript(MIGRATION_003.read_text(encoding="utf-8"))
        else:
            self._conn.execute(
                "INSERT OR IGNORE INTO schema_version(version) VALUES (3)"
            )

    def save(self, state: ExternalWaitState, *, now: datetime | None = None) -> None:
        """Persist one run's wait state (upsert, transactionally).

        ``now`` is the write instant (``updated_at``); a naive timestamp
        is rejected. The run row must exist (foreign key).
        """
        if not isinstance(state, ExternalWaitState):
            raise TypeError(
                f"state must be an ExternalWaitState, got {type(state).__name__}"
            )
        updated_at = _as_utc(
            now if now is not None else datetime.now(timezone.utc), "now"
        )
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            self._conn.execute(
                "INSERT INTO external_wait_state"
                " (run_id, review_json, waiting_since, next_check_at,"
                "  bug_attempts, updated_at)"
                " VALUES (?, ?, ?, ?, ?, ?)"
                " ON CONFLICT(run_id) DO UPDATE SET"
                "  review_json = excluded.review_json,"
                "  waiting_since = excluded.waiting_since,"
                "  next_check_at = excluded.next_check_at,"
                "  bug_attempts = excluded.bug_attempts,"
                "  updated_at = excluded.updated_at",
                (
                    state.run_id,
                    state.review.model_dump_json(),
                    state.waiting_since.isoformat()
                    if state.waiting_since is not None
                    else None,
                    state.next_check_at.isoformat()
                    if state.next_check_at is not None
                    else None,
                    state.bug_attempts,
                    updated_at.isoformat(),
                ),
            )
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise

    def load(self, run_id: str) -> ExternalWaitState | None:
        """The persisted wait state for one run (``None`` if unrecorded)."""
        run_id = _require_run_id(run_id)
        row = self._conn.execute(
            "SELECT run_id, review_json, waiting_since, next_check_at,"
            " bug_attempts FROM external_wait_state WHERE run_id = ?",
            (run_id,),
        ).fetchone()
        if row is None:
            return None
        review_json = row["review_json"]
        if not review_json:
            raise ValueError(
                f"run {run_id!r} has a wait state without a review record"
            )
        return ExternalWaitState(
            run_id=row["run_id"],
            review=ExternalReview.model_validate_json(review_json),
            waiting_since=_parse_utc(row["waiting_since"]),
            next_check_at=_parse_utc(row["next_check_at"]),
            bug_attempts=row["bug_attempts"],
        )


def _parse_utc(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value is not None else None


class ExternalWaitCoordinator:
    """Route review outcomes and persist the durable wait state.

    ``record_review`` is the single action the controller takes when a
    review outcome arrives. Wait bookkeeping is pure and deterministic
    given the handed-in clock (R7):

    * while the review is still pending the run stays on ``EXTERNAL_WAIT``
      and ``next_check_at`` is persisted as ``now + poll_interval``;
    * once the review resolves (approval or rejection) ``next_check_at``
      is cleared -- there is nothing left to poll -- and the verdict
      names the resulting lifecycle state;
    * BUG attempts are captured only when a wait begins and are never
      incremented while waiting: elapsed waiting time is not a failure,
      so a poll always preserves the count recorded at wait entry. The
      count is REQUIRED when a wait begins (fail closed -- a silently
      defaulted 0 could launder attempts that did happen);
    * the poll schedule is monotonic: a poll earlier than the persisted
      ``next_check_at`` is rejected instead of moving the schedule
      backwards.
    """

    def __init__(
        self,
        store: ExternalWaitStore,
        poll_interval: timedelta = DEFAULT_POLL_INTERVAL,
    ) -> None:
        if not isinstance(store, ExternalWaitStore):
            raise TypeError(
                f"store must be an ExternalWaitStore, got {type(store).__name__}"
            )
        if isinstance(poll_interval, bool) or not isinstance(
            poll_interval, timedelta
        ):
            raise TypeError(
                "poll_interval must be a timedelta, "
                f"got {type(poll_interval).__name__}"
            )
        if poll_interval <= timedelta(0):
            raise ValueError(
                f"poll_interval must be positive, got {poll_interval}"
            )
        self._store = store
        self.poll_interval = poll_interval

    def state(self, run_id: str) -> ExternalWaitState | None:
        """The run's persisted wait state (``None`` if unrecorded)."""
        return self._store.load(run_id)

    def record_review(
        self,
        run_id: str,
        review: ExternalReview,
        *,
        now: datetime | None = None,
        bug_attempts: int | None = None,
    ) -> ExternalWaitVerdict:
        """Record one review outcome: route it and persist the wait state.

        Returns the routing verdict; the caller resolves the run's
        lifecycle state from it (``PRODUCTION_VALIDATED`` / ``BUILDING``
        / ``HALTED``) or keeps waiting (``EXTERNAL_WAIT`` with the
        persisted ``next_check_at``).

        Entering a fresh wait requires ``bug_attempts`` (the run's
        authoritative BUG count -- never silently defaulted to 0), and a
        poll of an ongoing wait must not be earlier than the persisted
        ``next_check_at`` (the schedule is monotonic). ``run_id`` must be
        canonical run identity (``RUN_ID_PATTERN``).
        """
        now = _as_utc(
            now if now is not None else datetime.now(timezone.utc), "now"
        )
        verdict = route_external_review(review)
        previous = self._store.load(run_id)
        if verdict.route is LifecycleState.EXTERNAL_WAIT:
            if previous is None or previous.next_check_at is None:
                # Entering (or re-entering) the wait: capture the attempt
                # count now -- elapsed waiting time never increments it.
                if bug_attempts is None:
                    raise ValueError(
                        "bug_attempts is required when a wait begins so "
                        "the BUG count at wait entry is the run's "
                        "authoritative count, never a silent 0"
                    )
                state = ExternalWaitState(
                    run_id=run_id,
                    review=review,
                    waiting_since=now,
                    next_check_at=now + self.poll_interval,
                    bug_attempts=bug_attempts,
                )
            else:
                # A poll of the same wait: preserve the entry bookkeeping.
                if now < previous.next_check_at:
                    raise ValueError(
                        f"poll at {now.isoformat()} is before the persisted "
                        f"next_check_at "
                        f"({previous.next_check_at.isoformat()}); the poll "
                        "schedule must be monotonic"
                    )
                state = ExternalWaitState(
                    run_id=run_id,
                    review=review,
                    waiting_since=previous.waiting_since,
                    next_check_at=now + self.poll_interval,
                    bug_attempts=previous.bug_attempts,
                )
        else:
            # The wait resolved: nothing left to poll.
            state = ExternalWaitState(
                run_id=run_id,
                review=review,
                waiting_since=(
                    previous.waiting_since if previous is not None else None
                ),
                next_check_at=None,
                bug_attempts=previous.bug_attempts if previous is not None else 0,
            )
        self._store.save(state, now=now)
        return verdict
