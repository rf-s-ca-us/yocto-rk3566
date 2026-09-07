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

# poky 默认只给一份 80-wired.network,而板子既要能直连 PC(静态)又要能接
# 路由器(DHCP),还要一个能通的 NTP —— 板子没有电池 RTC。见 lubancat-netcfg。
IMAGE_INSTALL:append = " lubancat-netcfg"

# 板载 TL8821CUB 的驱动不在树内,见 rtl8821cu recipe。装 wpa-supplicant 才谈得上
# 连 AP —— 有了驱动没有它,只是多一个 wlan0 躺在那里。
IMAGE_INSTALL:append = " kernel-module-8821cu wpa-supplicant"

# 地址通了还得进得去:镜像里只有 sshd 没有任何凭据,root 密码为空而 sshd 不收
# 空密码。塞开发机的公钥,重烧一次仍然进得去。
IMAGE_INSTALL:append = " lubancat-ssh-authkeys lubancat-wifi"

# ROS 2 Jazzy。meta-ros 的 scarthgap 分支上只有 Jazzy 是 full 支持(到 2028-04),
# 同分支里的 Humble / Kilted / Lyrical 各自是独立 layer,只登记 Jazzy 那一层。
#
# 档位收在一个变量里:desktop = ros-base + rviz2 + rqt + demo 节点,是最贵的一档
# (连带 Qt5、OGRE、PCL 全要从源码编)。要缩范围就改这一行,别去拆下面的清单 ——
# ros-base 去掉可视化,ros-core 只剩发布/订阅与消息生成。
LUBANCAT_ROS_VARIANT ?= "desktop"
IMAGE_INSTALL:append = " ${LUBANCAT_ROS_VARIANT}"

# 板上开发环境 —— 判据是"能在板子上直接 colcon build 一个 ament 包",不是
# "跑得动别人编好的节点"。两个 feature 缺一不可:
#   tools-sdk  gcc / g++ / make / binutils / pkg-config,编译器本体
#   dev-pkgs   已装包的头文件与 .cmake / .pc,没有它编译器装了也 include 不到
# 代价是 rootfs 从几百 MB 涨到 GB 级。eMMC 放得下(parameter 里 rootfs 分区带
# :grow,烧录后撑满整片),但每次重烧的传输时间跟着涨。
IMAGE_FEATURES:append = " tools-sdk dev-pkgs"

# colcon 本身不在 tools-sdk 里,ROS 的构建前端要单独装;cmake / git 是 colcon
# 调用的外部命令(tools-sdk 只给 autotools 那一套)。vcstool 用来在板上拉工作区。
IMAGE_INSTALL:append = " python3-colcon-common-extensions python3-vcstool cmake git"
