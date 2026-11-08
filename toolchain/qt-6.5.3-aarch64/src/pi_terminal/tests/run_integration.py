#!/usr/bin/env python3
import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools'))
import package_tool
from mock_module import services

def main():
    p=argparse.ArgumentParser(); p.add_argument('build'); args=p.parse_args()
    build=Path(args.build).resolve()
    # The hotspot package URL may become reachable shortly after NetworkManager
    # reports AP activation while the ESP STA is still associating. Exercise the
    # bounded transport retry without changing the real network.
    original_builder = package_tool.urllib.request.build_opener
    class FlakyOpener:
        def __init__(self): self.attempts = 0
        def open(self, url, timeout):
            self.attempts += 1
            if self.attempts < 3:
                raise package_tool.urllib.error.URLError('simulated transient association delay')
            return io.BytesIO(b'package-ready')
    flaky = FlakyOpener()
    package_tool.urllib.request.build_opener = lambda *handlers: flaky
    try:
        assert package_tool.download('http://192.0.2.1/package.tar.zst', 64) == b'package-ready'
        assert flaky.attempts == 3
    finally:
        package_tool.urllib.request.build_opener = original_builder
    with tempfile.TemporaryDirectory(prefix='terminal-integration-') as tmp:
        tmp=Path(tmp); plugin=tmp/'plugin'; plugin.mkdir()
        for name in ('manifest.json','libexample_module.so'):
            shutil.copy(build/'modules/example'/name,plugin/name)
        shutil.copytree(root/'modules/example/qml',plugin/'qml')
        subprocess.run([sys.executable,str(root/'tools/package_tool.py'),'keys',str(tmp/'keys')],check=True)
        arch=json.loads((plugin/'manifest.json').read_text())['host_arch'][0]
        package_tool.build(plugin,tmp/'http',tmp/'keys/private.pem',arch)
        # 包服务仍走真实 HTTP 服务；本测试只验证签名包/缓存/篡改拒绝。
        tcp,http=services(tmp/'http','desktop-test-only')
        url=f'http://127.0.0.1:{http.server_port}'
        try:
            # Signed metadata, archive tamper, cache tamper and incompatible architecture.
            target=package_tool.install(url,tmp/'keys/public.pem',tmp/'cache',80,arch)
            (target/'qml/ExamplePage.qml').write_text('tampered')
            try: package_tool.install(url,tmp/'keys/public.pem',tmp/'cache',80,arch)
            except ValueError: pass
            else: raise AssertionError('cache tamper accepted')
            shutil.rmtree(target)
            envelope=json.loads((tmp/'http/package.json').read_text()); envelope['descriptor']['module_id']=129
            (tmp/'http/package.json').write_text(json.dumps(envelope))
            try: package_tool.install(url,tmp/'keys/public.pem',tmp/'cache',129,arch)
            except Exception: pass
            else: raise AssertionError('invalid signature accepted')
            package_tool.build(plugin,tmp/'http',tmp/'keys/private.pem',arch)
            archive=tmp/'http/package.tar.zst'; archive.write_bytes(archive.read_bytes()+b'x')
            try: package_tool.install(url,tmp/'keys/public.pem',tmp/'cache',80,arch)
            except ValueError: pass
            else: raise AssertionError('archive tamper accepted')
            package_tool.build(plugin,tmp/'http',tmp/'keys/private.pem',arch)
            print('PASS: signed package install, cache reuse, tamper rejection')
        finally:
            tcp.shutdown();http.shutdown();tcp.server_close();http.server_close()
if __name__=='__main__': main()
