#!/bin/sh
set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if ! command -v ucode >/dev/null 2>&1; then
	echo "ucode is required to run parser tests." >&2
	exit 77
fi

for test in tests/test-parsers.uc tests/test-topology.uc; do
	FIXTURE_ROOT="$PROJECT_ROOT/tests/fixtures" \
		ucode -S -L "$PROJECT_ROOT/root/usr/share/ucode" "$PROJECT_ROOT/$test"
done
