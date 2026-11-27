#!/bin/sh
# 镜像内容自查的 keyring 半边:rootfs 里必须有 /etc/rauc/keyring.pem
# (0644,与仓内证书字节相同),system.conf 必须单独有 [keyring] 和
# path=/etc/rauc/keyring.pem。tar 成员前缀(./ 或裸)不猜。
set -eu

if [ "$#" -ne 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
	echo "usage: $0 <rootfs.tar.gz> <expected-keyring.pem>" >&2
	exit 2
fi

tarball=$1
expected=$2
fail=0

[ -f "$tarball" ] || { echo "::error::找不到 rootfs 包 $tarball"; exit 1; }
[ -f "$expected" ] || { echo "::error::找不到预期证书 $expected"; exit 1; }

list=$(mktemp)
verbose=$(mktemp)
trap 'rm -f "$list" "$verbose"' EXIT

tar tzf "$tarball" > "$list"
tar tzvf "$tarball" > "$verbose"

member=$(grep 'rauc/keyring.pem$' "$list" | head -1 || true)
if [ -z "$member" ]; then
	echo "::error::rootfs 里没有 /etc/rauc/keyring.pem"
	fail=1
else
	mode=$(grep 'rauc/keyring.pem$' "$verbose" | awk '{print $1; exit}')
	case ${mode:-} in
		-rw-r--r--|-rw-r--r--.|-rw-r--r--+) ;;
		*)
			echo "::error::/etc/rauc/keyring.pem 权限不是 0644(实为 ${mode:-未知})"
			fail=1
			;;
	esac
	got=$(mktemp)
	# 成员名用清单里的原文,兼容 ./etc 与 etc 两种前缀。
	tar xzOf "$tarball" "$member" > "$got"
	if ! cmp -s "$got" "$expected"; then
		echo "::error::rootfs 的 /etc/rauc/keyring.pem 与仓内证书不一致"
		fail=1
	fi
	rm -f "$got"
fi

conf_member=$(grep 'rauc/system.conf$' "$list" | head -1 || true)
if [ -z "$conf_member" ]; then
	echo "::error::rootfs 里没有 rauc/system.conf,无法确认 keyring 配置"
	fail=1
else
	conf=$(mktemp)
	tar xzOf "$tarball" "$conf_member" > "$conf"
	if ! grep -qx '\[keyring\]' "$conf"; then
		echo "::error::system.conf 没有单独一行 [keyring] —— RAUC 1.15 会报 No keyring file or directory provided"
		fail=1
	fi
	if ! grep -qx 'path=/etc/rauc/keyring.pem' "$conf"; then
		echo "::error::system.conf 的 [keyring] 没有指向 /etc/rauc/keyring.pem"
		fail=1
	fi
	rm -f "$conf"
fi

exit "$fail"
