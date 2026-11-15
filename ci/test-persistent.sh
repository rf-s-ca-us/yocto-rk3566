#!/bin/sh
# 不跑 Yocto。验证空白分区才会被格式化,以及跨槽配置拷贝不覆盖、不放宽权限。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FILES=$ROOT/meta-lubancat/recipes-core/persistent/files
FMT=$FILES/format-data-if-empty
HOOK=$FILES/rauc-slot-hook
COMMON=$FILES/persistent-common.sh
MOUNT=$FILES/mount-persistent

fail=0
pass=0

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

bad() {
	fail=1
	printf '  FAIL %s\n' "$1"
	shift
	if [ "$#" -gt 0 ]; then
		printf '%s\n' "$@" | sed 's/^/       | /'
	fi
}

expect_eq() {
	name=$1
	want=$2
	got=$3
	if [ "$want" = "$got" ]; then
		ok "$name"
	else
		bad "$name" "want [$want]" "got  [$got]"
	fi
}

mode_of() {
	stat -c %a "$1"
}

echo "== syntax"
for f in "$FMT" "$HOOK" "$MOUNT" "$COMMON" \
	"$ROOT/meta-lubancat/recipes-core/ota/files/ota-selfcheck" \
	"$ROOT/meta-lubancat/recipes-core/ota/files/ota-update"; do
	if sh -n "$f"; then
		ok "sh -n $(basename "$f")"
	else
		bad "sh -n $(basename "$f")"
	fi
done

echo "== formatter never passes the force switch"
if grep -n 'mke2fs' "$FMT" | grep -q -- '-F'; then
	bad "format-data-if-empty 的 mke2fs 行含 -F"
else
	ok "mke2fs 行没有 -F"
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

make_fake_mke2fs() {
	dir=$1
	code=$2
	cat > "$dir/mke2fs" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$dir/mke2fs.log"
for a in "\$@"; do
	if [ "\$a" = "-F" ]; then
		echo FORCE >> "$dir/mke2fs.log"
		exit 3
	fi
done
exit $code
EOF
	chmod 0755 "$dir/mke2fs"
}

make_fake_blkid() {
	dir=$1
	code=$2
	cat > "$dir/blkid" <<EOF
#!/bin/sh
for a in "\$@"; do
	if [ "\$a" = "-s" ]; then
		printf '%s\\n' data
		exit 0
	fi
done
exit $code
EOF
	chmod 0755 "$dir/blkid"
}

run_format() {
	name=$1
	shift
	set +e
	out=$(env "$@" "$FMT" 2>&1)
	rc=$?
	set -e
	printf '%s\n' "$out" > "$workdir/last.out"
	return "$rc"
}

zero_file() {
	dd if=/dev/zero of="$1" bs=1048576 count=2 status=none
}

echo "== blank file is formatted once, without -F"
bin=$workdir/bin-ok
mkdir -p "$bin"
make_fake_mke2fs "$bin" 0
make_fake_blkid "$bin" 2
img=$workdir/blank.img
zero_file "$img"
if run_format blank \
	PATH="$bin:/usr/sbin:/usr/bin:/bin" \
	DATA_FORMAT_ALLOW_FILE=1 \
	DATA_DEV="$img"; then
	ok "空白文件退出 0"
else
	bad "空白文件退出 0" "$(cat "$workdir/last.out")"
fi
log=$bin/mke2fs.log
calls=$(wc -l < "$log" | tr -d ' ')
expect_eq "mke2fs 只调用一次" 1 "$calls"
if grep -q FORCE "$log"; then
	bad "调用参数含 -F" "$(cat "$log")"
else
	ok "调用参数不含 -F"
fi
case $(cat "$log") in
	"-t ext4 -L data -E nodiscard $img") ok "参数是 -t ext4 -L data -E nodiscard <设备>" ;;
	*) bad "参数不符合预期" "$(cat "$log")" ;;
esac

echo "== refusals do not call mke2fs"
refuse() {
	name=$1
	b=$2
	shift 2
	mkdir -p "$b"
	make_fake_mke2fs "$b" 0
	if run_format "$name" PATH="$b:/usr/sbin:/usr/bin:/bin" "$@"; then
		if [ -s "$b/mke2fs.log" ]; then
			bad "$name 仍调用了 mke2fs" "$(cat "$b/mke2fs.log")" "$(cat "$workdir/last.out")"
		else
			ok "$name"
		fi
	else
		bad "$name 退出非 0" "$(cat "$workdir/last.out")"
	fi
}

refuse "没有设备" "$workdir/bin-missing" DATA_DEV="$workdir/missing-dev" DATA_FORMAT_ALLOW_FILE=1
plain=$workdir/plain.img
zero_file "$plain"
refuse "普通文件且未显式允许" "$workdir/bin-plain" DATA_DEV="$plain"

mkdir -p "$workdir/bin-sig"
make_fake_blkid "$workdir/bin-sig" 0
refuse "blkid 报已有签名" "$workdir/bin-sig" DATA_FORMAT_ALLOW_FILE=1 DATA_DEV="$plain"

mkdir -p "$workdir/bin-probe"
make_fake_blkid "$workdir/bin-probe" 1
refuse "blkid 探测失败" "$workdir/bin-probe" DATA_FORMAT_ALLOW_FILE=1 DATA_DEV="$plain"

nonzero=$workdir/nonzero.img
zero_file "$nonzero"
printf '\001' | dd of="$nonzero" bs=1 seek=100 conv=notrunc status=none
refuse "前 1MiB 有非零字节" "$workdir/bin-nonzero" DATA_FORMAT_ALLOW_FILE=1 DATA_DEV="$nonzero"

magic=$workdir/magic.img
zero_file "$magic"
printf '\x53\xef' | dd of="$magic" bs=1 seek=1080 conv=notrunc status=none
refuse "ext 魔数" "$workdir/bin-magic" DATA_FORMAT_ALLOW_FILE=1 DATA_DEV="$magic"

short=$workdir/short.img
dd if=/dev/zero of="$short" bs=1024 count=100 status=none
refuse "短于 1MiB" "$workdir/bin-short" DATA_FORMAT_ALLOW_FILE=1 DATA_DEV="$short"

edge=$workdir/edge.img
zero_file "$edge"
printf '\001' | dd of="$edge" bs=1 seek=1048575 conv=notrunc status=none
refuse "1MiB 最后一个字节非零" "$workdir/bin-edge" DATA_FORMAT_ALLOW_FILE=1 DATA_DEV="$edge"

echo "== byte just past 1MiB is outside the checked prefix"
bin=$workdir/bin-past
mkdir -p "$bin"
make_fake_mke2fs "$bin" 0
make_fake_blkid "$bin" 2
past=$workdir/past.img
zero_file "$past"
printf '\001' | dd of="$past" bs=1 seek=1048576 conv=notrunc status=none
if run_format past \
	PATH="$bin:/usr/sbin:/usr/bin:/bin" \
	DATA_FORMAT_ALLOW_FILE=1 \
	DATA_DEV="$past"; then
	if [ -s "$bin/mke2fs.log" ]; then
		ok "1MiB 之后的字节不阻止格式化"
	else
		bad "1MiB 之后的字节不阻止格式化" "$(cat "$workdir/last.out")"
	fi
else
	bad "1MiB 边界用例退出非 0" "$(cat "$workdir/last.out")"
fi

echo "== real ext4 is left alone"
ext=$workdir/ext.img
if ! command -v mkfs.ext4 >/dev/null 2>&1 || ! command -v blkid >/dev/null 2>&1; then
	echo "  skip 没有 mkfs.ext4 或 blkid"
else
dd if=/dev/zero of="$ext" bs=1048576 count=8 status=none
if mkfs.ext4 -F -q -L populated "$ext"; then
	b=$workdir/bin-ext4
	mkdir -p "$b"
	make_fake_mke2fs "$b" 0
	if run_format ext4 \
		PATH="$b:/usr/sbin:/usr/bin:/bin" \
		DATA_FORMAT_ALLOW_FILE=1 \
		DATA_DEV="$ext"; then
		if [ -s "$b/mke2fs.log" ]; then
			bad "已有 ext4 仍被格式化" "$(cat "$b/mke2fs.log")" "$(cat "$workdir/last.out")"
		else
			ok "已有 ext4 不格式化"
		fi
		label=$(blkid -p -s LABEL -o value "$ext" 2>/dev/null || true)
		expect_eq "原卷标还在" populated "$label"
	else
		bad "已有 ext4 用例退出非 0" "$(cat "$workdir/last.out")"
	fi
else
	bad "测试无法创建 ext4"
fi
fi

echo "== mke2fs failure is not retried"
bin=$workdir/bin-fail
mkdir -p "$bin"
make_fake_mke2fs "$bin" 1
make_fake_blkid "$bin" 2
img=$workdir/fail.img
zero_file "$img"
set +e
env PATH="$bin:/usr/sbin:/usr/bin:/bin" DATA_FORMAT_ALLOW_FILE=1 DATA_DEV="$img" "$FMT" >"$workdir/fail.out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	ok "mke2fs 失败时脚本失败"
else
	bad "mke2fs 失败时脚本仍成功" "$(cat "$workdir/fail.out")"
fi
calls=$(wc -l < "$bin/mke2fs.log" | tr -d ' ')
expect_eq "失败后不重试" 1 "$calls"

echo "== config copy keeps secrets tight and does not clobber"
# shellcheck disable=SC1090
. "$COMMON"

src=$(mktemp -d)
dst=$(mktemp -d)
mkdir -p "$src"
printf 'secret\n' > "$src/wpa_supplicant-wlan.conf"
chmod 0644 "$src/wpa_supplicant-wlan.conf"
mkdir -p "$src/nested"
printf 'x\n' > "$src/nested/note"
chmod 0755 "$src/nested/note"
persist_copy_one "$src" "$dst"
expect_eq "拷贝后凭据是 0600" 600 "$(mode_of "$dst/wpa_supplicant-wlan.conf")"
expect_eq "目录是 0700" 700 "$(mode_of "$dst")"
expect_eq "可执行位还在属主身上" 700 "$(mode_of "$dst/nested/note")"
if grep -qx secret "$dst/wpa_supplicant-wlan.conf"; then
	ok "内容被拷走"
else
	bad "内容被拷走"
fi

kept=$(mktemp -d)
live=$(mktemp -d)
printf 'KEEP\n' > "$kept/f"
printf 'NEW\n' > "$live/f"
persist_seed_dir "$live" "$kept"
expect_eq "已有内容不被覆盖" KEEP "$(cat "$kept/f")"
if [ -e "$kept/NEW" ]; then
	bad "覆盖检查多写出了文件"
else
	ok "覆盖检查没有多写文件"
fi

link=$(mktemp -d)/link
secret_dir=$(mktemp -d)
printf 'nope\n' > "$secret_dir/x"
ln -s "$secret_dir" "$link"
empty=$(mktemp -d)
persist_seed_dir "$link" "$empty"
if [ -e "$empty/x" ]; then
	bad "符号链接源被跟着拷走了"
else
	ok "符号链接源不拷"
fi

root=$(mktemp -d)
mkdir -p "$root/etc/wpa_supplicant" "$root/etc/mihomo" "$root/root/.hermes" \
	"$root/root/.local/state/hermes"
printf 'pw\n' > "$root/etc/wpa_supplicant/wpa_supplicant-wlan.conf"
printf 'sub\n' > "$root/etc/mihomo/config.yaml"
printf 'env\n' > "$root/root/.hermes/.env"
chmod 0644 "$root/etc/wpa_supplicant/wpa_supplicant-wlan.conf" \
	"$root/etc/mihomo/config.yaml" "$root/root/.hermes/.env"
chmod 0755 "$root/etc/wpa_supplicant" "$root/etc/mihomo" "$root/root/.hermes"
persist_tighten_live "$root"
expect_eq "wpa conf 0600" 600 "$(mode_of "$root/etc/wpa_supplicant/wpa_supplicant-wlan.conf")"
expect_eq "mihomo config 0600" 600 "$(mode_of "$root/etc/mihomo/config.yaml")"
expect_eq "hermes env 0600" 600 "$(mode_of "$root/root/.hermes/.env")"
expect_eq "wpa 目录 0700" 700 "$(mode_of "$root/etc/wpa_supplicant")"
expect_eq "hermes 目录 0700" 700 "$(mode_of "$root/root/.hermes")"

echo "== hook refuses to write outside a RAUC slot mount"
set +e
out=$(RAUC_SLOT_CLASS=rootfs RAUC_SLOT_MOUNT_POINT=/ "$HOOK" slot-post-install 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	ok "拒绝挂载点 /"
else
	bad "拒绝挂载点 /" "$out"
fi

set +e
out=$(RAUC_SLOT_CLASS=rootfs RAUC_SLOT_MOUNT_POINT=/mnt/rauc/../../tmp "$HOOK" slot-post-install 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	ok "拒绝 /mnt/rauc/../../tmp"
else
	bad "拒绝 /mnt/rauc/../../tmp" "$out"
fi

set +e
out=$(RAUC_SLOT_CLASS=boot RAUC_SLOT_MOUNT_POINT=/ "$HOOK" slot-post-install 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	ok "非 rootfs 槽直接跳过"
else
	bad "非 rootfs 槽直接跳过" "$out"
fi

set +e
out=$("$HOOK" something-else 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	ok "未知钩子参数失败"
else
	bad "未知钩子参数失败" "$out"
fi

if awk '$2 == "/var/lib/containers" { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts; then
	echo "  skip mount-persistent 实跑:本机 /var/lib/containers 是挂载点"
else
	set +e
	out=$("$MOUNT" 2>&1)
	rc=$?
	set -e
	if [ "$rc" -eq 0 ]; then
		ok "data 未单独挂载时 mount-persistent 退出 0"
	else
		bad "data 未单独挂载时 mount-persistent 退出 0" "$out"
	fi
fi

echo "== hook copies inside a private mount namespace"
if unshare --user --map-root-user --mount true >/dev/null 2>&1; then
	set +e
	unshare --user --map-root-user --mount sh -c '
		set -eu
		# 盖住 /etc 和 /root 的可写层,不改宿主机。lower 仍要留着,
		# 否则 /usr/bin/awk → /etc/alternatives/awk 会断。
		mkdir -p /tmp/ov/etc-lower /tmp/ov/etc-upper /tmp/ov/etc-work \
			/tmp/ov/root-lower /tmp/ov/root-upper /tmp/ov/root-work
		mount --bind /etc /tmp/ov/etc-lower
		mount --bind /root /tmp/ov/root-lower
		mount -t overlay overlay \
			-o lowerdir=/tmp/ov/etc-lower,upperdir=/tmp/ov/etc-upper,workdir=/tmp/ov/etc-work /etc
		mount -t overlay overlay \
			-o lowerdir=/tmp/ov/root-lower,upperdir=/tmp/ov/root-upper,workdir=/tmp/ov/root-work /root
		mkdir -p /etc/wpa_supplicant /etc/mihomo /root/.hermes /root/.local/state/hermes
		printf "secret\n" > /etc/wpa_supplicant/wpa_supplicant-wlan.conf
		printf "proxy\n" > /etc/mihomo/config.yaml
		printf "token\n" > /root/.hermes/.env
		printf "state\n" > /root/.local/state/hermes/session
		chmod 0644 /etc/wpa_supplicant/wpa_supplicant-wlan.conf \
			/etc/mihomo/config.yaml /root/.hermes/.env /root/.local/state/hermes/session
		mount -t tmpfs tmpfs /mnt
		mkdir -p /mnt/rauc/rootfs.1
		mount -t tmpfs tmpfs /mnt/rauc/rootfs.1
		RAUC_SLOT_CLASS=rootfs \
		RAUC_SLOT_MOUNT_POINT=/mnt/rauc/rootfs.1 \
		RAUC_MOUNT_PREFIX=/mnt/rauc \
			'"$HOOK"' slot-post-install
		test "$(stat -c %a /mnt/rauc/rootfs.1/etc/wpa_supplicant/wpa_supplicant-wlan.conf)" = 600
		test "$(stat -c %a /mnt/rauc/rootfs.1/etc/mihomo/config.yaml)" = 600
		test "$(stat -c %a /mnt/rauc/rootfs.1/root/.hermes/.env)" = 600
		test "$(stat -c %a /mnt/rauc/rootfs.1/root/.hermes)" = 700
		grep -qx secret /mnt/rauc/rootfs.1/etc/wpa_supplicant/wpa_supplicant-wlan.conf
		grep -qx state /mnt/rauc/rootfs.1/root/.local/state/hermes/session
		# 源已是挂载点时不再往槽里拷
		mkdir -p /tmp/already /mnt/rauc/rootfs.0
		mount -t tmpfs tmpfs /mnt/rauc/rootfs.0
		mount --bind /tmp/already /etc/mihomo
		printf "only-on-source\n" > /etc/mihomo/config.yaml
		RAUC_SLOT_CLASS=rootfs \
		RAUC_SLOT_MOUNT_POINT=/mnt/rauc/rootfs.0 \
		RAUC_MOUNT_PREFIX=/mnt/rauc \
			'"$HOOK"' slot-post-install
		if [ -e /mnt/rauc/rootfs.0/etc/mihomo/config.yaml ]; then
			echo "mounted source was copied" >&2
			exit 1
		fi
	'
	rc=$?
	set -e
	if [ "$rc" -eq 0 ]; then
		ok "私有挂载命名空间里的钩子拷贝"
	else
		bad "私有挂载命名空间里的钩子拷贝"
	fi
else
	echo "  skip 钩子挂载测试:unshare 不可用"
fi

echo
echo "通过 $pass,失败标记 $fail"
[ "$fail" -eq 0 ]
