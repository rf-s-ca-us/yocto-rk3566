#!/bin/sh
# 不跑 Yocto。只验证:文档路径分类,以及内核配置自查在
# workdir / ipk / sstate 三种落点上的成败。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
fail=0

expect() {
	name=$1
	want=$2
	shift 2
	set +e
	"$@" >/tmp/ci-guard.out 2>&1
	got=$?
	set -e
	if [ "$got" -eq "$want" ]; then
		printf '  ok   %s\n' "$name"
	else
		printf '  FAIL %s (exit %s, want %s)\n' "$name" "$got" "$want"
		sed 's/^/       | /' /tmp/ci-guard.out
		fail=1
	fi
}

echo "== docs-only-change"
expect "仅 docs 指针" 0 sh -c 'printf "%s\n" docs | ci/docs-only-change.sh'
expect "仅 markdown" 0 sh -c 'printf "%s\n" README.md meta-lubancat/README.md | ci/docs-only-change.sh'
expect "LICENSE 与 LICENSES" 0 sh -c 'printf "%s\n" LICENSE LICENSES/README | ci/docs-only-change.sh'
expect "docs 加配方" 1 sh -c 'printf "%s\n" docs meta-lubancat/recipes-kernel/linux/files/ota.cfg | ci/docs-only-change.sh'
expect "workflow" 1 sh -c 'printf "%s\n" .github/workflows/build.yml | ci/docs-only-change.sh'
expect "u-boot bbappend" 1 sh -c 'printf "%s\n" meta-lubancat/recipes-bsp/u-boot/u-boot-rockchip.bbappend | ci/docs-only-change.sh'
expect "OTA 脚本" 1 sh -c 'printf "%s\n" meta-lubancat/recipes-core/ota/files/ota-update | ci/docs-only-change.sh'
expect "空列表" 1 sh -c 'printf "" | ci/docs-only-change.sh'
expect "子目录 LICENSE 不算根 LICENSE*" 1 sh -c 'printf "%s\n" foo/LICENSE | ci/docs-only-change.sh'

echo "== classify-image-build"
out=$(mktemp)
expect "push 纯文档" 0 env EVENT_NAME=push CHANGED_FILES="docs
README.md" GITHUB_OUTPUT="$out" ci/classify-image-build.sh
grep -q '^build_image=false$' "$out" || { echo "  FAIL classify 没写出 false"; fail=1; }
: > "$out"
expect "手动触发仍构建" 0 env EVENT_NAME=workflow_dispatch CHANGED_FILES=docs GITHUB_OUTPUT="$out" ci/classify-image-build.sh
grep -q '^build_image=true$' "$out" || { echo "  FAIL dispatch 没写出 true"; fail=1; }
: > "$out"
expect "push 含配方" 0 env EVENT_NAME=push CHANGED_FILES="docs
setup.sh" GITHUB_OUTPUT="$out" ci/classify-image-build.sh
grep -q '^build_image=true$' "$out" || { echo "  FAIL 混合变更没写出 true"; fail=1; }
rm -f "$out"

echo "== kernel config"
frag_c=$ROOT/meta-lubancat/recipes-kernel/linux/files/container.cfg
frag_o=$ROOT/meta-lubancat/recipes-kernel/linux/files/ota.cfg
good=$(mktemp)
{
	sed -n 's/^\(CONFIG_[A-Z0-9_]*\)=y.*/\1=y/p' "$frag_c" "$frag_o"
	sed -n 's/^\(CONFIG_[A-Z0-9_]*\)=\([0-9][0-9]*\).*/\1=\2/p' "$frag_c" "$frag_o"
} > "$good"
bad=$(mktemp)
grep -v '^CONFIG_DM_VERITY=' "$good" > "$bad"

fix=$(mktemp -d)
mkdir -p "$fix/build/tmp/work/linux-rockchip/6.1/linux-rockchip-6.1/linux-rk3566-standard-build"
cp "$good" "$fix/build/tmp/work/linux-rockchip/6.1/linux-rockchip-6.1/linux-rk3566-standard-build/.config"
expect "workdir 命中且项齐" 0 env WORK_ROOT="$fix" BITBAKE_CODE=0 ci/check-kernel-config.sh

mkdir -p "$fix/build/sstate-cache/aa"
sstate_root=$(mktemp -d)
mkdir -p "$sstate_root/packages-split/kernel-dev/boot"
# 坏配置放进 sstate;workdir 里仍是好配置,必须优先用 workdir。
cp "$bad" "$sstate_root/packages-split/kernel-dev/boot/config-6.1.0"
tar -czf "$fix/build/sstate-cache/aa/sstate:linux-rockchip:aarch64:6.1:r0:rk3566_lubancat:abc_package.tar.gz" -C "$sstate_root" packages-split
expect "workdir 优先于坏的 sstate" 0 env WORK_ROOT="$fix" BITBAKE_CODE=0 ci/check-kernel-config.sh
rm -rf "$fix" "$sstate_root"

ipkroot=$(mktemp -d)
mkdir -p "$ipkroot/tree/boot" "$ipkroot/build/tmp/deploy/ipk/rk3566_lubancat" "$ipkroot/empty"
cp "$good" "$ipkroot/tree/boot/config-6.1.84-rockchip"
tar -C "$ipkroot/tree" -cf "$ipkroot/data.tar" .
printf '2.0\n' > "$ipkroot/debian-binary"
tar -C "$ipkroot/empty" -cf "$ipkroot/control.tar" --files-from /dev/null
ar r "$ipkroot/build/tmp/deploy/ipk/rk3566_lubancat/kernel-dev_6.1-r0_rk3566_lubancat.ipk" \
	"$ipkroot/debian-binary" "$ipkroot/control.tar" "$ipkroot/data.tar" >/dev/null
expect "仅 ipk(模拟 sstate 命中)项齐" 0 env WORK_ROOT="$ipkroot" BITBAKE_CODE=0 ci/check-kernel-config.sh
rm -rf "$ipkroot"

ss=$(mktemp -d)
mkdir -p "$ss/payload/packages-split/kernel-dev/boot" "$ss/build/sstate-cache/bb"
cp "$bad" "$ss/payload/packages-split/kernel-dev/boot/config-6.1.0"
tar -czf "$ss/build/sstate-cache/bb/sstate:linux-rockchip::6.1:r0::rk3566_lubancat:def_package.tar.gz" \
	-C "$ss/payload" packages-split
expect "仅 sstate 且缺 DM_VERITY" 1 env WORK_ROOT="$ss" BITBAKE_CODE=0 ci/check-kernel-config.sh
rm -rf "$ss"

empty=$(mktemp -d)
expect "构建成功但没有任何 .config" 1 env WORK_ROOT="$empty" BITBAKE_CODE=0 ci/check-kernel-config.sh
expect "墙钟到点且没有 .config" 0 env WORK_ROOT="$empty" BITBAKE_CODE=124 ci/check-kernel-config.sh
rm -rf "$empty"
rm -f "$good" "$bad"

echo "== workflow 接线"
grep -q 'ci/check-kernel-config.sh' .github/workflows/build.yml
grep -q 'needs: gate' .github/workflows/build.yml
grep -q "build_image == 'true'" .github/workflows/build.yml
grep -q "paths-ignore: \['\*\*.md', 'LICENSE\*', 'LICENSES/\*\*', 'docs', 'docs/\*\*'\]" .github/workflows/build.yml
# 旧的「缓存命中就跳过」不能再出现。
if grep -q '跳过内核配置自查(输入与上轮相同)' .github/workflows/build.yml; then
	echo "  FAIL workflow 仍含跳过自查的旧分支"
	fail=1
else
	echo "  ok   已去掉缓存命中跳过"
fi

if [ "$fail" -ne 0 ]; then
	echo "FAILED"
	exit 1
fi
echo "ok"
