#!/bin/sh
# 决定这次 workflow 要不要编镜像并发布 OTA。
# 写出 build_image=true|false 到 $GITHUB_OUTPUT(没有该文件时只打到 stdout)。
#
# push 且变更全部是文档(含 docs submodule 指针)→ false。
# workflow_dispatch、无法列出文件、compare 结果被截断 → true
# (漏编会挡住真实发布;漏跳过顶多多一次构建,发布步仍会被 docs-only 拦住)。
#
# 测试时可设 CHANGED_FILES(多行路径),跳过 compare API。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${GITHUB_OUTPUT:-}

emit() {
	printf 'build_image=%s\n' "$1"
	if [ -n "$OUT" ]; then
		printf 'build_image=%s\n' "$1" >> "$OUT"
	fi
}

event=${EVENT_NAME:-push}
if [ "$event" != "push" ]; then
	echo "事件 $event:按手动构建处理,会编镜像并允许发布 OTA"
	emit true
	exit 0
fi

if [ "${CHANGED_FILES+x}" = x ]; then
	files=$CHANGED_FILES
else
	before=${BEFORE:-}
	after=${AFTER:-}
	repo=${REPO:-}
	if [ -z "$before" ] || [ "$before" = "0000000000000000000000000000000000000000" ] || [ -z "$after" ] || [ -z "$repo" ]; then
		echo "::warning::push 缺少 before/after,无法判断是不是纯文档,继续构建"
		emit true
		exit 0
	fi
	if ! json=$(gh api "repos/${repo}/compare/${before}...${after}"); then
		echo "::warning::compare API 失败,继续构建以免漏掉真实改动"
		emit true
		exit 0
	fi
	if ! n=$(printf '%s' "$json" | jq '.files // [] | length'); then
		echo "::warning::compare 结果解析失败,继续构建以免漏掉真实改动"
		emit true
		exit 0
	fi
	# compare 单次最多 300 个文件;到顶时可能还有没列出来的非文档路径。
	if [ "$n" -ge 300 ]; then
		echo "::warning::变更文件达到 compare 上限,继续构建"
		emit true
		exit 0
	fi
	if ! files=$(printf '%s' "$json" | jq -r '.files[]? | .filename, .previous_filename // empty'); then
		echo "::warning::compare 文件列表解析失败,继续构建以免漏掉真实改动"
		emit true
		exit 0
	fi
fi

if printf '%s\n' "$files" | "$ROOT/docs-only-change.sh"; then
	echo "只改了文档(markdown / LICENSE / docs 指针),不编镜像、不发布 OTA bundle、不改 latest.json"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		echo "只改了文档,跳过镜像构建与 OTA 发布。" >> "$GITHUB_STEP_SUMMARY"
	fi
	emit false
else
	echo "变更含非文档路径,继续编镜像;构建成功且自查通过后才发布 OTA"
	emit true
fi
