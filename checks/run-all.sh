#!/usr/bin/env bash
# Gate runner (ground-truth-gates pattern). Exit 1 if any gate fails.
set -u
cd "$(dirname "$0")"

pass=0
fail=0

run_gate() {
  name="$1"
  shift
  if out=$("$@" 2>&1); then
    printf '  PASS  %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$name"
    printf '%s\n' "$out" | tail -n 25 | sed 's/^/        /'
    fail=$((fail + 1))
  fi
}

for gate in */run.sh; do
  [ -e "$gate" ] || continue
  run_gate "$(dirname "$gate")" bash "$gate"
done

[ -e project.sh ] && run_gate project bash -c 'cd .. && bash checks/project.sh'

printf '%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  echo 'GATES RED — do not commit / ship'
  exit 1
fi
echo 'GATES GREEN'