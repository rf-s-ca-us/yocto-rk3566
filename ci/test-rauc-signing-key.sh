#!/bin/sh
# 不跑 Yocto。核对固定 OTA 证书、签名密钥脚本、镜像 keyring 自查和 workflow 接线。
# 测试用的私钥只活在 mktemp 目录里,断言失败输出会去掉 PEM 块。
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

CERT=$ROOT/meta-lubancat/recipes-core/ota/files/keyring.pem
CONF=$ROOT/meta-lubancat/recipes-core/ota/files/system.conf
RECIPE=$ROOT/meta-lubancat/recipes-core/ota/lubancat-rauc-conf_1.0.bb
WORKFLOW=$ROOT/.github/workflows/build.yml
PREPARE=$ROOT/ci/prepare-rauc-signing-key.sh
CHECK=$ROOT/ci/check-image-rauc-keyring.sh

fail=0

redact() {
	sed -e '/-----BEGIN/,/-----END/d'
}

expect() {
	name=$1
	want=$2
	shift 2
	set +e
	"$@" >/tmp/rauc-sign.out 2>&1
	got=$?
	set -e
	if [ "$got" -eq "$want" ]; then
		printf '  ok   %s\n' "$name"
	else
		printf '  FAIL %s (exit %s, want %s)\n' "$name" "$got" "$want"
		redact /tmp/rauc-sign.out | sed 's/^/       | /'
		fail=1
	fi
}

echo "== 仓内证书与 system.conf"
fp=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | sed 's/^.*=//')
want_fp='3C:4C:D5:4B:43:61:50:C9:36:22:86:CE:1A:51:B4:3F:14:79:B9:10:28:21:6E:73:DA:63:5E:EA:17:16:EE:3A'
if [ "$fp" = "$want_fp" ]; then
	printf '  ok   SHA-256 指纹\n'
else
	printf '  FAIL SHA-256 指纹\n       | got %s\n' "$fp"
	fail=1
fi
subj=$(openssl x509 -in "$CERT" -noout -subject)
case $subj in
	*'CN=yocto-rk3566-ota'*|*'CN = yocto-rk3566-ota'*) printf '  ok   CN=yocto-rk3566-ota\n' ;;
	*) printf '  FAIL subject: %s\n' "$subj"; fail=1 ;;
esac
if grep -q 'PRIVATE KEY' "$CERT"; then
	echo "  FAIL keyring.pem 含私钥"
	fail=1
else
	printf '  ok   证书文件没有私钥\n'
fi
if grep -qx '\[keyring\]' "$CONF" && grep -qx 'path=/etc/rauc/keyring.pem' "$CONF"; then
	printf '  ok   system.conf 指向 /etc/rauc/keyring.pem\n'
else
	echo "  FAIL system.conf 缺 [keyring] 或 path"
	fail=1
fi
if grep -q 'file://keyring.pem' "$RECIPE" \
	&& grep -q 'rauc/keyring.pem' "$RECIPE" \
	&& grep -q '0644' "$RECIPE"; then
	printf '  ok   recipe 安装 keyring.pem 0644\n'
else
	echo "  FAIL recipe 没有把 keyring.pem 以 0644 装进 /etc/rauc"
	fail=1
fi
if grep -R -n -E 'BEGIN (RSA |OPENSSH |ENCRYPTED )?PRIVATE KEY' \
	meta-lubancat .github ci >/tmp/rauc-sign-priv.out 2>&1; then
	echo "  FAIL 仓里出现了私钥"
	redact /tmp/rauc-sign-priv.out | sed 's/^/       | /'
	fail=1
else
	printf '  ok   仓里没有私钥 PEM\n'
fi

echo "== prepare-rauc-signing-key"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
	-subj /CN=rauc-sign-test \
	-keyout "$tmp/match.key" -out "$tmp/match.crt" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
	-subj /CN=rauc-sign-other \
	-keyout "$tmp/other.key" -out "$tmp/other.crt" 2>/dev/null
chmod 600 "$tmp/match.key" "$tmp/other.key"
body=$(sed -n '2p' "$tmp/match.key")

run_prep() {
	# $1 = name, $2 = want exit, $3 = key material, $4 = cert, $5 = extra grep of log (optional)
	name=$1
	want=$2
	material=$3
	use_cert=$4
	need=${5:-}
	out=$tmp/out.key
	rm -f "$out"
	set +e
	RAUC_SIGNING_KEY="$material" timeout 20 "$PREPARE" "$use_cert" "$out" >/tmp/rauc-sign.out 2>&1
	got=$?
	set -e
	if [ "$got" -ne "$want" ]; then
		printf '  FAIL %s (exit %s, want %s)\n' "$name" "$got" "$want"
		redact /tmp/rauc-sign.out | sed 's/^/       | /'
		fail=1
		return
	fi
	if [ -n "$body" ] && grep -q -F "$body" /tmp/rauc-sign.out; then
		echo "  FAIL $name 日志里出现了私钥正文"
		fail=1
		return
	fi
	if [ -n "$need" ] && ! grep -q "$need" /tmp/rauc-sign.out; then
		printf '  FAIL %s 日志缺少 %s\n' "$name" "$need"
		redact /tmp/rauc-sign.out | sed 's/^/       | /'
		fail=1
		return
	fi
	printf '  ok   %s\n' "$name"
}

run_prep "空 secret" 1 "" "$tmp/match.crt" "RAUC_SIGNING_KEY"
run_prep "垃圾字符串" 1 "not-a-pem-key" "$tmp/match.crt" ""
run_prep "base64 解出来不是 PEM" 1 "$(printf hello | base64 -w0)" "$tmp/match.crt" "不是 PEM"
run_prep "公钥不匹配" 1 "$(cat "$tmp/other.key")" "$tmp/match.crt" "不一致"

rm -f "$tmp/out.key"
set +e
env -u RAUC_SIGNING_KEY timeout 20 "$PREPARE" "$tmp/match.crt" "$tmp/out.key" >/tmp/rauc-sign.out 2>&1
got=$?
set -e
if [ "$got" -ne 0 ] && grep -q 'RAUC_SIGNING_KEY' /tmp/rauc-sign.out && [ ! -e "$tmp/out.key" ]; then
	printf '  ok   未设置 secret\n'
else
	echo "  FAIL 未设置 secret (exit $got)"
	redact /tmp/rauc-sign.out | sed 's/^/       | /'
	fail=1
fi

old_umask=$(umask)
umask 000
run_prep "原文 PEM" 0 "$(cat "$tmp/match.key")" "$tmp/match.crt" "matches committed"
umask "$old_umask"
if [ -f "$tmp/out.key" ]; then
	mode=$(stat -c %a "$tmp/out.key")
	if [ "$mode" = 600 ]; then
		printf '  ok   写出的私钥是 600(umask 000 也一样)\n'
	else
		echo "  FAIL 私钥模式 $mode,想要 600"
		fail=1
	fi
	openssl pkey -in "$tmp/out.key" -pubout > "$tmp/out.pub"
	openssl x509 -in "$tmp/match.crt" -noout -pubkey > "$tmp/crt.pub"
	if cmp -s "$tmp/out.pub" "$tmp/crt.pub"; then
		printf '  ok   写出的私钥与证书公钥一致\n'
	else
		echo "  FAIL 写出的私钥与证书公钥不一致"
		fail=1
	fi
else
	echo "  FAIL 原文 PEM 没有留下密钥文件"
	fail=1
fi

b64=$(base64 -w0 "$tmp/match.key")
case $b64 in
	*-----BEGIN*) echo "  FAIL 测试夹具的 base64 里竟然有 BEGIN"; fail=1 ;;
esac
run_prep "单行 base64 PEM" 0 "$b64" "$tmp/match.crt" "matches committed"
if [ -f "$tmp/out.key" ] && [ "$(stat -c %a "$tmp/out.key")" = 600 ]; then
	printf '  ok   base64 路径也是 600\n'
else
	echo "  FAIL base64 路径没有留下 600 的密钥"
	fail=1
fi
wrapped=$(base64 -w 64 "$tmp/match.key")
run_prep "换行 base64 PEM" 0 "$wrapped" "$tmp/match.crt" "matches committed"

# 失败不得留下密钥文件
rm -f "$tmp/out.key"
set +e
RAUC_SIGNING_KEY=$(cat "$tmp/other.key") timeout 20 "$PREPARE" "$tmp/match.crt" "$tmp/out.key" >/dev/null 2>&1
set -e
if [ -e "$tmp/out.key" ]; then
	echo "  FAIL 核对失败后密钥文件还在"
	fail=1
else
	printf '  ok   核对失败会删掉密钥文件\n'
fi

run_prep "与仓内证书不匹配" 1 "$(cat "$tmp/match.key")" "$CERT" "不一致"

rm -f "$tmp/xtrace.key"
set +e
RAUC_SIGNING_KEY=$(cat "$tmp/match.key") sh -x "$PREPARE" "$tmp/match.crt" "$tmp/xtrace.key" >/tmp/rauc-sign.out 2>&1
got=$?
set -e
if [ "$got" -ne 0 ]; then
	echo "  FAIL sh -x 下核对失败 (exit $got)"
	redact /tmp/rauc-sign.out | sed 's/^/       | /'
	fail=1
elif grep -q -F "$body" /tmp/rauc-sign.out; then
	echo "  FAIL sh -x 把私钥正文打进了日志"
	fail=1
elif [ ! -f "$tmp/xtrace.key" ] || [ "$(stat -c %a "$tmp/xtrace.key")" != 600 ]; then
	echo "  FAIL sh -x 没有留下 600 的密钥文件"
	fail=1
else
	printf '  ok   sh -x 也不会把私钥打进日志\n'
fi

echo "== 镜像 keyring 自查"
pack() {
	# $1 = 目录, $2 = 输出 tar,其余是 tar 参数
	dir=$1
	out=$2
	shift 2
	tar -C "$dir" -czf "$out" "$@"
}

good=$tmp/good
mkdir -p "$good/etc/rauc"
cp "$CERT" "$good/etc/rauc/keyring.pem"
cp "$CONF" "$good/etc/rauc/system.conf"
chmod 0644 "$good/etc/rauc/keyring.pem" "$good/etc/rauc/system.conf"
pack "$good" "$tmp/good.tar" etc
expect "证书与 system.conf 都在" 0 "$CHECK" "$tmp/good.tar" "$CERT"

dot=$tmp/dot
mkdir -p "$dot/etc/rauc"
cp "$CERT" "$dot/etc/rauc/keyring.pem"
cp "$CONF" "$dot/etc/rauc/system.conf"
chmod 0644 "$dot/etc/rauc/keyring.pem"
pack "$dot" "$tmp/dot.tar" .
expect "成员前缀 ./" 0 "$CHECK" "$tmp/dot.tar" "$CERT"

loose=$tmp/loose
mkdir -p "$loose/etc/rauc"
cp "$CERT" "$loose/etc/rauc/keyring.pem"
cp "$CONF" "$loose/etc/rauc/system.conf"
chmod 0600 "$loose/etc/rauc/keyring.pem"
pack "$loose" "$tmp/loose.tar" etc
expect "keyring 不是 0644" 1 "$CHECK" "$tmp/loose.tar" "$CERT"

nokey=$tmp/nokey
mkdir -p "$nokey/etc/rauc"
cp "$CONF" "$nokey/etc/rauc/system.conf"
pack "$nokey" "$tmp/nokey.tar" etc
expect "缺 keyring.pem" 1 "$CHECK" "$tmp/nokey.tar" "$CERT"

badconf=$tmp/badconf
mkdir -p "$badconf/etc/rauc"
cp "$CERT" "$badconf/etc/rauc/keyring.pem"
chmod 0644 "$badconf/etc/rauc/keyring.pem"
printf '%s\n' '[system]' 'compatible=lubancat-rk3566' > "$badconf/etc/rauc/system.conf"
pack "$badconf" "$tmp/badconf.tar" etc
expect "system.conf 没有 keyring" 1 "$CHECK" "$tmp/badconf.tar" "$CERT"

wrong=$tmp/wrong
mkdir -p "$wrong/etc/rauc"
cp "$tmp/match.crt" "$wrong/etc/rauc/keyring.pem"
cp "$CONF" "$wrong/etc/rauc/system.conf"
chmod 0644 "$wrong/etc/rauc/keyring.pem"
pack "$wrong" "$tmp/wrong.tar" etc
expect "证书字节不一致" 1 "$CHECK" "$tmp/wrong.tar" "$CERT"

echo "== workflow 接线"
secret_n=$(grep -c 'secrets\.RAUC_SIGNING_KEY' "$WORKFLOW" || true)
if [ "$secret_n" -eq 1 ]; then
	printf '  ok   RAUC_SIGNING_KEY 只引用一次\n'
else
	echo "  FAIL secrets.RAUC_SIGNING_KEY 出现 $secret_n 次,想要 1"
	fail=1
fi
# 单引号是故意的:$ 要留给 grep,不能被 shell 展开成空值。
# shellcheck disable=SC2016
if grep -E '(echo|printf).*\$(RAUC_SIGNING_KEY|\{RAUC_SIGNING_KEY)' "$WORKFLOW"; then
	echo "  FAIL workflow 会把 RAUC_SIGNING_KEY 的值打进日志"
	fail=1
else
	printf '  ok   workflow 不打印密钥的值\n'
fi
if grep -n 'set -x' "$WORKFLOW"; then
	echo "  FAIL workflow 开了 xtrace,私钥会进日志"
	fail=1
else
	printf '  ok   workflow 没有 set -x\n'
fi
for needle in \
	'ci/prepare-rauc-signing-key.sh' \
	'unset RAUC_SIGNING_KEY' \
	'ci/check-image-rauc-keyring.sh' \
	'multipart_chunksize = 64MB' \
	'max_concurrent_requests = 4' \
	'update.raucb 上传失败'
do
	if grep -q -F "$needle" "$WORKFLOW"; then
		printf '  ok   workflow 含 %s\n' "$needle"
	else
		echo "  FAIL workflow 缺 $needle"
		fail=1
	fi
done
if grep -q 'ota-ephemeral-' "$WORKFLOW" || grep -q 'openssl req -x509' "$WORKFLOW"; then
	echo "  FAIL workflow 仍在生成一次性证书"
	fail=1
else
	printf '  ok   已去掉一次性自签\n'
fi
if grep -q -- '--keyring' "$WORKFLOW"; then
	printf '  ok   bundle 用仓内证书验签\n'
else
	echo "  FAIL workflow 没有用 --keyring 验 bundle"
	fail=1
fi

rm -f /tmp/rauc-sign.out /tmp/rauc-sign-priv.out
if [ "$fail" -ne 0 ]; then
	echo "FAILED"
	exit 1
fi
echo "ok"
