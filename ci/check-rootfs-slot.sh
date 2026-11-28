#!/bin/sh
# 断言打进 update.raucb 的 rootfs.ext4 不大于 A/B 槽,并且(如果给出 wic)
# GPT 里 rootfs_a/rootfs_b 的扇区数就等于这个槽。
#
# 槽位字节数从 meta-lubancat/wic/lubancat-ab.wks.in 的 --fixed-size 读。
# wic 的 k/K 是 KiB。失败线是槽位本身(image > slot 时 RAUC 拒绝,
# 相等仍可装)。16 MiB 余量在 image recipe 里,不在这里再扣一次:
# 余量被内容吃掉一部分时,只要还没越过槽,这一关就该过。
set -eu

# CDPATH= 只作用于这一次 cd。
# shellcheck disable=SC1007
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WKS=$REPO/meta-lubancat/wic/lubancat-ab.wks.in
PRINT_ONLY=0
WIC=
DUMP=
IMAGES=

usage() {
	echo "usage: $0 [--wks FILE] [--print-limit] [--image FILE]... [--wic FILE | --sfdisk-dump FILE]" >&2
}

while [ "$#" -gt 0 ]; do
	case $1 in
	--wks)
		WKS=${2:-}
		shift 2
		;;
	--print-limit)
		PRINT_ONLY=1
		shift
		;;
	--image)
		IMAGES="$IMAGES ${2:-}"
		shift 2
		;;
	--wic)
		WIC=${2:-}
		shift 2
		;;
	--sfdisk-dump)
		DUMP=${2:-}
		shift 2
		;;
	*)
		usage
		exit 2
		;;
	esac
done

if [ -n "$WIC" ] && [ -n "$DUMP" ]; then
	echo "::error::--wic 与 --sfdisk-dump 只能给一个" >&2
	exit 2
fi

note() { printf '%s\n' "$*" >&2; }

# stdout 只打 KiB 数,每个 rootfs 槽一行。注释整段丢掉,data 的 --size 2G
# 不会被看成槽位。
slot_kibs() {
	wks=$1
	[ -f "$wks" ] || return 1
	awk '
		{
			line = $0
			sub(/#.*/, "", line)
		}
		line ~ /--part-name[[:space:]]+rootfs_a([^[:alnum:]_]|$)/ ||
		line ~ /--part-name[[:space:]]+rootfs_b([^[:alnum:]_]|$)/ {
			if (match(line, /--fixed-size[[:space:]]+[0-9]+[kK]([^[:alnum:]_]|$)/)) {
				token = substr(line, RSTART, RLENGTH)
				if (match(token, /[0-9]+/)) {
					print substr(token, RSTART, RLENGTH)
					next
				}
			}
			print "MISSING"
		}
	' "$wks"
}

kibs=$(slot_kibs "$WKS") || {
	note "::error::读不了分区表 $WKS"
	exit 1
}

count=0
slot_kib=
missing=0
mismatch=0
for kib in $kibs; do
	count=$((count + 1))
	if [ "$kib" = "MISSING" ]; then
		missing=1
		continue
	fi
	if [ -z "$slot_kib" ]; then
		slot_kib=$kib
	elif [ "$kib" != "$slot_kib" ]; then
		mismatch=1
	fi
done

if [ "$count" -ne 2 ] || [ "$missing" -ne 0 ] || [ "$mismatch" -ne 0 ] || [ -z "$slot_kib" ]; then
	note "::error::rootfs_a 与 rootfs_b 必须各有一个相同的 --fixed-size <KiB>k(来自 $WKS,解析结果: ${kibs:-<空>})"
	exit 1
fi

# 6729594*1024 放得进 64 位 shell 算术。不能被 512 整除就无法写成扇区。
slot_bytes=$((slot_kib * 1024))
if [ $((slot_bytes % 512)) -ne 0 ]; then
	note "::error::槽位 $slot_bytes 字节不是 512 字节扇区的整数倍"
	exit 1
fi
slot_sectors=$((slot_bytes / 512))

note "rootfs 槽位上限: ${slot_bytes} 字节 (${slot_sectors} 扇区, ${slot_kib} KiB), 来源: $WKS"
if [ "$PRINT_ONLY" -eq 1 ]; then
	printf '%s\n' "$slot_bytes"
fi

fail=0

for img in $IMAGES; do
	if [ ! -f "$img" ]; then
		note "::error::找不到 rootfs 镜像 $img"
		fail=1
		continue
	fi
	# -L: deploy 目录里的同名软链要量目标文件。RAUC 比的是这个表观大小。
	bytes=$(stat -L -c %s "$img")
	if [ "$bytes" -gt "$slot_bytes" ]; then
		over=$((bytes - slot_bytes))
		note "::error::$img 有 ${bytes} 字节,比 A/B 槽大 ${over} 字节(槽 ${slot_bytes})"
		fail=1
	else
		room=$((slot_bytes - bytes))
		note "rootfs 尺寸: $img ${bytes} 字节,距槽位还剩 ${room} 字节"
	fi
done

check_dump() {
	table=$1
	label=$2
	got_a=
	got_b=
	while IFS= read -r line; do
		name=
		case $line in
		*'name="rootfs_a"'* | *'name=rootfs_a,'* | *'name=rootfs_a '*) name=a ;;
		*'name="rootfs_b"'* | *'name=rootfs_b,'* | *'name=rootfs_b '*) name=b ;;
		*) continue ;;
		esac
		sectors=$(printf '%s\n' "$line" | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
		if [ -z "$sectors" ]; then
			note "::error::$label 的 rootfs_$name 行没有 size=: $line"
			fail=1
			continue
		fi
		if [ "$name" = "a" ]; then
			got_a=$sectors
		else
			got_b=$sectors
		fi
		if [ "$sectors" -ne "$slot_sectors" ]; then
			note "::error::$label 的 rootfs_$name 是 ${sectors} 扇区,分区表真源是 ${slot_sectors}"
			fail=1
		fi
	done < "$table"
	if [ -z "$got_a" ] || [ -z "$got_b" ]; then
		note "::error::$label 里没有同时找到 rootfs_a 与 rootfs_b"
		fail=1
	fi
}

table=
if [ -n "$WIC" ]; then
	if [ ! -f "$WIC" ]; then
		note "::error::找不到 wic $WIC"
		fail=1
	elif ! command -v sfdisk >/dev/null 2>&1; then
		note "::error::需要 sfdisk 才能核对 $WIC 的分区大小"
		fail=1
	else
		table=$(mktemp)
		if ! sfdisk -d "$WIC" > "$table"; then
			note "::error::sfdisk 读不了 $WIC"
			fail=1
			rm -f "$table"
			table=
		fi
	fi
elif [ -n "$DUMP" ]; then
	if [ ! -f "$DUMP" ]; then
		note "::error::找不到 sfdisk 转储 $DUMP"
		fail=1
	else
		table=$DUMP
	fi
fi

if [ -n "$table" ]; then
	check_dump "$table" "${WIC:-$DUMP}"
	if [ -n "$WIC" ]; then
		rm -f "$table"
	fi
fi

{
	echo "### rootfs 槽位"
	echo "上限: ${slot_bytes} 字节 (${slot_sectors} 扇区), 来自 \`$WKS\`。"
	if [ "$fail" -eq 0 ]; then
		echo "未超过槽位。"
	else
		echo "超过槽位或分区大小与真源不一致。"
	fi
} > "${TMPDIR:-/tmp}/rootfs-slot-summary.txt"
cat "${TMPDIR:-/tmp}/rootfs-slot-summary.txt" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	cat "${TMPDIR:-/tmp}/rootfs-slot-summary.txt" >> "$GITHUB_STEP_SUMMARY"
fi
rm -f "${TMPDIR:-/tmp}/rootfs-slot-summary.txt"

exit "$fail"
