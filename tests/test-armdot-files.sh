#!/usr/bin/env bash
# Tests for the ArmDot MSBuild files under build/, which the devkit build imports to obfuscate an extension assembly.
# Usage: ./tests/test-armdot-files.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

PROPS=build/ArmDot.Obfuscation.props
TARGETS=build/ArmDot.Obfuscation.targets
ATTRS=build/ArmDotObfuscationAssemblyInfo.cs
TEMPLATE=build/Directory.Build.targets.template

echo "armdot files:"

t "props pin both ArmDot packages to 2026.6.0 with PrivateAssets=all"
if grep -q '<ArmDotEngineVersion>2026.6.0</ArmDotEngineVersion>' "$PROPS" \
  && grep -q '<ArmDotClientVersion>2026.6.0</ArmDotClientVersion>' "$PROPS" \
  && grep -q 'Include="ArmDot.Engine.MSBuildTasks" Version="\$(ArmDotEngineVersion)" PrivateAssets="all"' "$PROPS" \
  && grep -q 'Include="ArmDot.Client" Version="\$(ArmDotClientVersion)" PrivateAssets="all"' "$PROPS"; then ok; else bad "package pins"; fi

t "assembly info carries exactly ObfuscateControlFlow and VirtualizeCode"
if [ "$(grep -c '^\[assembly: ArmDot.Client\.' "$ATTRS")" = 2 ] \
  && grep -q 'ArmDot.Client.ObfuscateControlFlow\]' "$ATTRS" \
  && grep -q 'ArmDot.Client.VirtualizeCode\]' "$ATTRS" \
  && ! grep -qE 'ObfuscateNames|HideStrings|IntegrityChecking' "$ATTRS"; then ok; else bad "attributes"; fi

t "props default ArmDotTreatWarningsAsErrors to true"
WARN_DEFAULT="<ArmDotTreatWarningsAsErrors Condition=\"'\$(ArmDotTreatWarningsAsErrors)' == ''\">true</ArmDotTreatWarningsAsErrors>"
if grep -q "$WARN_DEFAULT" "$PROPS"; then ok; else bad "warnings default"; fi

t "targets pass warnings-as-errors from the property, suppress CS 3 and 5, and take the license from ArmDotLicenseFile"
if grep -q 'TreatAllWarningsAsErrors="\$(ArmDotTreatWarningsAsErrors)"' "$TARGETS" \
  && grep -q 'NoWarn="3,5"' "$TARGETS" \
  && grep -q 'LicenseFile="\$(ArmDotLicenseFile)"' "$TARGETS"; then ok; else bad "task attributes"; fi

t "props run ArmDot only when DuploObfuscate is true, in Release"
SHOULD_COND="ShouldObfuscate Condition=\"'\$(Configuration)' == 'Release' and '\$(DuploObfuscate)' == 'true'\""
if grep -q "$SHOULD_COND" "$PROPS"; then ok; else bad "condition"; fi

t "targets name ArmDotLicenseFile in the log message"
if grep -q 'license file: .\$(ArmDotLicenseFile).' "$TARGETS"; then ok; else bad "message"; fi

t "the Directory.Build.targets template imports the targets by DuploDevkitBuildDir when DuploObfuscate is true"
if grep -q 'Import Project="\$(DuploDevkitBuildDir)ArmDot.Obfuscation.targets"' "$TEMPLATE" \
  && grep -q "'\$(DuploObfuscate)' == 'true'" "$TEMPLATE"; then ok; else bad "template import"; fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
