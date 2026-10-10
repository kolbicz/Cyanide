#!/usr/bin/env python3
"""Source-contract checks for timeout abandonment of JavaScript timers.

These checks do not execute Objective-C, JavaScriptCore, or libdispatch. They
verify the production control-flow contract that can be checked portably:
old generations detach their registry under the lifecycle lock, snapshot
sources, and cancel them from the abandoning thread; timer callbacks and
registration never mutate a registry without that lock.
"""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[3]


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    raise AssertionError(f"unterminated function: {signature}")


def assert_order(body: str, *needles: str) -> None:
    positions = [body.index(needle) for needle in needles]
    assert positions == sorted(positions), f"expected order {needles!r} in {body!r}"


def check_file(filename: str, prefix: str, registry: str, lock: str) -> None:
    source = (ROOT / "Cyanide" / "tweaks" / filename).read_text()
    abandon = function_body(source, f"static void {prefix}_abandon_js_queue_after_timeout")
    assert f"{registry} = nil" in abandon
    assert f"{prefix}_detach_timer_sources_locked(abandonedRegistry)" in abandon
    assert_order(
        abandon,
        "g_" + ("repo_generation++" if prefix == "repotweaks" else "quickloader_generation++"),
        f"{registry} = nil",
        f"{prefix}_detach_timer_sources_locked(abandonedRegistry)",
        "pthread_mutex_unlock",
        f"{prefix}_cancel_timer_sources(abandonedSources)",
    )
    assert "// The generation was invalidated before these sources were cancelled." in abandon

    detach = function_body(source, f"static NSArray *{prefix}_detach_timer_sources_locked")
    assert "removeAllObjects" in detach
    assert "The caller must hold" in source[source.index("// The caller must hold") : source.index("// The caller must hold") + 180]

    register = function_body(source, f"static BOOL {prefix}_register_timer")
    remove = function_body(source, f"static dispatch_source_t {prefix}_remove_timer")
    assert lock in register and "timers[timerID] = timer" in register
    assert lock in remove and "removeObjectForKey" in remove

    run = function_body(source, f"bool {prefix}_run_" + ("isolated_js" if prefix == "repotweaks" else "js_string"))
    assert f"{prefix}_register_timer" in run
    assert "dispatch_resume(timer);" in run
    assert "dispatch_source_cancel(timer);" in run
    # Outside the registration/removal helpers, callbacks must not directly
    # touch NSMutableDictionary.
    callback_direct_access = re.findall(r"timers\[@\(tId\)\]|\[timers removeObjectForKey", run)
    assert not callback_direct_access, callback_direct_access


def main() -> int:
    check_file(
        "RepoTweaks.m",
        "repotweaks",
        "g_repo_timers_registry",
        "g_repo_queue_lock",
    )
    check_file(
        "QuickLoader.m",
        "quickloader",
        "g_quickloader_timers",
        "g_quickloader_queue_lock",
    )
    print("source-contract checks passed for RepoTweaks.m and QuickLoader.m")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ValueError) as error:
        print(f"source-contract check failed: {error}", file=sys.stderr)
        raise
