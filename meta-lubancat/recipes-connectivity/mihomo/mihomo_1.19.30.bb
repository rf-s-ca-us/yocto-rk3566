SUMMARY = "mihomo(Clash.Meta) aarch64 官方预编译 + systemd 服务"
DESCRIPTION = "拍板 1.2:hermes 全部出站走 127.0.0.1:7890,代理不随镜像则原生 hermes 装了也哑火。\
release 资产是 .gz 包裹的单二进制(bitbake do_unpack 自动 gunzip),sha256 取自 GitHub API asset \
digest——该 release 未随附校验和文件,API digest 即官方值(已下载实算对账)。config.yaml 不进镜像:\
订阅属于运行时凭据,由使用者手工放 /etc/mihomo/config.yaml。"

LICENSE = "GPL-3.0-only"
# 许可取 pin 的 v1.19.30 tag 上的 LICENSE(上游 main 分支现已改 MIT,但发布的
# 这个二进制按 tag 时的许可走,tag 上是 GPL-3.0 规范全文;两处不一致以 pin 为准)
LIC_FILES_CHKSUM = "file://mihomo.LICENSE;md5=1ebbd3e34237af26da5dc08a4e440464"

SRC_URI = "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.30/mihomo-linux-arm64-v1.19.30.gz;downloadfilename=mihomo-linux-arm64-v1.19.30.gz \
           https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.30/LICENSE;downloadfilename=mihomo.LICENSE"
SRC_URI[sha256sum] = "58896873736d28628f66de3677c8654fa0f180662523148e136cff4f6e890069"
SRC_URI[sha256sum] = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"

COMPATIBLE_HOST = "aarch64.*-linux"
S = "${WORKDIR}"

INHIBIT_PACKAGE_STRIP = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags"

do_install() {
	install -d ${D}${bindir}
	install -m 0755 ${WORKDIR}/mihomo-linux-arm64-v1.19.30 ${D}${bindir}/mihomo
	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${WORKDIR}/mihomo.service ${D}${systemd_system_unitdir}/mihomo.service
	# 目录进包、配置不进包:服务起不起得来取决于运行时放不放 config.yaml
	install -d ${D}${sysconfdir}/mihomo
}

# unit 装进镜像但不预设自启:配置没放时自启只会空转刷日志。实机验通后由
# 使用者 systemctl enable --now mihomo——与 gateway 的"一次只引入一个变量"同则。
# 不声明 systemd 类的话 SYSTEMD_* 是死变量,"装而不自启"只是碰巧行为而非声明保证
# (lubancat-wifi 先例);features_check 把误配进无 systemd 镜像的构建挡在解析期
inherit systemd features_check
REQUIRED_DISTRO_FEATURES = "systemd"
SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "mihomo.service"
SYSTEMD_AUTO_ENABLE = "disable"

FILES:${PN} = "${bindir}/mihomo ${systemd_system_unitdir}/mihomo.service ${sysconfdir}/mihomo"
