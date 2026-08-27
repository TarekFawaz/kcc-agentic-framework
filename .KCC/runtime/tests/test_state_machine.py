import pytest
from kcc_autobuild.models import LifecycleState as S
from kcc_autobuild.state_machine import InvalidTransition, assert_transition


def test_happy_path_lock_to_build():
    assert_transition(S.CONTRACT_REVIEW, S.LOCKED)
    assert_transition(S.LOCKED, S.BUILDING)


def test_external_wait_acceptance_path():
    assert_transition(S.DEPLOYED, S.EXTERNAL_WAIT)
    assert_transition(S.EXTERNAL_WAIT, S.PRODUCTION_VALIDATED)
    assert_transition(S.EXTERNAL_WAIT, S.BUILDING)


def test_pause_and_resume_are_explicit():
    assert_transition(S.BUILDING, S.PAUSED)
    assert_transition(S.PAUSED, S.RESUMING)


def test_invalid_skip_to_done_fails_closed():
    with pytest.raises(InvalidTransition):
        assert_transition(S.BUILDING, S.DONE)
