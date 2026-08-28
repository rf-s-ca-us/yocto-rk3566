SUMMARY = "rk3566-lubancat 最小可启动镜像"

require recipes-core/images/core-image-minimal.bb

# C4 验收要 ssh 通——没有它每次改都得插卡,迭代成本翻倍
IMAGE_FEATURES:append = " ssh-server-openssh"

IMAGE_INSTALL:append = " kernel-modules"
