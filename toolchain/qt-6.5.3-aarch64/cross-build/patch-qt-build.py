#!/usr/bin/env python3
"""给 Qt 构建树打 GLIBC 2.36 兼容补丁（幂等，可重复执行）。

背景：宿主的交叉 gcc 内置路径 /usr/aarch64-linux-gnu/{include,lib}（glibc 2.39）
排在 --sysroot（Pi 的 glibc 2.36）之前，导致：
  * C++ 代码引用 __isoc23_*（2.38 新符号）        -> 链接时 undefined reference
  * .gnu.version_r 记录 GLIBC_2.38 需求           -> Pi 上 "GLIBC_2.38 not found"
本脚本做两件事：
  1) 在 CMake 的每条 *LINKER* rule 里把 sysroot 的 lib 目录插到 --sysroot 之后
     （-L 优先于内置路径，使 libc/libm 解析到 2.36）；
  2) 在链接命令和 GN 的 rspfile_content 末尾追加 isoc23_compat.o，
     补齐 __isoc23_strtol/sscanf/... 等 7 个符号（映射到 2.36 的同名函数）。

用法：
  python3 patch-qt-build.py <build_dir> <sysroot> <stub.o>
"""
import os
import sys

LINKER_MARK = "LINKER"


def patch_rules_ninja(path, sysroot, stub):
    sysroot_flag = "--sysroot=" + sysroot
    libs = "-L%s/usr/lib/aarch64-linux-gnu -L%s/lib/aarch64-linux-gnu" % (sysroot, sysroot)
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        lines = f.read().split("\n")
    cur = None
    n_lib = n_stub = 0
    for i, line in enumerate(lines):
        if line.startswith("rule "):
            cur = line[5:].strip()
        elif line.startswith("  command = ") and cur and LINKER_MARK in cur:
            if sysroot_flag in line and libs not in line:
                lines[i] = line.replace(sysroot_flag, sysroot_flag + " " + libs, 1)
                n_lib += 1
            if lines[i].rstrip().endswith("$LINK_LIBRARIES && $POST_BUILD") and stub not in lines[i]:
                lines[i] = lines[i].replace(
                    "$LINK_LIBRARIES && $POST_BUILD",
                    "$LINK_LIBRARIES %s && $POST_BUILD" % stub, 1)
                n_stub += 1
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("\n".join(lines))
    return n_lib, n_stub


def patch_gn_toolchain(path, stub):
    """GN 生成的 toolchain.ninja：solink / solink_module 的 rspfile_content 追加 stub。"""
    if not os.path.exists(path):
        return 0
    marker = "rspfile_content = -Wl,--whole-archive ${in} ${solibs} -Wl,--no-whole-archive ${libs} -Wl,--whole-archive ${rlibs} -Wl,--no-whole-archive"
    n = 0
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        lines = f.read().split("\n")
    for i, line in enumerate(lines):
        if line.strip() == marker and stub not in line:
            lines[i] = line.rstrip() + " " + stub
            n += 1
    if n:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write("\n".join(lines))
    return n


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    build_dir, sysroot, stub = sys.argv[1], sys.argv[2], sys.argv[3]
    rules = os.path.join(build_dir, "CMakeFiles", "rules.ninja")
    if not os.path.exists(rules):
        print("找不到 %s（先 configure）" % rules)
        return 1
    n_lib, n_stub = patch_rules_ninja(rules, sysroot, stub)
    print("rules.ninja: 注入 -L %d 条，注入 stub %d 条" % (n_lib, n_stub))
    total_gn = 0
    for sub in ("core", "pdf"):
        p = os.path.join(build_dir, "qtwebengine", "src", sub,
                         "Release", "aarch64", "toolchain.ninja")
        k = patch_gn_toolchain(p, stub)
        if k:
            print("%s/toolchain.ninja: 注入 stub %d 条" % (sub, k))
        total_gn += k
    print("完成。若 Qt 重新 configure，需要重新跑一次本脚本。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
