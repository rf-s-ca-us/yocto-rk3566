#!/bin/sh
# 不跑 Yocto。验证空白分区才会被格式化,以及跨槽配置拷贝不覆盖、不放宽权限。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FILES=$ROOT/meta-lubancat/recipes-core/persistent/files
FMT=$FILES/format-data-if-empty
HOOK=$FILES/rauc-slot-hook
COMMON=$FILES/persistent-common.sh
MOUNT=$FILES/mount-persistent
SEAL=$FILES/seal-data-store

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
for f in "$FMT" "$HOOK" "$MOUNT" "$COMMON" "$SEAL" \
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

echo "== poky BusyBox 1.36.1 不接受的参数"
# 只扫代码行。注释里可以写 status=none,提醒后来的人别加回去。
scan_busybox_flags() {
	file=$1
	label=$2
	hits=$(awk '
		/^[[:space:]]*#/ { next }
		{ print NR ":" $0 }
	' "$file" | grep -E 'status=|conv=|ibs=|obs=|iflag=|oflag=|(^|[^[:alnum:]_])od([^[:alnum:]_]|$)|printf "%[0-9.]*[udxX]' || true)
	if [ -n "$hits" ]; then
		bad "$label" "$hits"
	else
		ok "$label"
	fi
}
scan_busybox_flags "$FMT" "format-data-if-empty 没有 GNU 专用的 dd/od/awk 写法"
scan_busybox_flags "$COMMON" "persistent-common.sh 没有 GNU 专用的 dd/od/awk 写法"
scan_busybox_flags "$SEAL" "seal-data-store 没有 GNU 专用的 dd/od/awk 写法"
scan_busybox_flags "$MOUNT" "mount-persistent 没有 GNU 专用的 dd/od/awk 写法"
scan_busybox_flags "$HOOK" "rauc-slot-hook 没有 GNU 专用的 dd/od/awk 写法"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"; rm -rf /tmp/ov-* 2>/dev/null || true' EXIT
# 钩子的抢救目录默认在 /var/lib。测试里改到临时目录,避免碰到宿主机。
export PERSIST_SALVAGE=$workdir/salvage

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

# 始终返回 0。格式化脚本自己的退出码在 RUN_RC,避免 set -e 把拒绝路径当成测试崩溃。
run_format() {
	name=$1
	shift
	set +e
	out=$(env "$@" "$FMT" 2>&1)
	RUN_RC=$?
	set -e
	printf '%s\n' "$out" > "$workdir/last.out"
	return 0
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
run_format blank \
	PATH="$bin:/usr/sbin:/usr/bin:/bin" \
	DATA_FORMAT_ALLOW_FILE=1 \
	DATA_DEV="$img"
if [ "$RUN_RC" -eq 0 ]; then
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
	run_format "$name" PATH="$b:/usr/sbin:/usr/bin:/bin" "$@"
	if [ "$RUN_RC" -eq 0 ]; then
		bad "$name 本应拒绝并返回非 0" "$(cat "$workdir/last.out")"
	elif [ -s "$b/mke2fs.log" ]; then
		bad "$name 仍调用了 mke2fs" "$(cat "$b/mke2fs.log")" "$(cat "$workdir/last.out")"
	else
		ok "$name"
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

echo "== a non-zero byte past 1MiB still blocks formatting"
bin=$workdir/bin-past
mkdir -p "$bin"
make_fake_mke2fs "$bin" 0
make_fake_blkid "$bin" 2
past=$workdir/past.img
zero_file "$past"
printf '\001' | dd of="$past" bs=1 seek=1048576 conv=notrunc status=none
run_format past \
	PATH="$bin:/usr/sbin:/usr/bin:/bin" \
	DATA_FORMAT_ALLOW_FILE=1 \
	DATA_DEV="$past"
if [ "$RUN_RC" -eq 0 ] || [ -s "$bin/mke2fs.log" ]; then
	bad "1MiB 之后的非零字节仍被格式化" "$(cat "$bin/mke2fs.log" 2>/dev/null || true)" "$(cat "$workdir/last.out")"
else
	ok "1MiB 之后的非零字节拒绝格式化"
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
	run_format ext4 \
		PATH="$b:/usr/sbin:/usr/bin:/bin" \
		DATA_FORMAT_ALLOW_FILE=1 \
		DATA_DEV="$ext"
	if [ -s "$b/mke2fs.log" ]; then
		bad "已有 ext4 仍被格式化" "$(cat "$b/mke2fs.log")" "$(cat "$workdir/last.out")"
	elif [ "$RUN_RC" -eq 0 ]; then
		bad "已有其它卷标的 ext4 被当成成功" "$(cat "$workdir/last.out")"
	else
		ok "已有 ext4 不格式化"
	fi
	label=$(blkid -p -D -s LABEL -o value "$ext" 2>/dev/null || true)
	expect_eq "原卷标还在" populated "$label"
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

echo "== empty tree does not beat a salvaged tree"
live_empty=$(mktemp -d)
salvage=$(mktemp -d)
mkdir -p "$salvage"
printf 'from-A\n' > "$salvage/wpa_supplicant-wlan.conf"
chosen=$(persist_choose_source "$live_empty" "$salvage" wpa_supplicant-wlan.conf)
expect_eq "空的运行中目录让位给抢救副本" "$salvage" "$chosen"
if persist_should_bind "$live_empty"; then
	bad "空目录仍被允许 bind"
else
	ok "空目录不 bind"
fi
live_full=$(mktemp -d)
printf 'from-B\n' > "$live_full/wpa_supplicant-wlan.conf"
chosen=$(persist_choose_source "$live_full" "$salvage" wpa_supplicant-wlan.conf)
expect_eq "运行中的凭据文件优先于抢救副本" "$live_full" "$chosen"
live_logs=$(mktemp -d)
mkdir -p "$live_logs/logs"
printf 'noise\n' > "$live_logs/logs/gateway.log"
hermes_salvage=$(mktemp -d)
printf 'real-env\n' > "$hermes_salvage/.env"
chosen=$(persist_choose_source "$live_logs" "$hermes_salvage" .env)
expect_eq "只有日志的运行中树让位给带 .env 的抢救副本" "$hermes_salvage" "$chosen"
# 符号链接保持为链接,不把链接外面的目标抄进来。
linksrc=$(mktemp -d)
outside=$(mktemp -d)
printf 'outside\n' > "$outside/secret"
ln -s "$outside/secret" "$linksrc/wpa_supplicant-wlan.conf"
linkdst=$(mktemp -d)
persist_copy_one "$linksrc" "$linkdst"
if [ -L "$linkdst/wpa_supplicant-wlan.conf" ]; then
	ok "拷贝保留符号链接"
else
	bad "拷贝保留符号链接"
fi

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
		ov=/tmp/ov-$$
		mkdir -p "$ov/etc-lower" "$ov/etc-upper" "$ov/etc-work" \
			"$ov/root-lower" "$ov/root-upper" "$ov/root-work"
		mount --bind /etc "$ov/etc-lower"
		mount --bind /root "$ov/root-lower"
		mount -t overlay overlay \
			-o lowerdir=$ov/etc-lower,upperdir=$ov/etc-upper,workdir=$ov/etc-work /etc
		mount -t overlay overlay \
			-o lowerdir=$ov/root-lower,upperdir=$ov/root-upper,workdir=$ov/root-work /root
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

echo "== pre-install keeps the other slot when the running slot is empty"
if unshare --user --map-root-user --mount true >/dev/null 2>&1; then
	set +e
	unshare --user --map-root-user --mount sh -c '
		set -eu
		ov=/tmp/ov-$$
		mkdir -p "$ov/etc-lower" "$ov/etc-upper" "$ov/etc-work" \
			"$ov/root-lower" "$ov/root-upper" "$ov/root-work"
		mount --bind /etc "$ov/etc-lower"
		mount --bind /root "$ov/root-lower"
		mount -t overlay overlay \
			-o lowerdir=$ov/etc-lower,upperdir=$ov/etc-upper,workdir=$ov/etc-work /etc
		mount -t overlay overlay \
			-o lowerdir=$ov/root-lower,upperdir=$ov/root-upper,workdir=$ov/root-work /root
		# /var 换成内存盘,抢救目录和 data 挂载都不写宿主机。
		mount -t tmpfs tmpfs /var
		# 正在跑的 B:目录在,但是没有配置文件。
		mkdir -p /etc/wpa_supplicant /etc/mihomo /root/.hermes
		mount -t tmpfs tmpfs /mnt
		mkdir -p /mnt/rauc/rootfs.1
		mount -t tmpfs tmpfs /mnt/rauc/rootfs.1
		mkdir -p /mnt/rauc/rootfs.1/etc/wpa_supplicant /mnt/rauc/rootfs.1/root/.hermes
		printf "kept-from-A\n" > /mnt/rauc/rootfs.1/etc/wpa_supplicant/wpa_supplicant-wlan.conf
		printf "env-from-A\n" > /mnt/rauc/rootfs.1/root/.hermes/.env
		chmod 0644 /mnt/rauc/rootfs.1/etc/wpa_supplicant/wpa_supplicant-wlan.conf \
			/mnt/rauc/rootfs.1/root/.hermes/.env
		RAUC_SLOT_CLASS=rootfs \
		RAUC_SLOT_MOUNT_POINT=/mnt/rauc/rootfs.1 \
		RAUC_MOUNT_PREFIX=/mnt/rauc \
		PERSIST_SALVAGE=/var/lib/lubancat-persist-salvage \
			'"$HOOK"' slot-pre-install
		# 模拟 RAUC 写完新 rootfs:旧文件没了,只剩镜像里的空目录。
		rm -rf /mnt/rauc/rootfs.1/*
		mkdir -p /mnt/rauc/rootfs.1/etc/mihomo
		RAUC_SLOT_CLASS=rootfs \
		RAUC_SLOT_MOUNT_POINT=/mnt/rauc/rootfs.1 \
		RAUC_MOUNT_PREFIX=/mnt/rauc \
		PERSIST_SALVAGE=/var/lib/lubancat-persist-salvage \
			'"$HOOK"' slot-post-install
		grep -qx kept-from-A /mnt/rauc/rootfs.1/etc/wpa_supplicant/wpa_supplicant-wlan.conf
		grep -qx env-from-A /mnt/rauc/rootfs.1/root/.hermes/.env
		test "$(stat -c %a /mnt/rauc/rootfs.1/etc/wpa_supplicant/wpa_supplicant-wlan.conf)" = 600
		test ! -e /var/lib/lubancat-persist-salvage
		# 空 data 目录不能绑到配置路径上。
		mkdir -p /var/lib/containers
		mount -t tmpfs tmpfs /var/lib/containers
		'"$MOUNT"'
		if mountpoint -q /etc/wpa_supplicant; then
			echo "empty persistent dir was bind-mounted" >&2
			exit 1
		fi
		# 跑这一步时新槽上的凭据还在本命名空间的 /etc 里吗?不在,B 的 /etc 仍是空的。
		# 绑定之前 data 也是空的,所以不应该出现挂载。上面已经断言。
	'
	rc=$?
	set -e
	if [ "$rc" -eq 0 ]; then
		ok "空 B 不盖掉 A 上抢救出来的配置,也不绑定空目录"
	else
		bad "空 B 不盖掉 A 上抢救出来的配置,也不绑定空目录"
	fi
else
	echo "  skip 抢救测试:unshare 不可用"
fi

echo "== real blkid: empty GPT partition is not a filesystem"
if ! sudo -n true >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
	bad "需要免密 sudo 和 python3 才能复现空分区上的 blkid"
else
	gpt=$workdir/gpt
	mkdir -p "$gpt"
	python3 - "$gpt" << 'PY'
import struct, sys, uuid, zlib, pathlib
out = pathlib.Path(sys.argv[1])
SS = 512

def crc(b):
    return zlib.crc32(b) & 0xFFFFFFFF

def guid(s):
    return uuid.UUID(s).bytes_le

def header(my, alt, first, last, disk, entry_lba, entries):
    h = bytearray(512)
    h[0:8] = b"EFI PART"
    struct.pack_into("<I", h, 8, 0x00010000)
    struct.pack_into("<I", h, 12, 92)
    struct.pack_into("<Q", h, 24, my)
    struct.pack_into("<Q", h, 32, alt)
    struct.pack_into("<Q", h, 40, first)
    struct.pack_into("<Q", h, 48, last)
    h[56:72] = guid(disk)
    struct.pack_into("<Q", h, 72, entry_lba)
    struct.pack_into("<I", h, 80, 128)
    struct.pack_into("<I", h, 84, 128)
    struct.pack_into("<I", h, 88, crc(entries))
    struct.pack_into("<I", h, 16, crc(bytes(h[:92])))
    return bytes(h)

def entry(start, end, name):
    e = bytearray(128)
    e[0:16] = guid("0fc63daf-8483-4772-8e79-3d69d8477de4")
    e[16:32] = guid(str(uuid.uuid4()))
    struct.pack_into("<Q", e, 32, start)
    struct.pack_into("<Q", e, 40, end)
    nb = name.encode("utf-16le")
    e[56:56+len(nb)] = nb
    return bytes(e)

def entries(items):
    raw = b"".join(items)
    return raw + b"\x00" * (128 * 128 - len(raw))

def build(path, total, part_end):
    disk = str(uuid.uuid4())
    ent = entries([entry(2048, part_end, "data")])
    first, last = 34, total - 34 - 1
    primary = header(1, total - 1, first, last, disk, 2, ent)
    backup_lba = total - 33
    backup = header(total - 1, 1, first, last, disk, backup_lba, ent)
    img = bytearray(total * SS)
    img[510] = 0x55
    img[511] = 0xAA
    img[450] = 0xEE
    struct.pack_into("<I", img, 454, 1)
    struct.pack_into("<I", img, 458, min(total - 1, 0xFFFFFFFF))
    img[SS:2*SS] = primary
    img[2*SS:2*SS+len(ent)] = ent
    img[backup_lba*SS:backup_lba*SS+len(ent)] = ent
    img[(total-1)*SS:(total-1)*SS+512] = backup
    path.write_bytes(img)

total = 16384
build(out / "std.img", total, total - 34 - 1)
build(out / "over.img", total, total - 1)
std = (out / "std.img").read_bytes()
over = (out / "over.img").read_bytes()
(out / "over-part.bin").write_bytes(over[2048*SS:total*SS])
PY
	loops=
	cleanup_loops() {
		for d in $loops; do
			sudo -n losetup -d "$d" 2>/dev/null || true
		done
	}
	trap 'cleanup_loops; rm -rf "$workdir"; rm -rf /tmp/ov-* 2>/dev/null || true' EXIT
	dev=$(sudo -n losetup -f --show "$gpt/std.img")
	loops="$dev"
	sudo -n partx -u "$dev" >/dev/null 2>&1 || sudo -n partx -a "$dev" >/dev/null 2>&1 || true
	if [ ! -b "${dev}p1" ]; then
		bad "标准 GPT 没有分出分区"
	else
		part=${dev}p1
		back=$(sudo -n cat "/sys/block/$(basename "$dev")/loop/backing_file")
		if [ "$back" != "$gpt/std.img" ]; then
			bad "loop 后端不是测试镜像" "$back"
		else
			set +e
			sudo -n blkid -p "$part" >/dev/null 2>&1
			plain=$?
			sudo -n blkid -p -D "$part" >/dev/null 2>&1
			suppressed=$?
			set -e
			if [ "$plain" -eq 0 ] && [ "$suppressed" -eq 2 ]; then
				ok "空分区 blkid -p 退出 0,加 -D 后退出 2"
			else
				bad "空分区 blkid 语义与实测不符" "plain=$plain -D=$suppressed"
			fi
			set +e
			out=$(sudo -n env PATH="/usr/sbin:/usr/bin:/bin" DATA_DEV="$part" "$FMT" 2>&1)
			rc=$?
			set -e
			printf '%s\n' "$out" > "$workdir/last.out"
			label=$(sudo -n blkid -p -D -s LABEL -o value "$part" 2>/dev/null || true)
			if [ "$rc" -eq 0 ] && [ "$label" = data ]; then
				ok "空的 data 分区被格式化一次"
			else
				bad "空的 data 分区被格式化一次" "$out"
			fi
			sudo -n mkdir -p "$gpt/mnt"
			if sudo -n mount "$part" "$gpt/mnt"; then
				echo keep-me | sudo -n tee "$gpt/mnt/marker" >/dev/null
				sudo -n umount "$gpt/mnt"
				set +e
				sudo -n env PATH="/usr/sbin:/usr/bin:/bin" DATA_DEV="$part" "$FMT" >/dev/null 2>&1
				rc=$?
				set -e
				sudo -n mount "$part" "$gpt/mnt"
				if [ "$rc" -eq 0 ] && [ "$(cat "$gpt/mnt/marker")" = keep-me ]; then
					ok "已有数据的 data 分区再次运行不重写"
				else
					bad "已有数据的 data 分区再次运行不重写"
				fi
				sudo -n umount "$gpt/mnt"
				sudo -n mount "$part" "$gpt/mnt"
				set +e
				sudo -n env PATH="/usr/sbin:/usr/bin:/bin" DATA_DEV="$part" "$FMT" >/dev/null 2>&1
				rc=$?
				set -e
				if [ "$rc" -ne 0 ] && [ "$(cat "$gpt/mnt/marker")" = keep-me ]; then
					ok "已挂载时拒绝格式化"
				else
					bad "已挂载时拒绝格式化" "rc=$rc"
				fi
				set +e
				out=$(sudo -n env PATH="/usr/sbin:/usr/bin:/bin" DATA_MNT="$gpt/mnt" "$SEAL" 2>&1)
				rc=$?
				set -e
				echo still | sudo -n tee "$gpt/mnt/more" >/dev/null
				if [ "$rc" -eq 0 ] && [ "$(cat "$gpt/mnt/more")" = still ]; then
					ok "已挂上的 data ext4 不被改成只读"
				else
					bad "已挂上的 data ext4 不被改成只读" "rc=$rc" "$out"
				fi
				sudo -n umount "$gpt/mnt"
			else
				bad "测试分区无法挂载"
			fi
			# 擦回全零后再放一个非 ext 签名和一处中间数据。
			secs=$(cat "/sys/class/block/$(basename "$part")/size")
			sudo -n dd if=/dev/zero of="$part" bs=512 count="$secs" status=none
			printf 'LUKS\272\276\000\001' | sudo -n dd of="$part" bs=1 conv=notrunc status=none
			set +e
			sudo -n env PATH="/usr/sbin:/usr/bin:/bin" DATA_DEV="$part" "$FMT" >/dev/null 2>&1
			rc=$?
			set -e
			kind=$(sudo -n blkid -p -D -s TYPE -o value "$part" 2>/dev/null || true)
			if [ "$rc" -ne 0 ] && [ "$kind" = crypto_LUKS ]; then
				ok "LUKS 签名不格式化"
			else
				bad "LUKS 签名不格式化" "rc=$rc type=$kind"
			fi
			secs=$(cat "/sys/class/block/$(basename "$part")/size")
			sudo -n dd if=/dev/zero of="$part" bs=512 count="$secs" status=none
			printf '\001' | sudo -n dd of="$part" bs=1 seek=2097152 conv=notrunc status=none
			set +e
			sudo -n env PATH="/usr/sbin:/usr/bin:/bin" DATA_DEV="$part" "$FMT" >/dev/null 2>&1
			rc=$?
			set -e
			kind=$(sudo -n blkid -p -D -s TYPE -o value "$part" 2>/dev/null || true)
			byte=$(sudo -n dd if="$part" bs=1 skip=2097152 count=1 status=none | od -An -tu1 | tr -d ' ')
			if [ "$rc" -ne 0 ] && [ -z "$kind" ] && [ "$byte" = 1 ]; then
				ok "无 TYPE 但中间有数据时不格式化"
			else
				bad "无 TYPE 但中间有数据时不格式化" "rc=$rc type=${kind:-<空>} byte=$byte"
			fi
		fi
	fi
	tailfile=$gpt/over-part.bin
	before=$(wc -c < "$tailfile" | tr -d ' ')
	cp "$tailfile" "$gpt/over-copy.bin"
	set +e
	out=$(env PATH="/usr/sbin:/usr/bin:/bin" DATA_FORMAT_ALLOW_FILE=1 DATA_PART_START=2048 DATA_DEV="$gpt/over-copy.bin" "$FMT" 2>&1)
	rc=$?
	set -e
	printf '%s\n' "$out" > "$workdir/last.out"
	label=$(blkid -p -D -s LABEL -o value "$gpt/over-copy.bin" 2>/dev/null || true)
	python3 - "$tailfile" "$gpt/over-copy.bin" << 'PY'
import sys
a=open(sys.argv[1],"rb").read()
b=open(sys.argv[2],"rb").read()
tail=33*512
open("/tmp/data-tail-same","w").write("yes" if a[-tail:]==b[-tail:] and len(a)==len(b) else "no")
PY
	same=$(cat /tmp/data-tail-same)
	rm -f /tmp/data-tail-same
	if [ "$rc" -eq 0 ] && [ "$label" = data ] && [ "$same" = yes ]; then
		ok "只含备份 GPT 尾部的空白分区被格式化且尾部保留"
	else
		bad "只含备份 GPT 尾部的空白分区被格式化且尾部保留" "rc=$rc label=$label tail=$same" "$out"
	fi
	set +e
	out=$(env PATH="/usr/sbin:/usr/bin:/bin" DATA_FORMAT_ALLOW_FILE=1 DATA_PART_START=2048 DATA_DEV="$gpt/over-copy.bin" "$FMT" 2>&1)
	rc=$?
	set -e
	if [ "$rc" -eq 0 ]; then
		ok "备份 GPT 尾部的分区第二次不重写"
	else
		bad "备份 GPT 尾部的分区第二次不重写" "$out"
	fi
	# 校验和坏掉的尾部不能格式化。
	cp "$tailfile" "$gpt/bad-tail.bin"
	dd if=/dev/zero of="$gpt/bad-tail.bin" bs=1 seek=$((before - 512 + 16)) count=4 conv=notrunc status=none
	b=$workdir/bin-bad-tail
	mkdir -p "$b"
	make_fake_mke2fs "$b" 0
	run_format bad-tail PATH="$b:/usr/sbin:/usr/bin:/bin" DATA_FORMAT_ALLOW_FILE=1 DATA_PART_START=2048 DATA_DEV="$gpt/bad-tail.bin"
	if [ "$RUN_RC" -ne 0 ] && [ ! -s "$b/mke2fs.log" ]; then
		ok "备份 GPT 校验失败时不格式化"
	else
		bad "备份 GPT 校验失败时不格式化" "$(cat "$workdir/last.out")"
	fi
	noperm=$gpt/noperm.bin
	dd if=/dev/zero of="$noperm" bs=1048576 count=2 status=none
	chmod 000 "$noperm"
	b=$workdir/bin-io
	mkdir -p "$b"
	make_fake_mke2fs "$b" 0
	run_format io PATH="$b:/usr/sbin:/usr/bin:/bin" DATA_FORMAT_ALLOW_FILE=1 DATA_DEV="$noperm"
	chmod 644 "$noperm" || true
	if [ "$RUN_RC" -ne 0 ] && [ ! -s "$b/mke2fs.log" ]; then
		ok "读不到设备时不格式化"
	else
		bad "读不到设备时不格式化" "$(cat "$workdir/last.out")"
	fi
fi

echo "== data unavailable is sealed read-only"
if unshare --user --map-root-user --mount true >/dev/null 2>&1; then
	set +e
	unshare --user --map-root-user --mount sh -c '
		set -eu
		mount -t tmpfs tmpfs /var
		mkdir -p /var/lib/containers/payload
		echo spill > /var/lib/containers/payload/x
		set +e
		'"$SEAL"'
		rc=$?
		set -e
		test "$rc" -ne 0
		if touch /var/lib/containers/payload/y 2>/dev/null; then
			echo "unsealed directory accepted a write" >&2
			exit 1
		fi
		umount /var/lib/containers
		mkdir -p /var/lib/containers
		mount -t tmpfs tmpfs /var/lib/containers
		set +e
		'"$SEAL"'
		rc=$?
		set -e
		test "$rc" -ne 0
		if touch /var/lib/containers/z 2>/dev/null; then
			echo "wrong mount stayed writable" >&2
			exit 1
		fi
	'
	rc=$?
	set -e
	if [ "$rc" -eq 0 ]; then
		ok "data 不可用时目录或错误挂载变为只读"
	else
		bad "data 不可用时目录或错误挂载变为只读"
	fi
else
	echo "  skip 封闭测试:unshare 不可用"
fi

echo "== format-data 在 poky BusyBox 1.36.1 下"
# Ubuntu 的 busybox 包打开了 CONFIG_DESKTOP 和 CONFIG_FEATURE_DD_STATUS,
# 用它测不出板上的失败。这里按 scarthgap defconfig 另编一份:关掉这两项,
# 也关掉 CONFIG_FEATURE_DD_IBS_OBS,打开 hexdump 和 awk libm。
pbb_usable() {
	bin=$1
	[ -x "$bin" ] || return 1
	if printf x | "$bin" dd status=none >/dev/null 2>&1; then
		return 1
	fi
	if "$bin" od -An "$bin" >/dev/null 2>&1; then
		return 1
	fi
	got=$("$bin" awk 'BEGIN { printf "%.0f", 4294967295 }') || return 1
	[ "$got" = 4294967295 ]
}

build_poky_busybox() {
	cache=/tmp/lubancat-busybox-1.36.1-poky
	bin=$cache/busybox
	if pbb_usable "$bin"; then
		printf '%s\n' "$bin"
		return 0
	fi
	if ! command -v gcc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
		echo "缺少 gcc、make 或 curl,无法编 BusyBox" >&2
		return 1
	fi
	mkdir -p "$cache"
	tar=$cache/busybox-1.36.1.tar.bz2
	if [ ! -s "$tar" ]; then
		if ! curl -fsSL --retry 3 -o "$tar.part" https://busybox.net/downloads/busybox-1.36.1.tar.bz2; then
			if ! curl -fsSL --retry 3 -o "$tar.part" http://archive.ubuntu.com/ubuntu/pool/main/b/busybox/busybox_1.36.1.orig.tar.bz2; then
				echo "下载 BusyBox 1.36.1 失败" >&2
				return 1
			fi
		fi
		mv "$tar.part" "$tar"
	fi
	src=$cache/busybox-1.36.1
	if [ ! -f "$src/Makefile" ]; then
		rm -rf "$src"
		tar -xjf "$tar" -C "$cache"
	fi
	if ! (
		set -eu
		cd "$src"
		make allnoconfig </dev/null >"$cache/build.log" 2>&1
		enable() {
			key=$1
			if grep -q "^${key}=y$" .config; then
				return 0
			fi
			if grep -q "^# ${key} is not set$" .config; then
				sed -i "s/^# ${key} is not set$/${key}=y/" .config
			else
				echo "${key}=y" >> .config
			fi
		}
		disable() {
			key=$1
			if grep -q "^# ${key} is not set$" .config; then
				return 0
			fi
			if grep -q "^${key}=y$" .config; then
				sed -i "s/^${key}=y$/# ${key} is not set/" .config
			else
				echo "# ${key} is not set" >> .config
			fi
		}
		for key in CONFIG_STATIC CONFIG_LFS CONFIG_BUSYBOX \
			CONFIG_DD CONFIG_FEATURE_DD_SIGNAL_HANDLING \
			CONFIG_OD CONFIG_HEXDUMP \
			CONFIG_TR CONFIG_FEATURE_TR_CLASSES \
			CONFIG_WC CONFIG_AWK CONFIG_FEATURE_AWK_LIBM CONFIG_FEATURE_AWK_GNU_EXTENSIONS \
			CONFIG_GREP CONFIG_MKTEMP; do
			enable "$key"
		done
		for key in CONFIG_DESKTOP CONFIG_FEATURE_DD_THIRD_STATUS_LINE \
			CONFIG_FEATURE_DD_IBS_OBS CONFIG_FEATURE_DD_STATUS \
			CONFIG_FEATURE_WC_LARGE; do
			disable "$key"
		done
		make oldconfig </dev/null >>"$cache/build.log" 2>&1
		if grep -q '^CONFIG_DESKTOP=y$' .config \
			|| grep -q '^CONFIG_FEATURE_DD_STATUS=y$' .config \
			|| grep -q '^CONFIG_FEATURE_DD_IBS_OBS=y$' .config; then
			echo "BusyBox 配置被打开了 DESKTOP 或 dd status/ibs" >&2
			return 1
		fi
		sleep 1
		jobs=$(nproc 2>/dev/null || echo 1)
		make -j"$jobs" >>"$cache/build.log" 2>&1
	); then
		echo "编译 BusyBox 失败,日志 $cache/build.log" >&2
		tail -n 40 "$cache/build.log" >&2 || true
		return 1
	fi
	cp "$src/busybox" "$bin"
	chmod 0755 "$bin"
	if ! pbb_usable "$bin"; then
		echo "编出来的 BusyBox 仍接受 status= 或 od -A,或 awk 整数被钳位" >&2
		return 1
	fi
	printf '%s\n' "$bin"
}

if ! bb=$(build_poky_busybox); then
	bad "编出 poky 配置的 BusyBox 1.36.1"
else
	ok "编出 poky 配置的 BusyBox 1.36.1"
	bbin=$workdir/poky-bb
	mkdir -p "$bbin"
	for applet in dd od awk tr grep wc hexdump mktemp; do
		ln -sf "$bb" "$bbin/$applet"
	done
	bb_path="$bbin:/usr/sbin:/usr/bin:/sbin:/bin"
	if printf x | env PATH="$bb_path" dd status=none >/dev/null 2>&1; then
		bad "测试 PATH 上的 dd 拒绝 status="
	else
		ok "测试 PATH 上的 dd 拒绝 status="
	fi
	if env PATH="$bb_path" od -An -tu1 "$bb" >/dev/null 2>&1; then
		bad "测试 PATH 上的 od 拒绝 -A/-t"
	else
		ok "测试 PATH 上的 od 拒绝 -A/-t"
	fi

	bb_blank=$workdir/bb-blank
	mkdir -p "$bb_blank"
	make_fake_mke2fs "$bb_blank" 0
	make_fake_blkid "$bb_blank" 2
	blank=$workdir/bb-blank.img
	zero_file "$blank"
	run_format "busybox 空白文件" \
		PATH="$bb_blank:$bb_path" \
		DATA_FORMAT_ALLOW_FILE=1 \
		DATA_DEV="$blank"
	if [ "$RUN_RC" -eq 0 ] && [ -s "$bb_blank/mke2fs.log" ]; then
		ok "BusyBox 下空白文件会格式化"
	else
		bad "BusyBox 下空白文件会格式化" "$(cat "$workdir/last.out")"
	fi

	bb_magic=$workdir/bb-magic
	mkdir -p "$bb_magic"
	make_fake_mke2fs "$bb_magic" 0
	make_fake_blkid "$bb_magic" 2
	magicf=$workdir/bb-magic.img
	zero_file "$magicf"
	printf '\x53\xef' | dd of="$magicf" bs=1 seek=1080 conv=notrunc status=none
	run_format "busybox ext 魔数" \
		PATH="$bb_magic:$bb_path" \
		DATA_FORMAT_ALLOW_FILE=1 \
		DATA_DEV="$magicf"
	if [ "$RUN_RC" -ne 0 ] && [ ! -s "$bb_magic/mke2fs.log" ]; then
		ok "BusyBox 下 ext 魔数不格式化"
	else
		bad "BusyBox 下 ext 魔数不格式化" "$(cat "$workdir/last.out")"
	fi

	bb_nz=$workdir/bb-nz
	mkdir -p "$bb_nz"
	make_fake_mke2fs "$bb_nz" 0
	make_fake_blkid "$bb_nz" 2
	nz=$workdir/bb-nz.img
	zero_file "$nz"
	printf '\001' | dd of="$nz" bs=1 seek=100 conv=notrunc status=none
	run_format "busybox 非零" \
		PATH="$bb_nz:$bb_path" \
		DATA_FORMAT_ALLOW_FILE=1 \
		DATA_DEV="$nz"
	if [ "$RUN_RC" -ne 0 ] && [ ! -s "$bb_nz/mke2fs.log" ]; then
		ok "BusyBox 下非零字节不格式化"
	else
		bad "BusyBox 下非零字节不格式化" "$(cat "$workdir/last.out")"
	fi

	if ! command -v mke2fs >/dev/null 2>&1 || ! command -v blkid >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
		bad "BusyBox GPT 尾部测试需要 mke2fs、blkid 和 python3"
	else
		gptbb=$workdir/gpt-bb
		mkdir -p "$gptbb"
		python3 - "$gptbb" << 'PY'
import struct, sys, uuid, zlib, pathlib
out = pathlib.Path(sys.argv[1])
SS = 512

def crc(b):
    return zlib.crc32(b) & 0xFFFFFFFF

def guid(s):
    return uuid.UUID(s).bytes_le

def header(my, alt, first, last, disk, entry_lba, entries):
    h = bytearray(512)
    h[0:8] = b"EFI PART"
    struct.pack_into("<I", h, 8, 0x00010000)
    struct.pack_into("<I", h, 12, 92)
    struct.pack_into("<Q", h, 24, my)
    struct.pack_into("<Q", h, 32, alt)
    struct.pack_into("<Q", h, 40, first)
    struct.pack_into("<Q", h, 48, last)
    h[56:72] = guid(disk)
    struct.pack_into("<Q", h, 72, entry_lba)
    struct.pack_into("<I", h, 80, 128)
    struct.pack_into("<I", h, 84, 128)
    struct.pack_into("<I", h, 88, crc(entries))
    struct.pack_into("<I", h, 16, crc(bytes(h[:92])))
    return bytes(h)

def entry(start, end, name):
    e = bytearray(128)
    e[0:16] = guid("0fc63daf-8483-4772-8e79-3d69d8477de4")
    e[16:32] = guid(str(uuid.uuid4()))
    struct.pack_into("<Q", e, 32, start)
    struct.pack_into("<Q", e, 40, end)
    nb = name.encode("utf-16le")
    e[56:56+len(nb)] = nb
    return bytes(e)

def entries(items):
    raw = b"".join(items)
    return raw + b"\x00" * (128 * 128 - len(raw))

total = 16384
part_start = 2048
# 分区一直铺到盘尾,末尾 33 扇区是备份 GPT。挑一个头 CRC >= 2^31 的盘 GUID,
# BusyBox awk 的 printf %u 会把这种值钳成 2147483648。
ent = entries([entry(part_start, total - 34 - 1, "data")])
picked = None
for n in range(1, 10001):
    disk = str(uuid.UUID(int=n))
    backup = header(total - 1, 1, 34, total - 34 - 1, disk, total - 33, ent)
    stored = struct.unpack_from("<I", backup, 16)[0]
    if stored >= 2**31:
        picked = (disk, backup, stored)
        break
if picked is None:
    raise SystemExit("no high header crc")
disk, backup, stored = picked
img = bytearray(total * SS)
img[(total - 33) * SS:(total - 33) * SS + len(ent)] = ent
img[(total - 1) * SS:(total - 1) * SS + 512] = backup
part = bytes(img[part_start * SS:total * SS])
(out / "over-part.bin").write_bytes(part)
(out / "crc.txt").write_text(str(stored))
PY
		crc_hi=$(cat "$gptbb/crc.txt")
		if [ "$crc_hi" -ge 2147483648 ]; then
			ok "备份 GPT 头 CRC 落在 BusyBox %u 会钳位的范围 ($crc_hi)"
		else
			bad "备份 GPT 头 CRC 落在 BusyBox %u 会钳位的范围" "$crc_hi"
		fi
		cp "$gptbb/over-part.bin" "$gptbb/over-copy.bin"
		set +e
		out=$(env PATH="$bb_path" DATA_FORMAT_ALLOW_FILE=1 DATA_PART_START=2048 DATA_DEV="$gptbb/over-copy.bin" "$FMT" 2>&1)
		rc=$?
		set -e
		printf '%s\n' "$out" > "$workdir/last.out"
		label=$(blkid -p -D -s LABEL -o value "$gptbb/over-copy.bin" 2>/dev/null || true)
		python3 - "$gptbb/over-part.bin" "$gptbb/over-copy.bin" "$gptbb/tail.txt" << 'PY'
import sys
a = open(sys.argv[1], "rb").read()
b = open(sys.argv[2], "rb").read()
tail = 33 * 512
open(sys.argv[3], "w").write("yes" if a[-tail:] == b[-tail:] and len(a) == len(b) else "no")
PY
		same=$(cat "$gptbb/tail.txt")
		if [ "$rc" -eq 0 ] && [ "$label" = data ] && [ "$same" = yes ]; then
			ok "BusyBox 下高 CRC 的备份 GPT 尾部被保留"
		else
			bad "BusyBox 下高 CRC 的备份 GPT 尾部被保留" "rc=$rc label=$label tail=$same" "$out"
		fi
		cp "$gptbb/over-part.bin" "$gptbb/bad-tail.bin"
		before=$(wc -c < "$gptbb/bad-tail.bin" | tr -d ' ')
		dd if=/dev/zero of="$gptbb/bad-tail.bin" bs=1 seek=$((before - 512 + 16)) count=4 conv=notrunc status=none
		bb_bad=$workdir/bb-bad-tail
		mkdir -p "$bb_bad"
		make_fake_mke2fs "$bb_bad" 0
		run_format "busybox 坏 GPT" \
			PATH="$bb_bad:$bb_path" \
			DATA_FORMAT_ALLOW_FILE=1 \
			DATA_PART_START=2048 \
			DATA_DEV="$gptbb/bad-tail.bin"
		if [ "$RUN_RC" -ne 0 ] && [ ! -s "$bb_bad/mke2fs.log" ]; then
			ok "BusyBox 下备份 GPT 校验失败时不格式化"
		else
			bad "BusyBox 下备份 GPT 校验失败时不格式化" "$(cat "$workdir/last.out")"
		fi
	fi
fi

echo
echo "通过 $pass,失败标记 $fail"
[ "$fail" -eq 0 ]
