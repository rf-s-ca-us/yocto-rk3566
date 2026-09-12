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

# 容器运行时保留(拍板 1.3):Hermes 已原生进镜像,podman 不再承载它,但
# board-acceptance.sh 的三项容器门与 data 分区挂载点仍指向容器存储,现在删除
# 会连带改 OTA 验收口径。是否删除待 Hermes 原生稳定后单独拍板。
IMAGE_INSTALL:append = " podman"

# vscode-server 的兜底:版本错配时客户端回退自装的正路是板上 curl(busybox wget 无
# 证书校验不可靠)。ca-certificates 同时是 hermes venv 的 TLS 信任源(wrapper 保底指它)。
IMAGE_INSTALL:append = " curl ca-certificates"

# poky 默认只给一份 80-wired.network,而板子既要能直连 PC(静态)又要能接
# 路由器(DHCP),还要一个能通的 NTP —— 板子没有电池 RTC。见 lubancat-netcfg。
IMAGE_INSTALL:append = " lubancat-netcfg"

# 板载 TL8821CUB 的驱动不在树内,见 rtl8821cu recipe。装 wpa-supplicant 才谈得上
# 连 AP —— 有了驱动没有它,只是多一个 wlan0 躺在那里。
IMAGE_INSTALL:append = " kernel-module-8821cu wpa-supplicant"

# 地址通了还得进得去:镜像里只有 sshd 没有任何凭据,root 密码为空而 sshd 不收
# 空密码。塞开发机的公钥,重烧一次仍然进得去。
IMAGE_INSTALL:append = " lubancat-ssh-authkeys lubancat-wifi"

# A/B OTA:Linux 侧读写 u-boot env 的工具与位置配置(libubootenv 的命令在
# -bin 子包)。u-boot 侧 env 落盘由 recipes-bsp/u-boot 的 bbappend 补丁负责,
# 两边的偏移必须同源 —— fw_env.config 的注释里写着对齐关系。
IMAGE_INSTALL:append = " libubootenv libubootenv-bin lubancat-fw-env"

# Hermes 原生件:venv 组装 + 官方预编译供给件,各自 recipe 见 recipes-devtools /
# recipes-extended / recipes-connectivity。hermes-agent 会经 RDEPENDS 连带拉进
# ffmpeg(poky oe-core 现成 recipe,不在 meta-openembedded)。供给件在此显式列出,
# 是镜像契约的一部分,而不是靠依赖传递"顺便"进来;vscode-server 与 hermes 无
# 运行时交集,同列是它也是本轮交付的预编译件(拍板 1.1)。
IMAGE_INSTALL:append = " hermes-python hermes-agent lubancat-nodejs ripgrep mihomo vscode-server"
