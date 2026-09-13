SUMMARY = "ripgrep 15.2.0 aarch64 官方预编译(musl 静态)"
DESCRIPTION = "四个已启用 layer 的钉死提交树内都没有 ripgrep recipe(P0 探针结论),\
走 GitHub releases 预编译。选 musl 静态件:无动态库依赖,glibc 用户态直接跑。\
rg 是 hermes 的文件搜索工具(缺了退化为 grep fallback),独立成包便于单独升级。"

LICENSE = "MIT | Unlicense"
# 双许可:发行件随包携带两份许可文本,LIC_FILES_CHKSUM 各指一行
LIC_FILES_CHKSUM = "file://ripgrep-15.2.0-aarch64-unknown-linux-musl/UNLICENSE;md5=7246f848faa4e9c9fc0ea91122d6e680 \
                    file://ripgrep-15.2.0-aarch64-unknown-linux-musl/LICENSE-MIT;md5=8d0d0aa488af0ab9aafa3b85a7fc8e12"

SRC_URI = "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-unknown-linux-musl.tar.gz;downloadfilename=ripgrep-15.2.0-aarch64-unknown-linux-musl.tar.gz"
SRC_URI[sha256sum] = "800b1e7206afe799dfb5a6901f23147cfaabe0e52210538100f61e86e1740915"

COMPATIBLE_HOST = "aarch64.*-linux"
S = "${WORKDIR}"

INHIBIT_PACKAGE_STRIP = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags"

do_install() {
	install -d ${D}${bindir}
	install -m 0755 ${WORKDIR}/ripgrep-15.2.0-aarch64-unknown-linux-musl/rg ${D}${bindir}/rg
}

FILES:${PN} = "${bindir}/rg"
