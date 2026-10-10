#!/bin/sh
# Source-contract test: this does not exercise private iOS runtime behavior.
# It verifies that production r_msg_main_raw rejects unconfirmed setup before
# it can enqueue the prepared invocation.
set -eu

SOURCE="$(cd "$(dirname "$0")/../../.." && pwd)/Cyanide/tweaks/remote_objc.m"
export SOURCE
python3 - <<'PY'
import os

source = open(os.environ["SOURCE"], encoding="utf-8").read()
start = source.index("uint64_t r_msg_main_raw(")
end = source.index("uint64_t r_msg_main(", start)
body = source[start:end]

checks = [
    "if (!r_is_objc_ptr(sig) || !r_last_call_ok()) return 0;",
    "if (!r_is_objc_ptr(inv) || !r_last_call_ok()) return 0;",
    "if (!r_last_call_ok() || numArgs < 2 || numArgs > 6)",
    'r_msg2(inv, "retainArguments", 0, 0, 0, 0);',
    'if (!r_last_call_ok()) {\n        r_msg2(inv, "release", 0, 0, 0, 0);',
]
for check in checks:
    if check not in body:
        raise SystemExit(f"missing production contract: {check!r}")

retain = body.index('r_msg2(inv, "retainArguments"')
perform = body.index("r_invoke_on_main_wait", retain)
if retain > perform:
    raise SystemExit("retainArguments check is not before main-thread dispatch")
print("PASS source-contract: slow invocation setup fails closed")
PY
