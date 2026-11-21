"""Create the reviewable, secret-free baseline delivery and verify every hash."""
import hashlib
import json
from pathlib import Path
import tempfile
import zipfile

root=Path(__file__).resolve().parents[1]
files=[]
for path in root.rglob('*'):
    if not path.is_file(): continue
    relative=path.relative_to(root)
    if any(part in ('.private','__pycache__','deliverables','build') for part in relative.parts): continue
    if path.suffix in ('.pyc','.exe'): continue
    if relative.as_posix() in ('firmware/verification/build-stage.txt',): continue
    files.append(path)
manifest={p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
output=root/'deliverables/xiaotian-pogo-qml-baseline-20261118.zip'
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as archive:
    for path in files: archive.write(path,path.relative_to(root).as_posix())
    archive.writestr('MANIFEST-SHA256.json',json.dumps(manifest,ensure_ascii=False,indent=2))
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    for name,digest in manifest.items(): assert hashlib.sha256(archive.read(name)).hexdigest()==digest
    private=root/'.private/device.json'
    if private.exists():
        token=json.loads(private.read_text(encoding='utf-8'))['token'].encode()
        assert all(token not in archive.read(name) for name in archive.namelist())
temp=Path(tempfile.gettempdir())/'xiaotian-pogo-qml-handoff-20261118.md'
temp.write_bytes((root/'接手先看.md').read_bytes())
result=dict(file=str(output),bytes=output.stat().st_size,files=len(manifest),
            sha256=hashlib.sha256(output.read_bytes()).hexdigest(),temp_handoff=str(temp))
(output.parent/'xiaotian-pogo-qml-baseline-20261118.sha256.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False,indent=2))
