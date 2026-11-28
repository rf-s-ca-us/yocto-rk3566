SUMMARY = "rk3566-lubancat 最小可启动镜像"

require recipes-core/images/core-image-minimal.bb

# 这一行是能不能烧卡的关键。rockchip-image 负责:
#   IMAGE_FSTYPES += "ext4 wic"                   出一体化可烧写镜像
#   WKS_FILE = generic-gptdisk.wks.in             GPT 分区表
#   do_fixup_wks[depends] += virtual/bootloader   触发 u-boot 构建
#   再生成 Rockchip 的 parameter / update.img
# 不继承它的话:只出 rootfs.tar.gz + 内核,没有 u-boot、没有 wic,烧不了卡。
inherit rockchip-image

# 已经烧进板子的 A/B 槽是 wks 里的 --fixed-size(6729594 KiB =
# 6891104256 字节)。再在「内容 × 1.3」上追加 4 GiB 会让 ext4 跟着内容
# 涨:93-c5411847 的 rootfs.ext4 就是这样比槽多出 16384 字节,rauc 拒装。
# 不要把已经生成的镜像截短或补齐 —— 那会毁 ext4。这里改的是生成尺寸。
#
# IMAGE_ROOTFS_SIZE 是下限(KiB),取「槽位 − 16 MiB − systemd 的 4096」。
# core-image-minimal 在 DISTRO_FEATURES 含 systemd 时把
# IMAGE_ROOTFS_EXTRA_SPACE 追加 " + 4096",image.bbclass 在下限之后才加上
# 它,所以要先扣掉,最终 ROOTFS_SIZE 才正好是槽位减 16 MiB。
# 16 MiB 是余量,不是把槽缩小:小包先吃文件系统里大约 4 GiB 的空闲
# (槽位本来就是按「内容 + 4 GiB」烧出来的),镜像文件保持不动。
# 内容本身(含 1.3 倍)超过下限之后,镜像才开始涨。
# IMAGE_ROOTFS_MAXSIZE 取槽位本身。get_rootfs_size() 在对齐后的 KiB
# 大于它时直接 fatal,不许再编出装不进槽的 ext4。等于槽位仍然合法:
# RAUC 只在 image > slot 时拒绝。
# 数字从 wks 读,不在这里再写一遍。
LUBANCAT_ROOTFS_SLOT_MARGIN_KIB = "16384"
LUBANCAT_ROOTFS_SYSTEMD_EXTRA_KIB = "4096"
# 在本文件解析时展开。匿名 python 执行时 FILE 可能已经指向同目录下的
# bbappend,不能再拿 FILE 去拼路径。
LUBANCAT_AB_WKS := "${THISDIR}/../../wic/lubancat-ab.wks.in"

python () {
    import os
    import re

    wks = os.path.normpath(d.getVar("LUBANCAT_AB_WKS"))
    if not os.path.isfile(wks):
        bb.fatal("找不到 A/B 分区表: %s" % wks)

    sizes = []
    with open(wks, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0]
            if "--part-name rootfs_a" not in line and "--part-name rootfs_b" not in line:
                continue
            match = re.search(r"--fixed-size\s+(\d+)[kK](?:\s|$)", line)
            if not match:
                bb.fatal("rootfs 槽缺少 --fixed-size <KiB>k: %s" % raw.rstrip())
            sizes.append(int(match.group(1)))

    if len(sizes) != 2 or sizes[0] != sizes[1]:
        bb.fatal("rootfs_a 与 rootfs_b 的 --fixed-size 必须相同且各有一个,实为 %s" % sizes)

    slot = sizes[0]
    margin = int(d.getVar("LUBANCAT_ROOTFS_SLOT_MARGIN_KIB"))
    systemd_extra = int(d.getVar("LUBANCAT_ROOTFS_SYSTEMD_EXTRA_KIB"))
    image_kib = slot - margin - systemd_extra
    if margin <= 0 or systemd_extra < 0 or image_kib <= 0:
        bb.fatal("rootfs 槽位余量不是正数: slot=%d margin=%d systemd=%d" % (
            slot, margin, systemd_extra))

    d.setVar("IMAGE_ROOTFS_MAXSIZE", str(slot))
    d.setVar("IMAGE_ROOTFS_SIZE", str(image_kib))
    bb.note("A/B rootfs 槽 %d KiB,镜像下限 %d KiB(余量 %d KiB,systemd 额外 %d KiB)" % (
        slot, image_kib, margin, systemd_extra))
}

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

# A/B OTA 阶段 2:RAUC 本体(system.conf 与验签证书 /etc/rauc/keyring.pem
# 由 lubancat-rauc-conf 提供)+ 板上客户端(timer 拉取/比对/流式安装 + 自检 mark-good)。
# meta-rauc 匿名 python 会给 rauc 追加 RDEP u-boot-fw-utils(boothelper),
# 该名字由 poky libubootenv recipe 的 RPROVIDES:${PN}-bin 闭环——上面那行的
# libubootenv-bin 本身就是它,无需(也不可)另配同名 recipe:那样会构成双
# provider,bitbake 在 Initialising tasks 阶段直接 ERROR(CI run
# 36271625902 的死因,曾以元包试过)。
IMAGE_INSTALL:append = " rauc lubancat-rauc-conf lubancat-ota"

# 空白 data 分区的首启格式化,以及 Wi-Fi / Hermes / mihomo 跨槽 bind。
IMAGE_INSTALL:append = " lubancat-persistent"

# Hermes 原生件:venv 组装 + 官方预编译供给件,各自 recipe 见 recipes-devtools /
# recipes-extended / recipes-connectivity。hermes-agent 会经 RDEPENDS 连带拉进
# ffmpeg(poky oe-core 现成 recipe,不在 meta-openembedded)。供给件在此显式列出,
# 是镜像契约的一部分,而不是靠依赖传递"顺便"进来;vscode-server 与 hermes 无
# 运行时交集,同列是它也是本轮交付的预编译件(拍板 1.1)。
IMAGE_INSTALL:append = " hermes-python hermes-agent lubancat-nodejs ripgrep mihomo vscode-server"

# data 分区要能挂上,缺一不可的两半:
#   fstab 行 —— wic 路径会把非 / 挂载点注进 fstab,但 update.img 打包路径直接取
#   rootfs.ext4,注入不发生(2026-09-13 实机验收实测:烧完 fstab 是 stock 原样,
#   data 没人挂);在 rootfs 收尾时补,wic 已注入的同款行用 grep 挡住不重复。
#   nofail:万一将来的布局没有 data 分区,不让启动卡在挂载等待。
#   mke2fs —— update.img 的 data:grow 不带文件系统字节,首启格式化要用它。
#   谁来调用、什么情况下允许写盘,见 lubancat-persistent 的 format-data-if-empty:
#   分区名必须是 data,内容探测不能只看 blkid -p 的退出码,将写入的范围须全为零。
#   data 没挂上时 seal-data-store 把该目录改成只读,避免写进当前槽 rootfs。
IMAGE_INSTALL:append = " e2fsprogs-mke2fs"

# 同一场实机验收的第二处:podman 默认能力表缺 NET_RAW,容器内 ping 全灭而
# DNS/HTTP 出网正常,验收门与现实错位。containers.conf 由本层 recipe 显式给齐。
IMAGE_INSTALL:append = " lubancat-containers-conf"
lubancat_fstab_data() {
    if ! grep -q "^LABEL=data" ${IMAGE_ROOTFS}/etc/fstab; then
        # x-systemd.* 让挂载等空白分区格式化结束。nofail:没有 data 分区时不卡启动。
        echo "LABEL=data  /var/lib/containers  ext4  defaults,nofail,x-systemd.wants=lubancat-format-data.service,x-systemd.after=lubancat-format-data.service  0  2" >> ${IMAGE_ROOTFS}/etc/fstab
    fi
}
ROOTFS_POSTPROCESS_COMMAND:append = " lubancat_fstab_data;"
