#!/bin/sh
# Source-contract test: this does not exercise private iOS runtime behavior.
# It verifies production helpers reject failed retains and only compensate a
# retain when RemoteCall reported definite completion.
set -eu

SOURCE="$(cd "$(dirname "$0")/../../.." && pwd)/Cyanide/tweaks/remote_objc.m"
export SOURCE
python3 - <<'PY'
import os

source = open(os.environ["SOURCE"], encoding="utf-8").read()

def body(name, next_name):
    start = source.index(name)
    end = source.index(next_name, start)
    return source[start:end]

retain = body("static uint64_t r_retain_checked(", "static uint64_t r_msg_retained_return(")
if "bool completed = r_last_call_ok();" not in retain:
    raise SystemExit("retain helper does not capture completion status")
if "if (!completed || !r_is_objc_ptr(retained)) return 0;" not in retain:
    raise SystemExit("retain helper does not fail closed")

returned = body("static uint64_t r_msg_retained_return(", "uint64_t r_msg2(")
if "if (!r_last_call_ok() || !r_is_objc_ptr(ret)) return 0;" not in returned:
    raise SystemExit("retained return helper accepts an unconfirmed fetch")
if "if (retainCompleted)" not in returned:
    raise SystemExit("retained return helper lacks status-aware compensation")

main_retained = body("uint64_t r_msg2_main_retained(", "void r_release(")
if "if (!r_last_main_ok() || !r_is_objc_ptr(value)) return 0;" not in main_retained:
    raise SystemExit("main retained helper accepts an unknown main result")
if "uint64_t retained = r_retain_checked(value, &retainCompleted);" not in main_retained:
    raise SystemExit("main retained helper does not use checked retain")

invocation = body("uint64_t r_invocation_retained(", "bool r_invocation_invoke_main(")
if "uint64_t retained = r_retain_checked(inv, &retainCompleted);" not in invocation:
    raise SystemExit("invocation helper does not use checked retain")
if "if (retainCompleted)" not in invocation:
    raise SystemExit("invocation helper does not balance definite retain ownership")
print("PASS source-contract: retained helpers fail closed")
PY
