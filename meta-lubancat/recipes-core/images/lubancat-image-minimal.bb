SUMMARY = "rk3566-lubancat 最小可启动镜像"

require recipes-core/images/core-image-minimal.bb

# 这一行是能不能烧卡的关键。rockchip-image 负责:
#   IMAGE_FSTYPES += "ext4 wic"                   出一体化可烧写镜像
#   WKS_FILE = generic-gptdisk.wks.in             GPT 分区表
#   do_fixup_wks[depends] += virtual/bootloader   触发 u-boot 构建
#   再生成 Rockchip 的 parameter / update.img
# 不继承它的话:只出 rootfs.tar.gz + 内核,没有 u-boot、没有 wic,烧不了卡。
inherit rockchip-image

# C4 验收要 ssh 通——没有它每次改都得插卡,迭代成本翻倍
IMAGE_FEATURES:append = " ssh-server-openssh"

IMAGE_INSTALL:append = " kernel-modules"

# Hermes Agent 以容器跑:它要 Python 3.11 + Node.js + ripgrep + ffmpeg,
# 全塞进 rootfs 等于把镜像和它的版本焊死。podman 无守护进程,不像 docker
# 那样常驻一个 root daemon,在单板上更划算。
IMAGE_INSTALL:append = " podman"

# 接的网段没有 DHCP,poky 默认只给一份 80-wired.network(DHCP=yes),
# 起来了也拿不到地址。静态配置见 lubancat-netcfg。
IMAGE_INSTALL:append = " lubancat-netcfg"

# 板载 TL8821CUB 的驱动不在树内,见 rtl8821cu recipe。装 wpa-supplicant 才谈得上
# 连 AP —— 有了驱动没有它,只是多一个 wlan0 躺在那里。
IMAGE_INSTALL:append = " kernel-module-8821cu wpa-supplicant"
