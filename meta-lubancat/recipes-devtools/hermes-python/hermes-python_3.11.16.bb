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

# 官方发行件原样使用:不重 strip、不做调试分离、跳过为源码构建设计的常规检查。
# 调试分离与 strip 是 package.py 里两个独立门:不关 DEBUG_SPLIT 则 objcopy
# --only-keep-debug / --add-gnu-debuglink 照跑,后者会改写上游字节。本树纯
# aarch64(file 实扫 10 个 ELF 无异构,不会像 vscode-server round 7 那样 fatal),
# 但 bin/python3.11 等上游自带 debug_info,分离等于拆出并重分发上游调试件;
# pin-and-verify 语义同为"原样进来原样出去"。
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags libdir"

do_install() {
	install -d ${D}/usr/local/lib/hermes-python
	cp -a ${S}/. ${D}/usr/local/lib/hermes-python/
	# 属主归零:do_unpack 不在 pseudo 下,非 root 解包把 tarball 内文件属主重置为
	# 构建用户(GH Actions runner 是 uid 1001),cp -a 会把这次 chown 原样记进 pseudo
	# ——package_write_rpm 的 get_attr 走 getpwuid 映射不到该 uid,直接 KeyError
	# (round 4 CI 实证)。chown 让打包期伪根里 stat 即为 root。
	chown -R root:root ${D}/usr/local/lib/hermes-python
}

# 预编译发行版布局自带链接期符号链接与静态库:lib/libpython3.11.so 符号链接
# (dev-so 门)、itcl4.3.8/libitclstub*.a 静态库(staticdev 门),round 4 CI 两门
# 实证报错。整包预编译件语义下不做 -dev/-staticdev 拆包,这两门不适用,跳过。
INSANE_SKIP:${PN} += "dev-so staticdev"

# lib-dynload/_crypt.cpython-311-*.so 动态链 libcrypt.so.1。pinned poky(b2c16f1e)
# 的默认 libxcrypt 走 --disable-obsolete-api 只出 libcrypt.so.2;libcrypt.so.1 的
# 提供者是 libxcrypt-compat(libxcrypt-compat_4.4.36.bb:API="--enable-obsolete-api",
# do_install 删掉头文件与 dev 链接后,libcrypt.so.1 按默认 FILES:${PN} 的
# ${libdir}/lib*${SOLIBS} 落进主包)。DEPENDS 一并钉上,让自动 shlib 依赖解析
# 能在依赖树里找到提供者,否则 do_package_qa 的 file-rdeps 报 fatal。
DEPENDS += "libxcrypt-compat"
RDEPENDS:${PN} += "libxcrypt-compat"

FILES:${PN} = "/usr/local/lib/hermes-python"
