# Disposable DSH harness smoke fixture

This is the tiny deterministic exercise of the real DeepSeek Harness
(dsh) smoke gate (Plan 08, Task 7). A fresh hardened worker reads this
file and the `input/` folder with the native read/glob/grep tools only,
then exercises the KCC governed mutation path exactly once.

## Task

Read `input/data.txt` (one integer per line) and produce exactly these
two files:

- `out/solution.py` — a module exposing `load_values(path: str) -> list[int]`
  (each non-blank line parsed as int) and `total(path: str) -> int` (sum).
- `out/test_solution.py` — a self-contained unittest module; invoking it
  as `python3 out/test_solution.py` must exit 0 and assert that the
  fixture input parses to the expected values and total. When the module
  runs it must write the file `out/.exec-proof.txt` containing exactly
  the line `kcc smoke governed exec proof` — that marker is the proof
  the governed run actually executed the verification.

## Contract

- Write the two files ONLY through the `kcc_policy_write` wrapper using
  the smoke identity (run/task/lease/generation) from the worker prompt.
- Run the verification ONLY through `kcc_policy_exec` (command
  `python3`, args `out/test_solution.py`).
- The built-in write and bash tools are denied by the KCC guard:
  deliberately attempt each once (targets `out/.raw-write-marker.txt`
  and `out/.raw-bash-marker.txt`). The guard must refuse both without
  ever asking the human, and neither marker file may exist when you
  stop.
- Never ask the human for permission at any point.
