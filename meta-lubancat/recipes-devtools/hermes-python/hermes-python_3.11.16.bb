SUMMARY = "Hermes Agent 专用 CPython 3.11(aarch64 官方预编译)"
DESCRIPTION = "hermes 的 requires-python 是 >=3.11,<3.14,官方 install.sh 首选 3.11。\
不进公共 python3 体系(PN 不叫 python3,不 RPROVIDES python3),与宿主解释器互不干扰。\
独立成包的理由:hermes venv 的 pyvenv.cfg 直接指这里,升级 hermes 不必动解释器,反之亦然。\
上游 install.sh 会自己下 python-build-standalone(无 hash),这里由镜像侧以官方 SHA256SUMS 钉死。"

LICENSE = "PSF-2.0"
# 许可文本不在发行树根部,随解释器装在标准库目录里
LIC_FILES_CHKSUM = "file://lib/python3.11/LICENSE.txt;md5=fcf6b249c2641540219a727f35d8d2c2"

# 官方 SHA256SUMS 资产对应行(非本机实算;URL 里 %2B 是 release asset 路径中的 + 的原样转义)
SRC_URI = "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.11.16%2B20260901-aarch64-unknown-linux-gnu-install_only.tar.gz;downloadfilename=cpython-3.11.16-pbs20260901-aarch64-install_only.tar.gz"
SRC_URI[sha256sum] = "c1cca4af741e33d47871b298842e6c3272cd9e8f57daf8085359fcbfe2d1a5aa"

COMPATIBLE_HOST = "aarch64.*-linux"

# install_only tarball 的顶层目录名是 python/
S = "${WORKDIR}/python"

# 官方发行件原样使用:不重 strip、跳过为源码构建设计的常规检查
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_SYSROOT_STRIP = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags libdir"

do_install() {
	install -d ${D}/usr/local/lib/hermes-python
	cp -a ${S}/. ${D}/usr/local/lib/hermes-python/
}

FILES:${PN} = "/usr/local/lib/hermes-python"
