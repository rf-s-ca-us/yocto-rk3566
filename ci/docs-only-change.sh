#!/bin/sh
# 判断一组仓库路径是不是「纯文档」。
# 标准输入每行一个路径(compare API 的 filename / previous_filename)。
# 退出 0:至少一行,且每一行都是文档。
# 退出 1:空输入,或出现镜像/配方/内核/脚本/workflow 等会进构建的路径。
#
# 与 build.yml 的 paths-ignore 同一口径,并加上 docs submodule 指针:
#   **.md、仓库根的 LICENSE*、LICENSES/**、docs 与 docs/**。
set -eu

is_doc_path() {
	p=$1
	case "$p" in
	*.md | docs | docs/* | LICENSES | LICENSES/*)
		return 0
		;;
	esac
	# GitHub 的 LICENSE* 不跨目录:* 不匹配 /。
	case "$p" in
	*/*) return 1 ;;
	esac
	case "$p" in
	LICENSE | LICENSE*) return 0 ;;
	esac
	return 1
}

n=0
while IFS= read -r line || [ -n "$line" ]; do
	# 去掉 CR,忽略空行
	cr=$(printf '\r')
	line=${line%"$cr"}
	[ -n "$line" ] || continue
	n=$((n + 1))
	if ! is_doc_path "$line"; then
		exit 1
	fi
done

[ "$n" -ge 1 ]
