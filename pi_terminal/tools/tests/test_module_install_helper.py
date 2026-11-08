#!/usr/bin/env python3
"""模块安装 helper 的最小契约测试：签名、复制、篡改拒绝。"""
import platform
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ARCH = {"x86_64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}.get(platform.machine(), platform.machine())
TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from package_tool import build, install, local_fetch  # noqa: E402

from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        source = root / "source"
        source.mkdir()
        (source / "manifest.json").write_text(json.dumps({
            "module_id": 77, "package_id": "helper.test", "package_version": "1.0.0",
            "name": "Helper Test", "abi_version": 1, "host_arch": [ARCH],
            "qt_major": 6, "unload_contract": "synchronous-stop-v1",
            "library": "libhelper.so", "qml_page": "page.qml"}))
        shutil.copyfile("/bin/true", source / "libhelper.so")
        (source / "page.qml").write_text("import QtQuick\nItem {}\n")
        private = Ed25519PrivateKey.generate()
        (root / "key.pem").write_bytes(private.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption()))
        (root / "key.pub").write_bytes(private.public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))
        build(source, root / "pkg", root / "key.pem", ARCH)
        target = install("", root / "key.pub", root / "cache", 77, ARCH,
                         local_fetch(root / "pkg"))
        command = [sys.executable, str(TOOLS / "module_install_helper.py"),
                   "--source", str(target),
                   "--descriptor", str(target) + ".package.json",
                   "--root", str(root / "modules"),
                   "--key", str(root / "key.pub"),
                   "--module", "77", "--arch", ARCH,
                   "--allow-user-root"]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stderr, file=sys.stderr)
            return 1
        installed = Path(result.stdout.strip())
        if not (installed / "manifest.json").is_file():
            print("installed tree missing", file=sys.stderr)
            return 1
        (target / "page.qml").write_text("tampered")
        tampered = subprocess.run(command, capture_output=True, text=True)
        if tampered.returncode == 0:
            print("tampered source was accepted", file=sys.stderr)
            return 1
    print("module install helper: signed copy + tamper rejection OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
