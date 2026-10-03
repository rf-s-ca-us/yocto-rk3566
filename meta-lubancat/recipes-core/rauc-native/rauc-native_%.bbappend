# rauc bundle 打包(2026-09-26-ota-phase23.md Task 5,CI 侧)要在 runner 上
# 调外部 mksquashfs(RAUC v1.15.2 src/bundle.c create_bundle → g_spawn
# "mksquashfs")。meta-rauc 把 squashfs-tools-native 放在 RRECOMMENDS ——
# native 的 RRECOMMENDS 不会 stage 进 rauc-native 的 recipe-sysroot-native。
# 消费者是 build.yml 的 bundle 步:它不走 oe-run-native,而是 bitbake-getvar
# 取 rauc-native 的 WORKDIR(由 local.conf 的 RM_WORK_EXCLUDE 保活)find 出
# rauc 本体,再把 RECIPE_SYSROOT_NATIVE 挂上 PATH —— mksquashfs 必须真在
# 那棵 sysroot 里,故提为 DEPENDS(2026-10-03 评审 F10:旧注释把消费者写成
# oe-run-native 的 PATH,机制没变、引用过期)。
# squashfs-tools 本体在 meta-filesystems,已在 BBLAYERS。
DEPENDS += "squashfs-tools-native"
