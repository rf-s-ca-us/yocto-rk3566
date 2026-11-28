#!/bin/sh
# 不跑 Yocto。核对槽位真源、生成余量,以及超大 rootfs 会让检查失败。
set -eu

# CDPATH= 只作用于这一次 cd。
# shellcheck disable=SC1007
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
fail=0

expect() {
	name=$1
	want=$2
	shift 2
	set +e
	"$@" >/tmp/rootfs-slot.out 2>/tmp/rootfs-slot.err
	got=$?
	set -e
	if [ "$got" -eq "$want" ]; then
		printf '  ok   %s\n' "$name"
	else
		printf '  FAIL %s (exit %s, want %s)\n' "$name" "$got" "$want"
		sed 's/^/       | /' /tmp/rootfs-slot.err /tmp/rootfs-slot.out
		fail=1
	fi
}

CHECK=$ROOT/ci/check-rootfs-slot.sh
WKS=$ROOT/meta-lubancat/wic/lubancat-ab.wks.in
RECIPE=$ROOT/meta-lubancat/recipes-core/images/lubancat-image-minimal.bb
FRAG=$ROOT/meta-lubancat/recipes-kernel/linux/files/ota.cfg

# 13459188 扇区 × 512。已烧录板子的 mmcblk0p3 / p4。
SLOT_BYTES=6891104256
MARGIN_KIB=16384
SYSTEMD_EXTRA_KIB=4096

echo "== wks 真源"
limit=$(sh "$CHECK" --print-limit)
if [ "$limit" = "$SLOT_BYTES" ]; then
	printf '  ok   槽位 %s 字节\n' "$limit"
else
	printf '  FAIL 槽位解析得到 %s,想要 %s\n' "$limit" "$SLOT_BYTES"
	fail=1
fi

# 注释里的另一个 --fixed-size 不能把真源带跑。
noted=$(mktemp)
{
	echo "# 不要把这行当槽位 --fixed-size 1k"
	echo "part / --part-name data --size 2G"
	cat "$WKS"
} > "$noted"
noted_limit=$(sh "$CHECK" --wks "$noted" --print-limit)
if [ "$noted_limit" = "$SLOT_BYTES" ]; then
	echo "  ok   注释和 data 分区不改变槽位"
else
	printf '  FAIL 注释干扰后槽位变成 %s\n' "$noted_limit"
	fail=1
fi
rm -f "$noted"

echo "== 超大镜像失败,卡在槽位上仍通过"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/empty"
# 稀疏文件,不占 6 GiB 磁盘。
truncate -s "$SLOT_BYTES" "$tmp/exact"
truncate -s $((SLOT_BYTES + 1)) "$tmp/over-one"
truncate -s $((SLOT_BYTES + 16384)) "$tmp/over-16k"
truncate -s $((SLOT_BYTES - MARGIN_KIB * 1024)) "$tmp/margin"

expect "空文件(没有超过槽)" 0 sh "$CHECK" --image "$tmp/empty"
expect "正好等于槽位" 0 sh "$CHECK" --image "$tmp/exact"
expect "比槽大 1 字节" 1 sh "$CHECK" --image "$tmp/over-one"
expect "93-c5411847 那种大 16 KiB" 1 sh "$CHECK" --image "$tmp/over-16k"
expect "槽位减 16 MiB" 0 sh "$CHECK" --image "$tmp/margin"
expect "软链量的是目标文件" 1 sh -c "ln -s over-16k '$tmp/link' && '$CHECK' --image '$tmp/link'"

small=$tmp/small.wks
cat > "$small" << 'EOF'
# --fixed-size 99999k 在注释里
part / --part-name rootfs_a --fixed-size 2048k --align 8192
part / --part-name rootfs_b --fixed-size 2048k --align 8192
part /var/lib/containers --part-name data --size 2G
EOF
truncate -s 2097152 "$tmp/fits"
truncate -s 2097153 "$tmp/spills"
expect "小槽位按 wks 而不是写死的字节数通过" 0 sh "$CHECK" --wks "$small" --image "$tmp/fits"
expect "小槽位按 wks 而不是写死的字节数失败" 1 sh "$CHECK" --wks "$small" --image "$tmp/spills"

bad=$tmp/bad.wks
cat > "$bad" << 'EOF'
part / --part-name rootfs_a --fixed-size 2048k
part / --part-name rootfs_b --fixed-size 4096k
EOF
expect "两槽 fixed-size 不一致" 1 sh "$CHECK" --wks "$bad" --print-limit

nofixed=$tmp/nofixed.wks
cat > "$nofixed" << 'EOF'
part / --part-name rootfs_a --overhead-factor 1 --extra-space 0
part / --part-name rootfs_b --fixed-size 2048k
EOF
expect "缺 fixed-size" 1 sh "$CHECK" --wks "$nofixed" --print-limit

dump=$tmp/sfdisk.txt
cat > "$dump" << EOF
label: gpt
unit: sectors
/dev/mmcblk0p3 : start=1, size=$((SLOT_BYTES / 512)), type=L, name="rootfs_a"
/dev/mmcblk0p4 : start=2, size=$((SLOT_BYTES / 512)), type=L, name="rootfs_b"
/dev/mmcblk0p5 : start=3, size=4096, type=L, name="data"
EOF
expect "GPT 扇区数等于真源" 0 sh "$CHECK" --sfdisk-dump "$dump"
short=$tmp/short.txt
sed 's/size=13459188/size=13459187/' "$dump" > "$short"
expect "GPT 比真源少 1 扇区" 1 sh "$CHECK" --sfdisk-dump "$short"

echo "== 生成余量"
if grep -q '4194304' "$RECIPE"; then
	echo "  FAIL image recipe 仍在追加 4 GiB,ext4 还会跟着内容涨出槽外"
	fail=1
else
	echo "  ok   不再追加 4 GiB"
fi
if grep -q 'LUBANCAT_ROOTFS_SLOT_MARGIN_KIB = "16384"' "$RECIPE" \
	&& grep -q 'LUBANCAT_ROOTFS_SYSTEMD_EXTRA_KIB = "4096"' "$RECIPE" \
	&& grep -q 'd.setVar("IMAGE_ROOTFS_MAXSIZE", str(slot))' "$RECIPE" \
	&& grep -q 'd.setVar("IMAGE_ROOTFS_SIZE", str(image_kib))' "$RECIPE" \
	&& grep -q 'image_kib = slot - margin - systemd_extra' "$RECIPE" \
	&& grep -q '../../wic/lubancat-ab.wks.in' "$RECIPE"; then
	echo "  ok   下限 = 槽位 - 16 MiB - systemd 4096,上限 = 槽位"
else
	echo "  FAIL image recipe 没有按槽位和 16 MiB 余量设置 ROOTFS_SIZE"
	fail=1
fi

slot_kib=$((SLOT_BYTES / 1024))
image_kib=$((slot_kib - MARGIN_KIB - SYSTEMD_EXTRA_KIB))
final_kib=$((image_kib + SYSTEMD_EXTRA_KIB))
final_bytes=$((final_kib * 1024))
room=$((SLOT_BYTES - final_bytes))
if [ "$final_kib" -lt "$slot_kib" ] && [ "$room" -eq $((MARGIN_KIB * 1024)) ]; then
	printf '  ok   生成目标 %s 字节,比槽小 %s 字节\n' "$final_bytes" "$room"
else
	printf '  FAIL 生成目标 %s,余量 %s,槽 %s\n' "$final_bytes" "$room" "$SLOT_BYTES"
	fail=1
fi

# recipe 相对路径真能打开这份 wks。
recipe_wks=$ROOT/meta-lubancat/recipes-core/images/../../wic/lubancat-ab.wks.in
# shellcheck disable=SC1007
recipe_wks_dir=$(CDPATH= cd -- "$(dirname "$recipe_wks")" && pwd)
if [ "$recipe_wks_dir/$(basename "$recipe_wks")" = "$WKS" ]; then
	echo "  ok   recipe 里的 wks 相对路径指向真源"
else
	echo "  FAIL recipe 的 wks 相对路径对不上"
	fail=1
fi

echo "== NBD 必须编进内核"
if grep -qx 'CONFIG_BLK_DEV_NBD=y' "$FRAG" && grep -qx 'CONFIG_BLK_DEV=y' "$FRAG"; then
	echo "  ok   ota.cfg 要求 CONFIG_BLK_DEV_NBD=y"
else
	echo "  FAIL ota.cfg 没有把 CONFIG_BLK_DEV_NBD 设成 =y"
	fail=1
fi
if grep -q '^CONFIG_BLK_DEV_NBD=m' "$FRAG"; then
	echo "  FAIL NBD 是模块,流式安装不会先 modprobe"
	fail=1
else
	echo "  ok   NBD 不是模块"
fi

echo "== workflow 接线"
if grep -q 'ci/check-rootfs-slot.sh' .github/workflows/build.yml \
	&& grep -q 'ci/test-rootfs-slot.sh' .github/workflows/build.yml; then
	echo "  ok   构建与 gate 都会跑槽位检查"
else
	echo "  FAIL workflow 没有接上槽位检查"
	fail=1
fi

rm -f /tmp/rootfs-slot.out /tmp/rootfs-slot.err

if [ "$fail" -ne 0 ]; then
	echo "FAILED"
	exit 1
fi
echo "ok"
