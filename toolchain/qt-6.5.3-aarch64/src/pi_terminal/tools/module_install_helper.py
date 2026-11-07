#!/usr/bin/env python3
"""以 root 把已签名、已解包的模块目录安装到系统模块根。

宿主先以普通用户把包验证/解压到用户缓存，然后通过 pkexec 调用本 helper。
helper 会重新校验签名描述符和整棵树，再原子复制到 root 只读模块目录。
"""
import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_tool import validate_tree, verify_descriptor  # noqa: E402


def copy_verified(source: Path, target: Path) -> None:
    root = target.parent
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o755)
    if target.exists():
        return
    temp = Path(tempfile.mkdtemp(prefix=".incoming-", dir=root))
    try:
        for current, dirs, files in os.walk(source):
            rel = Path(current).relative_to(source)
            out_dir = temp / rel
            out_dir.mkdir(parents=True, exist_ok=True)
            for name in files:
                src = Path(current) / name
                if src.is_symlink():
                    raise ValueError("symlink in verified source")
                dst = out_dir / name
                shutil.copyfile(src, dst)
                os.chmod(dst, 0o755 if name.endswith(".sh") else 0o644)
        for current, dirs, files in os.walk(temp):
            os.chmod(current, 0o755)
        os.replace(temp, target)
        temp = None
    finally:
        if temp is not None:
            shutil.rmtree(temp, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--descriptor", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--module", required=True, type=int)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--allow-user-root", action="store_true",
                        help="仅测试：允许非 root 写入临时模块根")
    args = parser.parse_args()

    if os.geteuid() != 0 and not args.allow_user_root:
        print("module-install-helper must run as root", file=sys.stderr)
        return 2
    source = Path(args.source).resolve()
    descriptor = Path(args.descriptor).resolve()
    root = Path(args.root).resolve()
    if not source.is_dir() or not descriptor.is_file():
        print("source/descriptor missing", file=sys.stderr)
        return 2
    try:
        data = descriptor.read_bytes()
        desc = verify_descriptor(data, args.key, args.module, args.arch)
        validate_tree(source, desc)
        target = root / desc["sha256"]
        copy_verified(source, target)
        if os.geteuid() == 0:
            os.chown(root, 0, 0)
            os.chmod(root, 0o755)
        if os.geteuid() == 0:
            for current, dirs, files in os.walk(target):
                os.chown(current, 0, 0)
                for name in files:
                    os.chown(Path(current) / name, 0, 0)
        print(target)
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"module install failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
