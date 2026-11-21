"""Flash ONLY the identified infrared board; no whole-chip erase or eFuse changes."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

EXPECTED_MAC = 'd8:85:ac:dd:b3:b8'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', default='COM8')
    p.add_argument('--expected-mac', default=EXPECTED_MAC,
                   help='Explicitly confirmed target MAC; mismatch stops before writes')
    args = p.parse_args()
    firmware = Path(__file__).resolve().parents[1] / 'firmware'
    artifacts = firmware / 'artifacts'
    probe = [sys.executable, '-m', 'esptool', '--chip', 'esp32s3', '--port', args.port, '--baud', '115200']
    result = subprocess.run(probe + ['read_mac'], capture_output=True, text=True)
    print(result.stdout, end='')
    if not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', args.expected_mac):
        raise SystemExit('Invalid expected MAC')
    if result.returncode or not re.search(r'MAC:\s*' + re.escape(args.expected_mac), result.stdout, re.IGNORECASE):
        raise SystemExit('STOP: infrared module MAC does not match; nothing flashed')
    config = json.loads((artifacts / 'flasher_args.json').read_text(encoding='utf-8-sig'))
    files = []
    for offset, file in config['flash_files'].items():
        path = artifacts / Path(file).name
        if not path.is_file():
            raise SystemExit('Missing artifact: ' + str(path))
        files += [offset, str(path)]
    command = [sys.executable, '-m', 'esptool', '--chip', 'esp32s3', '--port', args.port,
               '--baud', '460800', 'write_flash', '--flash_mode', 'dio',
               '--flash_freq', '40m', '--flash_size', '16MB'] + files
    result = subprocess.run(command, capture_output=True, text=True)
    report = result.stdout + result.stderr
    (firmware / 'verification/v21-flash.log').write_text(report, encoding='utf-8')
    print(report)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
