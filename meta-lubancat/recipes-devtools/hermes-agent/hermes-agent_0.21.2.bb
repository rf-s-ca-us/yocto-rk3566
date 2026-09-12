SUMMARY = "hermes-agent 原生组装(git pin + uv 交叉 venv)"
DESCRIPTION = "把上游 install.sh 的运行时联网拼装(clone + uv sync + 自管 Node/Python)搬到构建期:\
依赖树按 pinned uv.lock 用 uv export 交叉解析成 aarch64 需求集,断言后逐 wheel 安装进目标 venv,\
构建期不跑一行目标机代码。上游自管件(Node 浮动 latest、astral python 下载)一概不用——\
它们无 hash,由 lubancat-nodejs / hermes-python 以官方 SHA 钉死替代。懒依赖在板上运行时\
经 venv 里的 pip 现装(走 mihomo 出网),落 /root/.hermes 属运行时状态,不是镜像契约。"

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

COMPATIBLE_HOST = "aarch64.*-linux"

# 交叉导出/断言/安装都要访问 PyPI;bitbake 对非 fetch 任务默认断网的场景下显式放开
do_compile[network] = "1"

RDEPENDS:${PN} = "hermes-python lubancat-nodejs ripgrep ffmpeg git bash"
# manylinux wheel(onnxruntime/numpy 等)动态链 libstdc++.so.6,由 gcc-runtime 提供
RDEPENDS:${PN} += "libstdc++6"

do_compile() {
	UV="${WORKDIR}/uv-x86_64-unknown-linux-gnu/uv"

	# 1) 按 pinned uv.lock 交叉导出(--frozen 禁止重解析,--no-header 去掉 index 头)
	${UV} export --frozen --no-dev --no-emit-project --no-header \
		--python-platform aarch64 --python-version 3.11 \
		--format requirements-txt -o ${WORKDIR}/req-aarch64.txt

	# 2) wheel 覆盖断言:需 native 却无 aarch64 wheel 的条目数必须为 0,
	#    纯 Python sdist 放行(pure-sdist.txt)
	python3 ${WORKDIR}/wheel-assert.py ${WORKDIR}/req-aarch64.txt \
		|| bbfatal "wheel 覆盖断言失败,见上方 MUSL-ONLY/阻断行——回 P0 探针重核"

	# 3) 主体安装 --only-binary:有 sdist 混入即失败,等于把探针门搬进构建;
	#    纯 Python sdist 单独由 uv 按 --no-binary 取 sdist 装(hash 随导出行逐字校验,
	#    在 host 构建成 py3-none-any 再入 target,产物平台无关)。不走"host 先
	#    pip wheel 再 find-links"是因为本地现构建的 wheel 哈希对不上锁内 sdist 的
	#    哈希,带 --hash 的需求行会被 uv 拒收。
	grep -v -F -f ${WORKDIR}/pure-sdist.txt ${WORKDIR}/req-aarch64.txt > ${WORKDIR}/req-wheels.txt
	${UV} pip install --python-platform aarch64 --python-version 3.11 \
		--no-deps --only-binary :all: \
		--target ${WORKDIR}/site-pkgs -r ${WORKDIR}/req-wheels.txt
	if [ -s ${WORKDIR}/pure-sdist.txt ]; then
		${UV} pip install --python-platform aarch64 --python-version 3.11 \
			--no-deps --no-binary :all: \
			--target ${WORKDIR}/site-pkgs -r ${WORKDIR}/pure-sdist.txt
	fi

	# 4) hermes 本体:非 editable wheel(host 构建纯 Python;editable 会指向构建机路径)
	${UV} pip install --python-platform aarch64 --python-version 3.11 \
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

	install -d ${D}${systemd_system_unitdir} ${D}${nonarch_libdir}/tmpfiles.d
	install -m 0644 ${WORKDIR}/hermes-gateway.service ${D}${systemd_system_unitdir}/hermes-gateway.service
	install -m 0644 ${WORKDIR}/hermes-gateway-tmpfiles.conf ${D}${nonarch_libdir}/tmpfiles.d/hermes-gateway.conf
}

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
