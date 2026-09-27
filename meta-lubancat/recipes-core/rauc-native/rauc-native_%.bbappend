# rauc bundle 打包(2026-09-26-ota-phase23.md Task 5,CI 侧)要在 runner 上
# 调外部 mksquashfs(RAUC v1.15.2 src/bundle.c create_bundle → g_spawn
# "mksquashfs")。meta-rauc 把 squashfs-tools-native 放在 RRECOMMENDS ——
# native 的 RRECOMMENDS 不会 stage 进 rauc-native 的 recipe-sysroot-native,
# 而 oe-run-native 的 PATH 恰恰只指那里(STAGING_DIR_NATIVE =
# ${WORKDIR}/recipe-sysroot-native,bitbake.conf:418;oe-find-native-sysroot
# 用 bitbake-getvar 取的就是它)。提为 DEPENDS 才真正进 sysroot。
# squashfs-tools 本体在 meta-filesystems,已在 BBLAYERS。
DEPENDS += "squashfs-tools-native"
