#!/usr/bin/env python3
"""Model of vendor U-Boot 2017.09 hush, not that binary.

Checked against JeffyCN/mirrors a93658f8 common/cli_hush.c:
break is not compiled (builtin table is ifndef __U_BOOT__), and
cmd_process() does not stop run_list_real()'s for loop. make_list_in()
splits on spaces. Nested if is a real context stack (reserved_word
FLAG_START/FLAG_END) and is modeled by recursion here.

This file does not execute the 2017.09 interpreter. A result here is
not a substitute for the board's serial log.
"""

import pathlib
import sys

PATCH = pathlib.Path(__file__).resolve().parents[1] / (
    "meta-lubancat/recipes-bsp/u-boot/files/0002-rk3568-ab-slot-boot.patch"
)

# The script shipped on build #88. break does not stop the loop, so
# BOOT_ORDER=A B ends on B.
BUGGY = (
    'if test -z "${BOOT_ORDER}"; then setenv BOOT_ORDER "A B"; fi; '
    'if test -z "${BOOT_A_LEFT}"; then setenv BOOT_A_LEFT 3; fi; '
    'if test -z "${BOOT_B_LEFT}"; then setenv BOOT_B_LEFT 3; fi; '
    'setenv BOOT_SLOT ""; '
    'for slot in ${BOOT_ORDER}; do '
    'if test "${slot}" = "A" -a "${BOOT_A_LEFT}" -gt 0; then setenv BOOT_SLOT "A"; fi; '
    'if test "${slot}" = "B" -a "${BOOT_B_LEFT}" -gt 0; then setenv BOOT_SLOT "B"; fi; '
    'if test -n "${BOOT_SLOT}"; then '
    'if test "${upgrade_available}" = "1"; then '
    'if test "${BOOT_SLOT}" = "A"; then setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1; fi; '
    'if test "${BOOT_SLOT}" = "B"; then setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1; fi; '
    'if test "${BOOT_SLOT}" = "A" -a "${BOOT_A_LEFT}" = "0"; then setenv BOOT_ORDER "B"; fi; '
    'if test "${BOOT_SLOT}" = "B" -a "${BOOT_B_LEFT}" = "0"; then setenv BOOT_ORDER "A"; fi; '
    'saveenv; '
    'fi; '
    'break; '
    'fi; '
    'done; '
    'if test -z "${BOOT_SLOT}"; then setenv BOOT_SLOT "A"; fi'
)


def extract_ab_boot(patch_text):
    body = []
    capturing = False
    for line in patch_text.splitlines():
        if not line.startswith("+"):
            if capturing:
                break
            continue
        text = line[1:].strip()
        if text.startswith('"ab_boot="'):
            capturing = True
            continue
        if not capturing:
            continue
        if text.startswith('"altbootcmd="'):
            break
        if text.endswith("\\"):
            text = text[:-1].rstrip()
        if text.startswith('"') and text.endswith('"'):
            text = text[1:-1]
        elif text.startswith('"'):
            text = text[1:]
            if text.endswith('"'):
                text = text[:-1]
        text = text.replace('\\"', '"')
        body.append(text)
    script = "".join(body)
    if script.endswith("\\0"):
        script = script[:-2]
    if not script.startswith("if test"):
        raise SystemExit("failed to extract ab_boot from patch")
    return script


def tokenize(src):
    tokens = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
            continue
        if c == '"':
            i += 1
            buf = []
            while i < n and src[i] != '"':
                buf.append(src[i])
                i += 1
            i += 1
            tokens.append("".join(buf))
            continue
        if c == ';':
            tokens.append(";")
            i += 1
            continue
        buf = []
        while i < n and not src[i].isspace() and src[i] not in ';"':
            buf.append(src[i])
            i += 1
        tokens.append("".join(buf))
    return tokens


class Hush:
    def __init__(self, env):
        self.env = dict(env)
        self.saves = 0
        self.unknown = []

    def expand(self, token):
        out = []
        i = 0
        while i < len(token):
            if token.startswith("${", i):
                end = token.find("}", i)
                name = token[i + 2 : end]
                out.append(self.env.get(name, ""))
                i = end + 1
            else:
                out.append(token[i])
                i += 1
        return "".join(out)

    def run(self, script):
        self.exec_list(tokenize(script), 0)

    def exec_list(self, tokens, pos):
        while pos < len(tokens):
            pos = self.exec_one(tokens, pos)
        return pos

    def exec_one(self, tokens, pos):
        if pos >= len(tokens):
            return pos
        word = tokens[pos]
        if word == "if":
            return self.exec_if(tokens, pos)
        if word == "for":
            return self.exec_for(tokens, pos)
        if word in ("fi", "done", "then", "do", "else"):
            return pos
        if word == ";":
            return pos + 1
        return self.exec_simple(tokens, pos)

    def exec_simple(self, tokens, pos):
        cmd = []
        while pos < len(tokens) and tokens[pos] not in (";", "then", "do", "fi", "done", "else"):
            cmd.append(tokens[pos])
            pos += 1
        if pos < len(tokens) and tokens[pos] == ";":
            pos += 1
        if not cmd:
            return pos
        self.command(cmd)
        return pos

    def command(self, cmd):
        name = cmd[0]
        if name == "setenv":
            self.env[cmd[1]] = self.expand(cmd[2]) if len(cmd) > 2 else ""
            return
        if name == "setexpr":
            # NAME ${NAME} - 1
            cur = int(self.expand(cmd[2]) or "0")
            if cmd[3] != "-" or cmd[4] != "1":
                raise SystemExit(f"unsupported setexpr {cmd}")
            self.env[cmd[1]] = str(cur - 1)
            return
        if name == "saveenv":
            self.saves += 1
            return
        if name == "test":
            return
        if name == "break":
            self.unknown.append("break")
            return
        raise SystemExit(f"unsupported command {cmd}")

    def test_ok(self, args):
        args = [self.expand(a) for a in args]
        if "-a" in args:
            cut = args.index("-a")
            return self.test_ok(args[:cut]) and self.test_ok(args[cut + 1 :])
        if args[0] == "-z":
            return args[1] == ""
        if args[0] == "-n":
            return args[1] != ""
        if len(args) == 3 and args[1] == "=":
            return args[0] == args[2]
        if len(args) == 3 and args[1] == "-gt":
            return int(args[0] or "0") > int(args[2] or "0")
        raise SystemExit(f"unsupported test {args}")

    def exec_if(self, tokens, pos):
        # if test ARGS ; then BODY fi
        if tokens[pos] != "if" or tokens[pos + 1] != "test":
            raise SystemExit(f"bad if at {tokens[pos:pos+4]}")
        pos += 2
        args = []
        while tokens[pos] != ";":
            args.append(tokens[pos])
            pos += 1
        pos += 1  # ;
        if tokens[pos] != "then":
            raise SystemExit("if without then")
        pos += 1
        cond = self.test_ok(args)
        depth = 0
        body_start = pos
        while pos < len(tokens):
            if tokens[pos] == "if":
                depth += 1
            elif tokens[pos] == "fi" and depth == 0:
                break
            elif tokens[pos] == "fi":
                depth -= 1
            pos += 1
        body_end = pos
        if cond:
            self.exec_list(tokens[body_start:body_end], 0)
        if pos < len(tokens) and tokens[pos] == "fi":
            pos += 1
        if pos < len(tokens) and tokens[pos] == ";":
            pos += 1
        return pos

    def exec_for(self, tokens, pos):
        # for NAME in WORDS ; do BODY done
        name = tokens[pos + 1]
        if tokens[pos + 2] != "in":
            raise SystemExit("for without in")
        pos = pos + 3
        words = []
        while tokens[pos] != ";":
            words.append(tokens[pos])
            pos += 1
        pos += 1
        if tokens[pos] != "do":
            raise SystemExit("for without do")
        pos += 1
        depth_for = 0
        depth_if = 0
        body_start = pos
        while pos < len(tokens):
            if tokens[pos] == "for":
                depth_for += 1
            elif tokens[pos] == "done" and depth_for == 0 and depth_if == 0:
                break
            elif tokens[pos] == "done" and depth_for:
                depth_for -= 1
            elif tokens[pos] == "if":
                depth_if += 1
            elif tokens[pos] == "fi" and depth_if:
                depth_if -= 1
            pos += 1
        body = tokens[body_start:pos]
        items = []
        for word in words:
            items.extend(self.expand(word).split())
        # Vendor hush does not stop on break. Iterate every item.
        for item in items:
            self.env[name] = item
            self.exec_list(body, 0)
        if pos < len(tokens) and tokens[pos] == "done":
            pos += 1
        if pos < len(tokens) and tokens[pos] == ";":
            pos += 1
        return pos


def run(script, **env):
    hush = Hush(env)
    hush.run(script)
    return hush


def expect(name, cond, detail):
    if cond:
        print(f"  ok   {name}")
        return 0
    print(f"  FAIL {name}: {detail}")
    return 1


def main():
    fail = 0
    patch = PATCH.read_text()
    script = extract_ab_boot(patch)
    if "break" in script:
        fail += expect("fixed script does not call break", False, script)
    else:
        fail += expect("fixed script does not call break", True, "")

    buggy = run(BUGGY, BOOT_ORDER="A B", BOOT_A_LEFT="3", BOOT_B_LEFT="3", upgrade_available="0")
    fail += expect(
        "#88 script: A B with break-as-nop selects B",
        buggy.env["BOOT_SLOT"] == "B" and buggy.saves == 0 and "break" in buggy.unknown,
        buggy.env,
    )

    fresh = run(script, BOOT_ORDER="A B", BOOT_A_LEFT="3", BOOT_B_LEFT="3", upgrade_available="0")
    fail += expect(
        "default A B selects A and does not saveenv",
        fresh.env["BOOT_SLOT"] == "A"
        and fresh.env["BOOT_ORDER"] == "A B"
        and fresh.env["BOOT_A_LEFT"] == "3"
        and fresh.saves == 0,
        fresh.env,
    )

    flipped = run(script, BOOT_ORDER="B A", BOOT_A_LEFT="3", BOOT_B_LEFT="3", upgrade_available="0")
    fail += expect("BOOT_ORDER B A selects B", flipped.env["BOOT_SLOT"] == "B", flipped.env)

    a_dead = run(script, BOOT_ORDER="A B", BOOT_A_LEFT="0", BOOT_B_LEFT="3", upgrade_available="0")
    fail += expect("A LEFT 0 falls through to B", a_dead.env["BOOT_SLOT"] == "B", a_dead.env)

    none = run(script, BOOT_ORDER="A B", BOOT_A_LEFT="0", BOOT_B_LEFT="0", upgrade_available="0")
    fail += expect("both LEFT 0 falls back to A", none.env["BOOT_SLOT"] == "A", none.env)

    dec = run(script, BOOT_ORDER="A B", BOOT_A_LEFT="3", BOOT_B_LEFT="3", upgrade_available="1")
    fail += expect(
        "upgrade decrements only A, once",
        dec.env["BOOT_SLOT"] == "A"
        and dec.env["BOOT_A_LEFT"] == "2"
        and dec.env["BOOT_B_LEFT"] == "3"
        and dec.env["BOOT_ORDER"] == "A B"
        and dec.saves == 1,
        (dec.env, dec.saves),
    )

    drop = run(script, BOOT_ORDER="A B", BOOT_A_LEFT="1", BOOT_B_LEFT="3", upgrade_available="1")
    fail += expect(
        "A reaching 0 is removed from BOOT_ORDER",
        drop.env["BOOT_SLOT"] == "A" and drop.env["BOOT_A_LEFT"] == "0" and drop.env["BOOT_ORDER"] == "B" and drop.saves == 1,
        drop.env,
    )

    b_only = run(script, BOOT_ORDER="A B", BOOT_A_LEFT="0", BOOT_B_LEFT="2", upgrade_available="1")
    fail += expect(
        "skipped A does not consume the one saveenv",
        b_only.env["BOOT_SLOT"] == "B"
        and b_only.env["BOOT_B_LEFT"] == "1"
        and b_only.env["BOOT_A_LEFT"] == "0"
        and b_only.saves == 1,
        (b_only.env, b_only.saves),
    )

    print(f"\n通过检查,失败 {fail}")
    return fail


if __name__ == "__main__":
    sys.exit(main())
