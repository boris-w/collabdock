APP_NAME := CollabDock
BUILD_DIR := build
VERSION := 0.1.0

.PHONY: build test test-unit test-e2e coverage snapshots icon app dmg universal-dmg run clean

build:
	swift build

# 全部测试（单测 + 端到端）
test:
	swift test

test-unit:
	swift test --filter CollabDockCoreTests

# 端到端：假 GitHub + 假 Agent CLI + 真实临时 git 仓库，无需网络与真实 AI
test-e2e:
	swift test --filter CollabDockE2ETests

# 全部测试 + CollabDockCore 行覆盖率门槛（默认 75%，可用 MIN_CORE_LINE_COVERAGE 覆盖）；CI 使用此目标
coverage:
	./scripts/coverage.sh

# DEBUG 构建离屏渲染 UI 快照（Light/Dark），用于 README 截图与视觉回归
snapshots: build
	"$$(swift build --show-bin-path)/$(APP_NAME)" --snapshot-dir docs/images

icon:
	swift scripts/generate-icon.swift Resources/AppIcon.icns

app:
	./scripts/package-app.sh

dmg: app
	VERSION="$(VERSION)" ./scripts/package-dmg.sh

universal-dmg:
	UNIVERSAL=1 ./scripts/package-app.sh
	VERSION="$(VERSION)" ./scripts/package-dmg.sh

run: app
	killall "$(APP_NAME)" 2>/dev/null || true
	open "$(BUILD_DIR)/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf "$(BUILD_DIR)"
