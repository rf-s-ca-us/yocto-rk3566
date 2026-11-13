#!/bin/sh
# 断言最终内核 .config 含 container.cfg 与 ota.cfg 要求的项。
#
# 真编译时 .config 在 linux-rockchip 的 standard-build/。内核配方被
# rm_work 自动排除(poky rm_work.bbclass 的 inject_rm_work),所以编译过
# 的话文件还在。sstate 全命中时 do_configure 不跑,workdir 没有它;
# do_shared_workdir 的 setscene 固定 exit 1,work-shared 也不会还原。
# do_install 会把同一份 .config 装进 kernel-dev 的 /boot/config-*,
# package_write 的 setscene 把它放进 deploy,sstate 包里也有。
# BITBAKE_CODE=0 却一处都找不到 → 失败,不许跳过。
#
# WORK_ROOT 默认当前目录(CI 在仓根,构建树在 ./build)。
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=${WORK_ROOT:-.}
case "$ROOT" in
/*) ;;
*) ROOT=$(CDPATH= cd -- "$ROOT" && pwd) ;;
esac

FRAG_CONTAINER=$REPO/meta-lubancat/recipes-kernel/linux/files/container.cfg
FRAG_OTA=$REPO/meta-lubancat/recipes-kernel/linux/files/ota.cfg
CODE=${BITBAKE_CODE:-}
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

note() { printf '%s\n' "$*" >&2; }

first_match() {
	root=$1
	pattern=$2
	[ -d "$root" ] || return 1
	find "$root" -type f -path "$pattern" -print -quit 2>/dev/null
}

extract_archive() {
	ball=$1
	dest=$2
	mkdir -p "$dest"
	# 没有匹配成员时 tar 非 0;成败看后面找不找得到文件。
	set +e
	case "$ball" in
	*.zst | *.tzst)
		if ! command -v zstd >/dev/null 2>&1; then
			note "::error::需要 zstd 才能从 $ball 取出 .config"
			set -e
			return 1
		fi
		zstd -dc "$ball" | tar -x -C "$dest" --wildcards --no-anchored -f - \
			'*/kernel-dev/boot/config-*' \
			'*/boot/config-*' \
			'*standard-build/.config' \
			'*/kernel-build-artifacts/.config'
		;;
	*)
		tar -x -C "$dest" -f "$ball" --wildcards --no-anchored \
			'*/kernel-dev/boot/config-*' \
			'*/boot/config-*' \
			'*standard-build/.config' \
			'*/kernel-build-artifacts/.config'
		;;
	esac
	set -e
	return 0
}

extract_rpm() {
	rpm=$1
	dest=$2
	mkdir -p "$dest"
	if command -v rpm2cpio >/dev/null 2>&1; then
		# 成员名是 ./boot/config-$version,不靠 glob 猜。kernel-dev 不含整棵源码树。
		set +e
		(cd "$dest" && rpm2cpio "$rpm" | cpio -idm >/dev/null)
		rc=$?
		set -e
		[ "$rc" -le 1 ] || return 1
		return 0
	fi
	if command -v bsdtar >/dev/null 2>&1; then
		bsdtar -xf "$rpm" -C "$dest"
		return 0
	fi
	note "::error::找到 $rpm 但没有 rpm2cpio 或 bsdtar,读不出 .config"
	return 1
}

extract_ar_data() {
	pkg=$1
	dest=$2
	unpacked=$dest/unpacked
	root=$dest/root
	mkdir -p "$unpacked" "$root"
	(cd "$unpacked" && ar x "$pkg")
	data=$(find "$unpacked" -name 'data.tar*' -type f -print -quit)
	[ -n "$data" ] || return 1
	case "$data" in
	*.gz) tar -xzf "$data" -C "$root" ;;
	*.xz) tar -xJf "$data" -C "$root" ;;
	*.zst)
		command -v zstd >/dev/null 2>&1 || return 1
		zstd -dc "$data" | tar -x -C "$root"
		;;
	*) tar -xf "$data" -C "$root" ;;
	esac
	first_match "$root" '*/boot/config-*' || first_match "$root" '*/.config'
}

# 按「更接近这次编译」的顺序找。stdout 只打路径。
locate() {
	cfg=$(first_match "$ROOT/build/tmp/work" '*standard-build/.config' || true)
	if [ -n "$cfg" ]; then
		note "内核配置来源:workdir $cfg"
		printf '%s\n' "$cfg"
		return 0
	fi
	cfg=$(first_match "$ROOT/build/tmp/work-shared" '*/kernel-build-artifacts/.config' || true)
	if [ -n "$cfg" ]; then
		note "内核配置来源:work-shared $cfg"
		printf '%s\n' "$cfg"
		return 0
	fi
	cfg=$(first_match "$ROOT/build/tmp/work" '*/kernel-dev/boot/config-*' || true)
	if [ -n "$cfg" ]; then
		note "内核配置来源:packages-split $cfg"
		printf '%s\n' "$cfg"
		return 0
	fi

	deploy=$ROOT/build/tmp/deploy
	if [ -d "$deploy" ]; then
		find "$deploy" -type f \( -name 'kernel-dev-*.rpm' -o -name 'kernel-dev_*.ipk' -o -name 'kernel-dev_*.deb' \) -printf '%T@ %p\n' 2>/dev/null \
			| sort -nr | awk '{ $1=""; sub(/^ /,""); print }' > "$STAGE/pkgs.list" || true
		while IFS= read -r pkg; do
			[ -n "$pkg" ] || continue
			base=$(basename "$pkg")
			case "$base" in
			kernel-devsrc* | kernel-dev-dbg* | kernel-dev-src*) continue ;;
			esac
			one=$STAGE/pkg
			rm -rf "$one"
			mkdir -p "$one"
			case "$pkg" in
			*.rpm) extract_rpm "$pkg" "$one" || continue ;;
			*.ipk | *.deb) ;;
			*) continue ;;
			esac
			if [ "$pkg" != "${pkg%.rpm}" ]; then
				cfg=$(first_match "$one" '*/boot/config-*' || true)
			else
				cfg=$(extract_ar_data "$pkg" "$one" || true)
			fi
			if [ -n "$cfg" ]; then
				note "内核配置来源:包 $pkg"
				cp -L "$cfg" "$STAGE/chosen.config"
				printf '%s\n' "$STAGE/chosen.config"
				return 0
			fi
		done < "$STAGE/pkgs.list"
	fi

	sstate=$ROOT/build/sstate-cache
	if [ -d "$sstate" ]; then
		find "$sstate" -type f -name '*linux-rockchip*' \( \
			-name '*_package.tar.zst' -o -name '*_package.tar.gz' -o \
			-name '*_package_write_*.tar.zst' -o -name '*_package_write_*.tar.gz' \
			\) -print > "$STAGE/balls.list" 2>/dev/null || true
		while IFS= read -r ball; do
			[ -n "$ball" ] || continue
			one=$STAGE/sstate
			rm -rf "$one"
			mkdir -p "$one"
			extract_archive "$ball" "$one" || continue
			cfg=$(first_match "$one" '*/boot/config-*' || true)
			if [ -z "$cfg" ]; then
				cfg=$(first_match "$one" '*standard-build/.config' || true)
			fi
			if [ -z "$cfg" ]; then
				cfg=$(first_match "$one" '*/kernel-build-artifacts/.config' || true)
			fi
			if [ -n "$cfg" ]; then
				note "内核配置来源:sstate $ball"
				cp -L "$cfg" "$STAGE/chosen.config"
				printf '%s\n' "$STAGE/chosen.config"
				return 0
			fi
		done < "$STAGE/balls.list"
	fi
	return 1
}

cfg=""
if cfg=$(locate); then
	:
else
	if [ "$CODE" = "0" ]; then
		note "::error::构建成功但没有可断言的内核 .config(workdir、work-shared、kernel-dev 包、sstate 都没有)。缓存命中不能跳过内核配置自查"
		exit 1
	fi
	note "::warning::构建未完成(BITBAKE_CODE=${CODE:-空}),且没有 .config,跳过内核配置自查"
	exit 0
fi

[ -s "$cfg" ] || {
	note "::error::内核配置文件是空的:$cfg"
	exit 1
}

fail=0
miss=""
expected=0
for frag in "$FRAG_CONTAINER" "$FRAG_OTA"; do
	[ -f "$frag" ] || {
		note "::error::找不到 fragment:$frag"
		exit 1
	}
	count=$(grep -c '^CONFIG_.*=y' "$frag" || true)
	expected=$((expected + count))
	for sym in $(sed -n 's/^\(CONFIG_[A-Z0-9_]*\)=y.*/\1/p' "$frag"); do
		grep -q "^$sym=y$" "$cfg" || {
			miss="$miss $sym"
			fail=1
		}
	done
done
# 数值项不进 =y 循环。panic 后不重启则回退网失效。
if ! grep -q '^CONFIG_PANIC_TIMEOUT=10$' "$cfg"; then
	note "::error::CONFIG_PANIC_TIMEOUT 不是 10 —— panic 不重启,回退网失效"
	fail=1
fi
if [ -n "$miss" ]; then
	note "::error::这些项没进最终 .config(多半是 depends on 没满足):$miss"
fi

{
	echo "### 内核配置自查"
	echo "来源: $cfg"
	if [ "$fail" -eq 0 ]; then
		echo "container.cfg + ota.cfg 共 $expected 项全部落进 .config。"
	else
		echo "缺:$miss"
	fi
} > "$STAGE/summary.txt"
cat "$STAGE/summary.txt" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	cat "$STAGE/summary.txt" >> "$GITHUB_STEP_SUMMARY"
fi

exit "$fail"
