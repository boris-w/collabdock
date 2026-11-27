#!/usr/bin/env bash
# 运行全部测试并统计行覆盖率：
#   - CollabDockCore：低于门槛时失败（MIN_CORE_LINE_COVERAGE，默认 80%）
#   - CollabDockApp：只报告，暂不设门槛（SwiftUI 视图不在单测范围内）
# 在 GitHub Actions 中会把逐文件覆盖率写进 Job Summary。
#
#   MIN_CORE_LINE_COVERAGE=80 ./scripts/coverage.sh
set -euo pipefail

MIN="${MIN_CORE_LINE_COVERAGE:-80}"

swift test --enable-code-coverage

BIN="$(swift build --show-bin-path)"
PROF="$BIN/codecov/default.profdata"
XCTEST="$(find "$BIN" -maxdepth 1 -name '*.xctest' | head -1)"
EXE="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"

# 只保留某一个 target 的源码：排除构建产物、测试和其他 target
report_for() {
  local exclude="$1"
  xcrun llvm-cov report "$EXE" -instr-profile "$PROF" -ignore-filename-regex="(\.build|/Tests/|${exclude})"
}

CORE_REPORT="$(report_for '/Sources/CollabDockApp/|/Sources/CollabDock/')"
APP_REPORT="$(report_for '/Sources/CollabDockCore/|/Sources/CollabDock/')"
echo "$CORE_REPORT"

# llvm-cov report 列：Filename Regions Missed Cover Functions Missed Executed Lines Missed Cover ...
total_of() { echo "$1" | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }'; }
CORE_TOTAL="$(total_of "$CORE_REPORT")"
APP_TOTAL="$(total_of "$APP_REPORT")"
PASS="$(awk -v t="$CORE_TOTAL" -v m="$MIN" 'BEGIN { print (t + 0 >= m + 0) ? "yes" : "no" }')"

table() {
  echo "| File | Lines | Covered |"
  echo "| :--- | ---: | ---: |"
  echo "$1" | awk 'NR > 2 && $1 !~ /^-/ && $1 != "TOTAL" { printf "| `%s` | %s | %s |\n", $1, $8, $10 }' | sort -t'|' -k4 -n
}

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## CollabDockCore line coverage: ${CORE_TOTAL}% (gate ≥ ${MIN}%)"
    echo
    table "$CORE_REPORT"
    echo
    echo "## CollabDockApp line coverage: ${APP_TOTAL:-n/a}% (reported, no gate yet)"
    echo
    table "$APP_REPORT"
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "CollabDockApp line coverage ${APP_TOTAL:-n/a}% (reported only)"
if [ "$PASS" != "yes" ]; then
  echo "::error::CollabDockCore line coverage ${CORE_TOTAL}% is below the ${MIN}% gate"
  exit 1
fi
echo "CollabDockCore line coverage ${CORE_TOTAL}% (gate ≥ ${MIN}%)"
