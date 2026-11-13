#!/usr/bin/env bash
# Builds a tiny probe project against real ArmDot to prove the build/ files obfuscate and guard the license.
# Opt-in because it restores packages from nuget.org and takes about a minute.
# Usage: ARMDOT_BUILD_TEST=1 ./tests/test-armdot-build.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if ! command -v dotnet >/dev/null 2>&1; then echo "SKIP: dotnet is not on PATH"; exit 0; fi
if [ -z "${ARMDOT_BUILD_TEST:-}" ]; then echo "SKIP: set ARMDOT_BUILD_TEST=1 to build against nuget.org"; exit 0; fi

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Build in a temp copy so the repo tree stays clean. The fixture imports ../../../build/..., so mirror that depth.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tests/fixtures"
cp -R tests/fixtures/armdot-probe "$WORK/tests/fixtures/"
cp -R build "$WORK/build"
cd "$WORK/tests/fixtures/armdot-probe" || exit 1

echo "armdot build:"

t "a plain build (DuploObfuscate unset) ships the ArmDot.Client reference and both attributes"
if dotnet build -c Release -o out-plain -nologo -v q >/dev/null 2>&1 \
  && strings -n 4 out-plain/Probe.dll | grep -q 'ObfuscateControlFlowAttribute' \
  && strings -n 4 out-plain/Probe.dll | grep -q 'VirtualizeCodeAttribute'; then ok; else bad "plain build"; fi

t "an obfuscated demo build (DuploObfuscate=true, no license, warnings allowed) drops the attributes"
if dotnet build -c Release -o out-obf -nologo -v q -p:DuploObfuscate=true -p:ArmDotLicenseFile= \
  -p:ArmDotTreatWarningsAsErrors=false >/dev/null 2>&1 \
  && ! strings -n 4 out-obf/Probe.dll | grep -q 'ObfuscateControlFlowAttribute' \
  && ! strings -n 4 out-obf/Probe.dll | grep -q 'VirtualizeCodeAttribute'; then ok; else bad "obfuscated build"; fi

t "a second pass logs that the assembly is already obfuscated"
if dotnet build -c Release -o out-obf2 -nologo -v d -p:DuploObfuscate=true -p:ArmDotLicenseFile= \
  -p:ArmDotTreatWarningsAsErrors=false 2>&1 | grep -q 'already obfuscated'; then ok; else bad "second pass"; fi

t "with warnings as errors, no license fails on ARMDOT0002 and an unreadable license path fails too"
rm -rf obj bin
out=$(dotnet build -c Release -o out-guard -nologo -v q -p:DuploObfuscate=true -p:ArmDotLicenseFile= 2>&1)
rc=$?
rm -rf obj bin
out2=$(dotnet build -c Release -o out-guard2 -nologo -v q -p:DuploObfuscate=true -p:ArmDotLicenseFile=/nonexistent 2>&1)
rc2=$?
if [ "$rc" -ne 0 ] && grep -q 'treated as an error: warning ARMDOT0002' <<<"$out" \
  && [ "$rc2" -ne 0 ] && [ ! -e out-guard2/Probe.dll ]; then ok
else bad "guard (rc=$rc rc2=$rc2): $(head -c 600 <<<"$out")"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
