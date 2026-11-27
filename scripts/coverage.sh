#!/usr/bin/env bash
# 运行全部测试并统计 CollabDockCore 的行覆盖率；低于门槛时失败。
# 在 GitHub Actions 中会把逐文件覆盖率写进 Job Summary。
#
#   MIN_CORE_LINE_COVERAGE=75 ./scripts/coverage.sh
#
# 说明：CollabDockApp 是可执行 target，目前没有被测试链接，所以这里只统计 Core。
set -euo pipefail

MIN="${MIN_CORE_LINE_COVERAGE:-75}"

swift test --enable-code-coverage

BIN="$(swift build --show-bin-path)"
PROF="$BIN/codecov/default.profdata"
XCTEST="$(find "$BIN" -maxdepth 1 -name '*.xctest' | head -1)"
EXE="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"

REPORT="$(xcrun llvm-cov report "$EXE" -instr-profile "$PROF" -ignore-filename-regex='(\.build|Tests)/')"
echo "$REPORT"

# llvm-cov report 列：Filename Regions Missed Cover Functions Missed Executed Lines Missed Cover ...
TOTAL="$(echo "$REPORT" | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')"
PASS="$(awk -v t="$TOTAL" -v m="$MIN" 'BEGIN { print (t + 0 >= m + 0) ? "yes" : "no" }')"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## CollabDockCore line coverage: ${TOTAL}% (gate ≥ ${MIN}%)"
    echo
    echo "| File | Lines | Covered |"
    echo "| :--- | ---: | ---: |"
    echo "$REPORT" | awk 'NR > 2 && $1 !~ /^-/ && $1 != "TOTAL" { printf "| `%s` | %s | %s |\n", $1, $8, $10 }' | sort -t'|' -k4 -n
    echo
    echo "_CollabDockApp (SwiftUI app target) is not linked into tests yet and is not measured._"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$PASS" != "yes" ]; then
  echo "::error::CollabDockCore line coverage ${TOTAL}% is below the ${MIN}% gate"
  exit 1
fi
echo "CollabDockCore line coverage ${TOTAL}% (gate ≥ ${MIN}%)"
