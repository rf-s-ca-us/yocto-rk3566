SUMMARY = "u-boot-fw-utils 元包 —— 满足 meta-rauc 的 boothelper 依赖,真身是 libubootenv"
DESCRIPTION = "meta-rauc 的匿名 python(rauc-target.inc,子串匹配)在 \
PREFERRED_PROVIDER_virtual/bootloader 含 'u-boot' 时给 rauc 追加 \
RDEPENDS u-boot-fw-utils。本构建的 provider 是 u-boot-rockchip(meta-rockchip \
rockchip-common.inc),命中年匹配,但 pinned poky scarthgap 全宇宙没有任何 \
recipe 产出 u-boot-fw-utils 包名(u-boot-tools 只拆 mkimage/mkenvimage/\
mkeficapsule,u-boot.inc 拆 -env/-extlinux)——没有本元包,rootfs 解析直接 \
Nothing RPROVIDES。板上真正的 fw 工具是 libubootenv-bin(fw_printenv/\
fw_setenv,Phase 1 起与 lubancat-fw-env 的 /etc/fw_env.config 同源),所以 \
这里只做名字闭环,把依赖指过去,不装任何文件,避免双套工具撞文件。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

RDEPENDS:${PN} += "libubootenv-bin"

ALLOW_EMPTY:${PN} = "1"
