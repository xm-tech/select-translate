# 划词翻译（SelectTranslate）常用命令
#
#   make            # 显示所有命令
#   make setup      # 构建 + 安装到 ~/Applications + 重新授权（最常用）
#   make e2e e2e-zh # 端到端自测

SHELL := /bin/bash
APP_NAME := SelectTranslate
APP_DIR := $(HOME)/Applications/$(APP_NAME).app
APP_BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
DIST_DIR := dist/$(APP_NAME).app
DIST_BIN := $(DIST_DIR)/Contents/MacOS/$(APP_NAME)
LOG := $(HOME)/Library/Logs/$(APP_NAME).log
VERSION ?= 1.1
TARGET_ARCH ?= arm64
SWIFT_FLAGS := -O -swift-version 5 -target $(TARGET_ARCH)-apple-macos13.0 -module-cache-path .tmp/modcache
export VERSION TARGET_ARCH

.DEFAULT_GOAL := help
.PHONY: help build install regrant setup run stop logs doctor \
        selftest appletest axtest snapshot icon tools e2e e2e-zh test clean release

help: ## 显示可用命令
	@echo ""
	@echo "  划词翻译 SelectTranslate · 版本 $(VERSION) · $(TARGET_ARCH)"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-11s\033[0m %s\n", $$1, $$2}'
	@echo ""

build: ## 编译到 dist/SelectTranslate.app
	./scripts/build.sh

install: ## 构建 + 安装到 ~/Applications 并启动
	./scripts/install.sh

regrant: ## 修复辅助功能授权（每次重新构建后都要跑）
	./scripts/regrant.sh

setup: install regrant ## 一步到位：构建 + 安装 + 重新授权（推荐）
	@echo "==> 完成：试试选中一段文字"

run: ## 启动已安装的 App
	open "$(APP_DIR)"

stop: ## 退出正在运行的 App（含测试进程）
	-@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" >/dev/null 2>&1 || true

logs: ## 实时查看日志
	tail -f "$(LOG)"

doctor: ## 检查环境：SDK、安装位置、辅助功能授权
	@echo "SDK:        $$(xcrun --sdk macosx --show-sdk-version)"
	@echo "架构:       $$(uname -m)"
	@echo "安装位置:   $(APP_DIR)"
	@if [ -x "$(APP_BIN)" ]; then echo "已安装:     是"; else echo "已安装:     否（先跑 make setup）"; fi
	@if [ -f "$(LOG)" ]; then echo "最近启动:   $$(grep 'launched' "$(LOG)" | tail -1)"; fi

selftest: build ## 命令行翻译自测（腾讯 / MyMemory / Google，中英双向）
	"$(DIST_BIN)" --selftest

appletest: build ## Apple 本地翻译状态 + 中英双向计时
	"$(DIST_BIN)" --appletest

axtest: build ## 打印前台 App 的选区信息（排查权限 / 选区问题）
	"$(DIST_BIN)" --axtest

snapshot: build ## 渲染结果卡片三种状态截图到 .tmp/snap
	"$(DIST_BIN)" --snapshot .tmp/snap

icon: build ## 重新生成 App 图标（app/AppIcon.icns）
	rm -f app/AppIcon.icns
	./scripts/build.sh

tools: ## 编译端到端测试工具
	swiftc $(SWIFT_FLAGS) Tools/e2e.swift -o .tmp/e2e
	swiftc $(SWIFT_FLAGS) Tools/e2e-zh.swift -o .tmp/e2e-zh

e2e: build tools ## 英文划词端到端（TextEdit：选区、按钮、卡片、✕、复制、点别处）
	@$(MAKE) stop
	rm -rf .tmp/e2e-out
	./.tmp/e2e "$(DIST_BIN)"

e2e-zh: build tools ## 中文划词端到端（中译英方向识别 + 复制英文）
	@$(MAKE) stop
	rm -rf .tmp/e2e-zh-out
	./.tmp/e2e-zh "$(DIST_BIN)"

test: selftest e2e e2e-zh ## 全部自测：翻译链路 + 中英两套 E2E

clean: ## 清理构建产物与临时文件
	rm -rf .tmp dist .build

release: build ## 打发布包（zip + sha256）
	ditto -c -k --sequesterRsrc --keepParent "$(DIST_DIR)" "$(APP_NAME)-$(VERSION).zip"
	shasum -a 256 "$(APP_NAME)-$(VERSION).zip" | tee "$(APP_NAME)-$(VERSION).zip.sha256"
