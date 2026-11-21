"""Passive serial capture; no commands and no intentional reset."""
import argparse
from pathlib import Path
import time
import serial
import sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--port', required=True)
p.add_argument('--seconds', type=float, default=15)
p.add_argument('--output', type=Path, required=True)
args = p.parse_args()
port = serial.Serial(port=None, baudrate=115200, timeout=0.2)
port.dtr = False
port.rts = False
port.port = args.port
port.open()
data = bytearray()
try:
    end = time.monotonic() + args.seconds
    while time.monotonic() < end:
        data.extend(port.read(max(1, port.in_waiting)))
finally:
    port.close()
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.with_suffix('.bin').write_bytes(data)
text = data.decode('utf-8', errors='replace')
args.output.with_suffix('.log').write_text(text, encoding='utf-8')
print('CAPTURE port=%s bytes=%d seconds=%s' % (args.port, len(data), args.seconds))
print(text[-22000:])
if data and not text.strip():
    print('HEX:', data[:256].hex(' '))
