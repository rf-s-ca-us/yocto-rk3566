SUMMARY = "root 的 authorized_keys —— 开发机的公钥"
DESCRIPTION = "镜像里只有 ssh-server-openssh,没有任何凭据:root 密码为空而 sshd \
不接受空密码登录,所以地址通了也进不去。塞一把公钥是唯一不牵扯密码的做法 —— \
poky 的 sshd_config 把 PermitRootLogin 那行注释掉了,走上游默认 prohibit-password, \
公钥认证放行、密码认证拒绝。放公钥不放私钥,公钥本来就是公开物。"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://authorized_keys"

do_install() {
	install -d -m 0700 ${D}/home/root/.ssh
	install -m 0600 ${WORKDIR}/authorized_keys ${D}/home/root/.ssh/authorized_keys
}

FILES:${PN} = "/home/root/.ssh"

# sshd 对 .ssh 与 authorized_keys 的属主和权限有硬性要求,松一点就直接拒认。
# 镜像里 root 的 uid/gid 都是 0,写死即可。
do_install:append() {
	chown -R 0:0 ${D}/home/root/.ssh
}
