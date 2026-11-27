#!/bin/sh
# 把 GitHub Secret RAUC_SIGNING_KEY 落成 mode 600 的私钥文件,并在签名前
# 核对它与仓内公钥证书是一对。私钥只写入调用方给出的路径,不进 stdout/stderr,
# 不进 argv。
#
# secret 两种形态都收:
#   - 原文 PEM(内容里有 -----BEGIN)
#   - 没有 -----BEGIN 的 base64(空白会被去掉,解码后仍须是 PEM)
# 加密私钥没有口令可用,-passin pass: 会立刻失败,而不是在 CI 里卡住。
set -eu
# 关掉调用方的 xtrace。sh -x 会把私钥展开进 stderr。
set +x

if [ "$#" -ne 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
	echo "usage: $0 <cert.pem> <key-out>" >&2
	exit 2
fi

cert=$1
key_out=$2

die() {
	echo "::error::$*" >&2
	rm -f "$key_out"
	exit 1
}

[ -f "$cert" ] || die "找不到公钥证书 $cert"
command -v openssl >/dev/null 2>&1 || die "需要 openssl 才能核对 RAUC_SIGNING_KEY 与证书"

if [ -z "${RAUC_SIGNING_KEY:-}" ]; then
	die "RAUC_SIGNING_KEY 为空。发布 OTA bundle 需要 GitHub Secret RAUC_SIGNING_KEY:原文 PEM 私钥,或无 -----BEGIN 的 base64 PEM。私钥不进仓。"
fi

# 先把模式钉成 600 再写入,避免 umask 过宽时密钥落在别人可读的文件里。
umask 077
rm -f "$key_out"
: > "$key_out"
chmod 600 "$key_out"

if printf '%s' "$RAUC_SIGNING_KEY" | grep -q -- '-----BEGIN'; then
	printf '%s\n' "$RAUC_SIGNING_KEY" > "$key_out"
else
	b64_err=$(mktemp)
	if ! printf '%s' "$RAUC_SIGNING_KEY" | tr -d '[:space:]' | base64 -d > "$key_out" 2>"$b64_err"; then
		err=$(sed -e '/-----BEGIN/,/-----END/d' "$b64_err" | head -c 300 || true)
		rm -f "$b64_err" "$key_out"
		die "RAUC_SIGNING_KEY 不含 -----BEGIN,按 base64 解码失败${err:+: $err}"
	fi
	rm -f "$b64_err"
	if ! grep -q -- '-----BEGIN' "$key_out"; then
		rm -f "$key_out"
		die "RAUC_SIGNING_KEY 按 base64 解码后不是 PEM 私钥"
	fi
fi
chmod 600 "$key_out"

pub_err=$(mktemp)
cert_pub=$(mktemp)
key_pub=$(mktemp)
cert_mod=$(mktemp)
key_mod=$(mktemp)
trap 'rm -f "$pub_err" "$cert_pub" "$key_pub" "$cert_mod" "$key_mod"' EXIT

if ! openssl x509 -in "$cert" -noout -pubkey > "$cert_pub" 2>"$pub_err"; then
	err=$(sed -e '/-----BEGIN/,/-----END/d' "$pub_err" | head -c 300 || true)
	die "公钥证书无法解析${err:+: $err}"
fi
if ! openssl pkey -in "$key_out" -pubout -passin pass: > "$key_pub" 2>"$pub_err"; then
	err=$(sed -e '/-----BEGIN/,/-----END/d' "$pub_err" | head -c 300 || true)
	die "RAUC_SIGNING_KEY 无法解析为未加密的 PEM 私钥${err:+: $err}"
fi
if ! cmp -s "$cert_pub" "$key_pub"; then
	die "RAUC_SIGNING_KEY 与仓内证书公钥不一致(pubkey 不匹配)。Secret 配错了,拒绝签名。"
fi

# pubkey 已一致时 modulus 必然一致;再比一次,避免只看 PEM 文本包装。
if ! openssl x509 -in "$cert" -noout -modulus > "$cert_mod" 2>"$pub_err"; then
	err=$(sed -e '/-----BEGIN/,/-----END/d' "$pub_err" | head -c 300 || true)
	die "无法读取证书 modulus${err:+: $err}"
fi
if ! openssl rsa -in "$key_out" -noout -modulus -passin pass: > "$key_mod" 2>"$pub_err"; then
	err=$(sed -e '/-----BEGIN/,/-----END/d' "$pub_err" | head -c 300 || true)
	die "无法读取 RAUC_SIGNING_KEY 的 modulus${err:+: $err}"
fi
if ! cmp -s "$cert_mod" "$key_mod"; then
	die "RAUC_SIGNING_KEY 与仓内证书的 modulus 不一致。Secret 配错了,拒绝签名。"
fi

echo "RAUC signing key matches committed certificate" >&2
