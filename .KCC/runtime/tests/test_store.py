from datetime import datetime, timezone
import pytest
from kcc_autobuild.models import LifecycleState as S, RunRecord
from kcc_autobuild.store import ConcurrentStateChange, RunStore


def test_store_persists_and_transitions(tmp_path):
    store = RunStore(tmp_path / "run.db")
    store.create_run(RunRecord(run_id="RUN-001", title="demo", created_at=datetime.now(timezone.utc)))
    store.transition("RUN-001", expected=S.INTAKE, target=S.DISCOVERY, reason="classified")
    assert store.load_run("RUN-001").state is S.DISCOVERY
    assert [e.kind for e in store.list_events("RUN-001")] == ["run.created", "state.transition"]


def test_transition_rejects_stale_expected_state(tmp_path):
    store = RunStore(tmp_path / "run.db")
    store.create_run(RunRecord(run_id="RUN-001", title="demo", created_at=datetime.now(timezone.utc)))
    with pytest.raises(ConcurrentStateChange):
        store.transition("RUN-001", expected=S.BUILDING, target=S.PAUSED, reason="stale controller")
