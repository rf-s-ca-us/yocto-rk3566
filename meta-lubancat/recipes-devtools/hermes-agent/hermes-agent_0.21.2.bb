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

# unit 装而不自启:先手动验通再议 enable——一次只引入一个变量
inherit systemd features_check
REQUIRED_DISTRO_FEATURES = "systemd"
SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "hermes-gateway.service"
SYSTEMD_AUTO_ENABLE = "disable"

FILES:${PN} = "/usr/local/lib/hermes-venv /usr/local/lib/hermes-agent /usr/local/bin/hermes"
FILES:${PN} += "${systemd_system_unitdir}/hermes-gateway.service ${nonarch_libdir}/tmpfiles.d/hermes-gateway.conf"
