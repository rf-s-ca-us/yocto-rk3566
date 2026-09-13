SUMMARY = "hermes-agent 原生组装(git pin + uv 交叉 venv)"
DESCRIPTION = "把上游 install.sh 的运行时联网拼装(clone + uv sync + 自管 Node/Python)搬到构建期:\
依赖树按 pinned uv.lock 用 uv export 交叉解析成 aarch64 需求集,断言后逐 wheel 安装进目标 venv,\
构建期不跑一行目标机代码。上游自管件(Node 浮动 latest、astral python 下载)一概不用——\
它们无 hash,由 lubancat-nodejs / hermes-python 以官方 SHA 钉死替代。懒依赖在板上运行时\
经 venv 里的 pip 现装(走 mihomo 出网),落 /root/.hermes 属运行时状态,不是镜像契约。"

# LICENSE 就在 pin 树根目录(git blob 75410e73,MIT,Copyright (c) 2025 Nous
# Research),md5 按该 blob 实算核对一致;pyproject.toml 亦声明 license = "MIT"。
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1864e6648a4c302b984b2efd215c7918"

# uv 是构建 host 件(x86_64),与源码同受 fetch+sha256 红线约束,故进 SRC_URI 而非装进系统
SRC_URI = "gitsm://github.com/NousResearch/hermes-agent.git;protocol=https;branch=main;name=hermes \
           https://github.com/astral-sh/uv/releases/download/0.12.13/uv-x86_64-unknown-linux-gnu.tar.gz;downloadfilename=uv-x86_64-unknown-linux-gnu.tar.gz;name=uv \
           file://wheel-assert.py \
           file://hermes-wrapper \
           file://hermes-gateway.service \
           file://hermes-gateway-tmpfiles.conf"
SRCREV = "939e45c91d751fadd94dcd1b873ac3cb44846213"
SRC_URI[uv.sha256sum] = "745765a3b6e360ad76743599ae5c42e9278c7edf8bbff9fc76d05bf2623a04dd"
PV = "0.21.2"

# round 8 唯一失败的根因:源树从不在默认 S 里。本 poky pin(b2c16f1e)的
# base_do_unpack 把 WORKDIR 直接交给 fetcher,git fetcher 无 destsuffix 一律
# 解到 ${WORKDIR}/git;而默认 S=${WORKDIR}/${BP}(hermes-agent-0.21.2)从不
# 产生——do_populate_lic 的 license-checksum 硬门在 ${S}/LICENSE isfile 上
# 报 "points to an invalid file"(md5 分支根本没走到),do_compile/do_install
# 的 ${S} 引用同样悬空。显式对齐解包布局(同层 rtl8821cu_git.bb 同此约定)。
S = "${WORKDIR}/git"

COMPATIBLE_HOST = "aarch64.*-linux"

# 交叉导出/断言/安装都要访问 PyPI;bitbake 对非 fetch 任务默认断网的场景下显式放开
do_compile[network] = "1"

RDEPENDS:${PN} = "hermes-python lubancat-nodejs ripgrep ffmpeg git bash"
# manylinux wheel(onnxruntime/numpy 等)动态链 libstdc++.so.6,由 gcc-runtime 提供;
# 包名是 libstdc++(libstdc++6 是 Debian 的叫法,poky 里没有这个包)
RDEPENDS:${PN} += "libstdc++"

do_compile() {
	UV="${WORKDIR}/uv-x86_64-unknown-linux-gnu/uv"

	# 1) 按 pinned uv.lock 导出(--frozen 禁止重解析,--no-header 去掉 index 头)。
	#    本 recipe 钉死的 uv 0.12.13 的 export 子命令没有 --python-platform/
	#    --python-version(uv 0.12.13 export --help 实证只有 -p, --python;带
	#    --python-platform 即 round 9 CI 的 "error: unexpected argument
	#    '--python-platform' found; tip: a similar argument exists: '--python'")。
	#    uv.lock 本就是全平台通用锁,导出不按平台过滤、逐行保留 PEP 508 marker,
	#    平台取舍整体后移到安装步(--python-platform/--python-version 是本版本
	#    uv pip install 的合法参数,help 实证)。--no-python-downloads 禁 uv
	#    自管解释器下载,守住"上游自管件一概不用"的红线。
	${UV} export --frozen --no-dev --no-emit-project --no-header --no-python-downloads \
		--format requirements-txt -o ${WORKDIR}/req-aarch64.txt

	# 2) wheel 覆盖断言:需 native 却无 aarch64 wheel 的条目数必须为 0,
	#    纯 Python sdist 放行(pure-sdist.txt)。脚本内含与安装步同口径的
	#    marker 求值(CPython 3.11/linux/aarch64),win32 专属 fork(pywin32
	#    等)不计入覆盖统计;对 marker 求值不动的行一律保守视为适用。
	python3 ${WORKDIR}/wheel-assert.py ${WORKDIR}/req-aarch64.txt \
		|| bbfatal "wheel 覆盖断言失败,见上方 MUSL-ONLY/阻断行——回 P0 探针重核"

	# 3) 主体安装 --only-binary:有 sdist 混入即失败,等于把探针门搬进构建;
	#    纯 Python sdist 单独由 uv 按 --no-binary 取 sdist 装(hash 随导出行逐字校验,
	#    在 host 构建成 py3-none-any 再入 target,产物平台无关)。不走"host 先
	#    pip wheel 再 find-links"是因为本地现构建的 wheel 哈希对不上锁内 sdist 的
	#    哈希,带 --hash 的需求行会被 uv 拒收。
	#    --python-platform 必须写全三元 aarch64-unknown-linux-gnu:0.12.13 的
	#    pip install 拒收裸 aarch64("error: invalid value 'aarch64' for
	#    '--python-platform'",help 的 possible values 即全三元列表)。
	if [ -s ${WORKDIR}/pure-sdist.txt ]; then
		grep -v -F -f ${WORKDIR}/pure-sdist.txt ${WORKDIR}/req-aarch64.txt > ${WORKDIR}/req-wheels.txt
	else
		# 本锁主闭包 pure_sdist=0 走这里:空 pattern 文件时 grep -v -f 行为跨实现
		# 不一(GNU grep 全保留;ugrep 全丢弃且非零退出),cp 让语义确定——
		# req-wheels ≡ req,任何一条都不装成"空需求集"。
		cp ${WORKDIR}/req-aarch64.txt ${WORKDIR}/req-wheels.txt
	fi
	${UV} pip install --no-python-downloads --python-platform aarch64-unknown-linux-gnu --python-version 3.11 \
		--no-deps --only-binary :all: \
		--target ${WORKDIR}/site-pkgs -r ${WORKDIR}/req-wheels.txt
	if [ -s ${WORKDIR}/pure-sdist.txt ]; then
		${UV} pip install --no-python-downloads --python-platform aarch64-unknown-linux-gnu --python-version 3.11 \
			--no-deps --no-binary :all: \
			--target ${WORKDIR}/site-pkgs -r ${WORKDIR}/pure-sdist.txt
	fi

	# 4) hermes 本体:非 editable wheel(host 构建纯 Python;editable 会指向构建机路径)。
	#    上游 setup.py 守卫 bdist_wheel:非 Nix 构建一律 RuntimeError("Building
	#    wheels or sdists for hermes-agent is not supported"),HERMES_NIX_BUILD=1
	#    是其文档化的合法源码构建出口(uv2nix 的 python.nix 同款用法);产物
	#    py3-none-any 平台无关,本地同版本 uv 实证可交叉装入 --target。
	HERMES_NIX_BUILD=1 ${UV} pip install --no-python-downloads --python-platform aarch64-unknown-linux-gnu --python-version 3.11 \
		--no-deps --target ${WORKDIR}/site-pkgs ${S}
}

do_install() {
	install -d ${D}/usr/local/lib/hermes-venv/bin \
		${D}/usr/local/lib/hermes-venv/lib/python3.11/site-packages \
		${D}/usr/local/lib/hermes-agent \
		${D}/usr/local/bin

	# venv 骨架:解释器指 hermes-python,不复制解释器本体(单一真源)
	cat > ${D}/usr/local/lib/hermes-venv/pyvenv.cfg <<'EOF'
home = /usr/local/lib/hermes-python/bin
include-system-site-packages = false
version = 3.11.16
EOF
	ln -sf /usr/local/lib/hermes-python/bin/python3.11 ${D}/usr/local/lib/hermes-venv/bin/python3

	cp -a ${WORKDIR}/site-pkgs/. ${D}/usr/local/lib/hermes-venv/lib/python3.11/site-packages/
	# uv --target 生成的 console script shebang 指向构建机,镜像里不可用;入口由 wrapper 以 -m 起
	rm -rf ${D}/usr/local/lib/hermes-venv/lib/python3.11/site-packages/bin

	# 源树按上游 root 安装形态摆 /usr/local/lib/hermes-agent;.git 不进镜像
	cp -a ${S}/. ${D}/usr/local/lib/hermes-agent/
	rm -rf ${D}/usr/local/lib/hermes-agent/.git
	# docker/ 整目录是上游容器运行时入口(entrypoint、tini-shim、s6-rc.d 服务定义、
	# cont-init.d),板上由 systemd unit + /usr/local/bin/hermes wrapper 起服务,
	# 无 s6/with-contenv,装进去就是死件。实证依据(round 9 本地实物枚举):
	# temp/hermes-src 全树 shebang 扫描,唯一非白名单解释器 #!/command/with-contenv sh
	# 共 5 个全在 docker/ 下,其中 4 个带可执行位(tarball mode 755:02-reconcile-profiles、
	# s6-rc.d/{dashboard/{run,finish},main-hermes/run})——round 10 do_rootfs 的
	# "nothing provides /command/with-contenv" 即 rpmdeps 对它们自动生成的解释器
	# Requires。目录外无第二个异型解释器(其余全部 /bin/sh、/bin/bash、/usr/bin/env*)。
	rm -rf ${D}/usr/local/lib/hermes-agent/docker

	install -m 0755 ${WORKDIR}/hermes-wrapper ${D}/usr/local/bin/hermes

	# 属主归零:site-pkgs(uv 在 do_compile 生成)与 ${S}(git clone)在 CI 上属
	# 构建用户 uid 1001,cp -a 把 chown 记进 pseudo,package_write_rpm 的 getpwuid
	# 映射不到即 KeyError(hermes-python round 4 CI 实证同一机制)。install 出的
	# wrapper/unit 本就新建为 root,一并覆盖无害。
	chown -R root:root ${D}/usr/local/lib/hermes-venv ${D}/usr/local/lib/hermes-agent

	install -d ${D}${systemd_system_unitdir} ${D}${nonarch_libdir}/tmpfiles.d
	install -m 0644 ${WORKDIR}/hermes-gateway.service ${D}${systemd_system_unitdir}/hermes-gateway.service
	install -m 0644 ${WORKDIR}/hermes-gateway-tmpfiles.conf ${D}${nonarch_libdir}/tmpfiles.d/hermes-gateway.conf
}

# 预编译件统一语义(vscode-server round 7 同源问题):树内 ELF 全是 uv 按锁装出的
# manylinux aarch64 .so(wheel-assert 门保证无异构;历轮 CI 开着 strip 也能打包,
# 旁证可被本架构工具处理),且是上游已 strip 的钉死字节——strip 与调试分离只会
# 改写它们。两个门独立,须同时关。
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags libdir"
# manylinux .so 不是本层构建产物,库依赖检查(file-rdeps)会误报
INSANE_SKIP:${PN} += "file-rdeps"

# ── round 10 do_rootfs 五条 "nothing provides" 的两条根因与处置 ──────────────
# 报错五条:/command/with-contenv + libjpeg-f7df23c0.so.62.4.0(LIBJPEG_6.2)、
# liblzma-d6711707.so.5.8.3(XZ_5.0)、libpng16-5a20c924.so.16.58.0(PNG16_0)、
# libtiff-fb36a6b9.so.6.2.0(LIBTIFF_4.0),均 (64bit)。
#
# 机制(全部按 pinned poky b2c16f1e 源码逐行核对):
# 1) 这些依赖走 per-file 通道:oe/package.py process_filedeps 跑 RPMDEPS
#    (rpmdeps --alldeps),R 行存成 FILERDEPENDS,再由 package_rpm.bbclass
#    write_rpm_perfiledata 生成 __find_requires 脚本喂给 rpmbuild(第 685/723 行)
#    ——该通道不读 PRIVATE_LIBS。与 shlibs 通道(process_shlibs,产出 RDEPENDS)
#    相互独立。
# 2) 版本化 soname require 永无提供者:rpm 4.19.1.1 的 elfdeps 工具里,
#    require 取自 VERNEED 的 vn_file(auditwheel 改写过的哈希 DT_NEEDED),
#    版本化 provide 却取自 VERDEF 的 BASE 名(上游原始 soname libjpeg.so.62,
#    auditwheel 不改写)——两者名字永不相等。全树 readelf -V 实扫,哈希名
#    版本化 require 恰为上述 4 条(dnf 报错与之逐条一致;其余 14 个哈希库只被
#    无版本符号引用,require 是裸 soname,能被包内裸 soname provide 满足)。
# 3) PRIVATE_LIBS 在 b2c16f1e 只被 meta/lib/oe/package.py 的 shlibs 机制消费:
#    1678 行阻止私有 soname 注册为 shlib 提供者,1858 行(fnmatch.fnmatch)
#    跳过为其解析 RDEPENDS——支持通配符,但救不了 FILERDEPENDS 通道。
#
# 处置一:SKIP_FILEDEPS 关掉整条 per-file 通道(process_filedeps 入口
# 1565/1577 行)。本包是预编译件拼装(venv + 上游源树),文件级 require 要么
# 无提供者(哈希 soname、with-contenv),要么指向镜像必有的系统库
# (libc/libstdc++/libgcc/zlib 的真提供关系仍由 process_shlibs 走 objdump
# NEEDED 解析进 RDEPENDS,显式 RDEPENDS 未动)。oe-core 先例:ltp_20240129
# 整包 SKIP_FILEDEPS:${PN} = '1'(valgrind-ptest、perl-ptest 同)。
SKIP_FILEDEPS:${PN} = "1"

# 处置二:PRIVATE_LIBS 做 shlibs 通道卫生——不让 18 个哈希 soname 注册成
# shlib 提供者,也不为它们做 RDEPENDS 解析。实物枚举(temp/wl/site-pkgs,
# find -path '*.libs/*'):全仓唯一 *.libs 是 pillow.libs,18 个
# lib<name>-<8位hex>.so<ver>(libjpeg/liblzma/libpng16/libtiff/libwebp*/libavif/
# libbrotli*/libfreetype/libharfbuzz/liblcms2/libopenjp2/libsharpyuv/libXau/
# libxcb/libzstd),objdump -p 全树 140 条 DT_NEEDED 逐一核对,全部同包自带、
# 无第二个 .libs、无 numpy/scipy 类 openblas 捆绑(本锁闭包里不存在)。
# 模式即 auditwheel 哈希指纹:标准系统 soname 无 "-<8hex>" 形态,不会误伤
# libc.so.6/libstdc++.so.6 等真依赖(它们须照常解析)。
PRIVATE_LIBS:${PN} = "lib*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].so*"

# unit 装而不自启:先手动验通再议 enable——一次只引入一个变量
inherit systemd features_check
REQUIRED_DISTRO_FEATURES = "systemd"
SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "hermes-gateway.service"
SYSTEMD_AUTO_ENABLE = "disable"

FILES:${PN} = "/usr/local/lib/hermes-venv /usr/local/lib/hermes-agent /usr/local/bin/hermes"
FILES:${PN} += "${systemd_system_unitdir}/hermes-gateway.service ${nonarch_libdir}/tmpfiles.d/hermes-gateway.conf"
