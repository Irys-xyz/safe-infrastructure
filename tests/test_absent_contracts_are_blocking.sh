# expect-fail-against-base: yes
#
# verify_deployments.py's own docstring says of the must-be-absent addresses: "If a proxy
# factory ever appears here WITHOUT its matching singleton, the create-Safe flow could deploy a
# proxy pointing at codeless code -- a Safe that is bricked, with anything sent to it
# unrecoverable. Treat a hit as a blocker." The code recorded a hit as a warning and exited 0,
# under a line beginning "PASS:". An RPC error on those addresses was a warning too, so an
# endpoint that simply refused the query satisfied the check by saying nothing.
#
# The script is the documented pre-deploy gate, so what is asserted here is its exit status.

need_cmd python3

run_case() {   # $1 = python expression for the code at the must-be-absent addresses
  python3 - "$SUT" "$1" <<'PY'
import importlib.util, io, sys, contextlib
spec = importlib.util.spec_from_file_location('vd', sys.argv[1] + '/scripts/verify_deployments.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# Narrow the run to the must-be-absent set: the present-contract half needs real bytecode whose
# keccak matches, which cannot be fabricated, and is not what is under test here.
m.MUST_BE_PRESENT = {}
m.rpc = lambda url, method, params: hex(m.CHAIN_ID)
answer = eval(sys.argv[2])          # noqa: S307 - test fixture, not input
m.get_code_many = lambda url, addrs: {a: answer for a in addrs}

sys.argv = ['verify_deployments.py', '--rpc', 'http://stub']
with contextlib.redirect_stdout(io.StringIO()) as out:
    rc = m.main()
sys.stdout.write(out.getvalue())
sys.exit(rc)
PY
}

# The expected state of the chain: those addresses hold no code.
assert_status "must-be-absent addresses really absent -> exit 0" 0 run_case "'0x'"
assert_contains "and reports a pass" "PASS" "$OUT"

# The state the check exists to detect.
assert_status "an older Safe version deployed there -> exit 1" 1 run_case "'0x60806040'"
assert_contains "and refuses the deploy" "do not deploy" "$OUT"

# An endpoint that will not answer for those addresses is not evidence of absence.
assert_status "an RPC error on those addresses -> exit 1" 1 \
  run_case "RuntimeError('endpoint refuses eth_getCode')"
assert_contains "and refuses the deploy" "do not deploy" "$OUT"
