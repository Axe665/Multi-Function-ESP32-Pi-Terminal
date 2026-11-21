"""Xiaotian v2 control. Python 3.9+; pyserial is required only for USB.

TLS uses an out-of-band USB-paired certificate SHA256 pin. Certificate checking
below MUST finish before the Authorization header or request body is sent.
"""
import argparse
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import ssl
import time
import uuid


class RpcError(RuntimeError):
    pass


class PinnedConnection(http.client.HTTPSConnection):
    def __init__(self, host, port, fingerprint, timeout=3):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.fingerprint = fingerprint.lower()
        if len(self.fingerprint) != 64 or any(c not in '0123456789abcdef' for c in self.fingerprint):
            raise ValueError('A paired SHA256 certificate pin is required')
        super().__init__(host, port, timeout=timeout, context=context)

    def connect(self):
        super().connect()
        actual = hashlib.sha256(self.sock.getpeercert(binary_form=True)).hexdigest()
        if not hmac.compare_digest(actual, self.fingerprint):
            self.close()
            raise ssl.SSLError('Certificate pin mismatch: request was NOT sent')


class NetworkClient:
    def __init__(self, config, host=None):
        self.config = config
        self.host = host or config['host']

    def call(self, op, **kwargs):
        body = json.dumps(dict(op=op, **kwargs), separators=(',', ':')).encode()
        conn = PinnedConnection(self.host, self.config.get('port', 8443), self.config['pin_sha256'])
        try:
            conn.connect()  # Pin check precedes credentials and body.
            conn.request('POST', '/v1/rpc', body=body, headers={
                'Authorization': 'Bearer ' + self.config['token'],
                'Content-Type': 'application/json', 'Connection': 'close'})
            response = conn.getresponse()
            data = json.loads(response.read())
            if response.status != 200:
                raise RpcError('HTTP ' + str(response.status))
            return check(data)
        finally:
            conn.close()

    def close(self):
        pass


def check(data):
    if not data.get('ok'):
        raise RpcError(data.get('error', 'unknown_error'))
    return data


class SerialClient:
    def __init__(self, port):
        import serial
        self.serial = serial.Serial(port=None, baudrate=115200, timeout=0.3, write_timeout=3)
        self.serial.dtr = False
        self.serial.rts = False
        self.serial.port = port
        self.serial.open()
        self.buffer = bytearray()

    def call(self, op, **kwargs):
        request_id = uuid.uuid4().hex
        self.serial.write((json.dumps(dict(op=op, request_id=request_id, **kwargs)) + '\n').encode())
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            self.buffer.extend(self.serial.read(max(1, self.serial.in_waiting)))
            while b'\n' in self.buffer:
                raw, _, rest = self.buffer.partition(b'\n')
                self.buffer = bytearray(rest)
                try:
                    row = json.loads(raw.decode('utf-8', errors='strict'))
                except (ValueError, UnicodeError):
                    continue
                if row.get('request_id') == request_id:
                    return check(row)
            if len(self.buffer) > 16384:
                self.buffer.clear()
        raise TimeoutError('No matching USB reply; check port and wait for NODE_READY')

    def close(self):
        self.serial.close()


def set_enabled(client, enabled):
    current = client.call('status')
    return client.call('enable' if enabled else 'disable', boot_id=current['boot_id'],
                       if_revision=current['revision'])


def save_private(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(data, stream, indent=2)
    os.chmod(path, 0o600)


class LoginSession:
    """Call only AFTER the Pi's real authentication succeeds.

    No account identifier leaves the Pi. A random session and a controller ID
    are sent to the module. poll() must be called at least once per second.
    After a transport failure we close this object; require an explicit new
    authenticated session rather than replaying data across users.
    """
    def __init__(self, client, user_key, consume, owner='pi-controller'):
        self.client, self.user_key, self.consume = client, user_key, consume
        self.owner, self.session = owner, uuid.uuid4().hex
        status = client.call('status')
        if not status['enabled']:
            raise RpcError('Enable monitoring before recording')
        self.boot = status['boot_id']
        self.after = status['seq']
        self.closed = False
        started = client.call('record_start', **self.params())
        self.epoch = started['record_epoch']

    def params(self):
        return dict(boot_id=self.boot, owner=self.owner, session=self.session)

    def poll(self):
        if self.closed:
            raise RpcError('Session is closed')
        try:
            self.client.call('record_keepalive', **self.params())
            reply = self.client.call('events', after_seq=self.after, **self.params())
            if reply['record_epoch'] != self.epoch or reply['boot_id'] != self.boot:
                raise RpcError('Recording generation changed')
            if reply.get('gap'):
                raise RpcError('Event buffer overflow: data is incomplete')
            for event in reply['events']:
                if event['record_epoch'] != self.epoch or event['seq'] <= self.after:
                    continue
                # Pi associates a record with the logged-in user at this point.
                self.consume(dict(user_key=self.user_key, device_id=reply['device_id'],
                                  boot_id=self.boot, received_unix=time.time(), **event))
                self.after = event['seq']
            return reply
        except Exception:
            self.close()
            raise

    def close(self):
        if self.closed:
            return
        self.closed = True  # Stop local callbacks BEFORE attempting remote stop.
        self.consume = lambda event: None
        self.user_key = None
        try:
            self.client.call('record_stop', **self.params())
        except (OSError, RpcError, TimeoutError, ValueError):
            # Device lease expires in <=5 seconds when stop cannot be delivered.
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--serial', help='USB UART port, e.g. COM8 or /dev/ttyUSB0')
    target.add_argument('--device', type=Path, help='Private USB pairing JSON')
    parser.add_argument('--host', help='Override IP after DHCP address changes')
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('status', 'enable', 'disable', 'watch'):
        sub.add_parser(name)
    provision = sub.add_parser('provision')
    provision.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / '.private/device.json')
    wifi = sub.add_parser('wifi')
    wifi.add_argument('--config', required=True, type=Path, help='Private JSON: ssid/password')
    record = sub.add_parser('record')
    record.add_argument('--user-key', required=True, help='Opaque local Pi user ID (not sent to ESP)')
    record.add_argument('--output', required=True, type=Path, help='Private per-user JSONL file on Pi')
    args = parser.parse_args()
    client = SerialClient(args.serial) if args.serial else NetworkClient(json.loads(args.device.read_text(encoding='utf-8-sig')), args.host)
    session = None
    try:
        if args.command in ('enable', 'disable'):
            print(json.dumps(set_enabled(client, args.command == 'enable')))
        elif args.command == 'provision':
            data = client.call('provision')
            data.pop('request_id', None)
            save_private(args.output, data)
            print('Private pairing saved: ' + str(args.output) + ' (do not share or put in ZIP/Git)')
        elif args.command == 'wifi':
            data = json.loads(args.config.read_text(encoding='utf-8-sig'))
            print(json.dumps(client.call('set_wifi', ssid=data['ssid'], password=data['password'])))
        elif args.command == 'status':
            print(json.dumps(client.call('status')))
        elif args.command == 'watch':
            while True:
                try:
                    print(json.dumps(client.call('status')), flush=True)
                except (OSError, RpcError, TimeoutError, ValueError) as exc:
                    print(json.dumps(dict(offline=True, error=type(exc).__name__)), flush=True)
                time.sleep(1)
        elif args.command == 'record':
            args.output.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(str(args.output), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, 'a', encoding='utf-8') as stream:
                def consume(event):
                    stream.write(json.dumps(event) + '\n')
                    stream.flush()
                session = LoginSession(client, args.user_key, consume)
                print('Recording logged-in session; Ctrl+C logs out and leaves monitoring enabled.')
                try:
                    while True:
                        reply = session.poll()
                        print(json.dumps({k: reply[k] for k in ('enabled', 'recording', 'state', 'seq')}), flush=True)
                        time.sleep(1)
                finally:
                    session.close()
    except KeyboardInterrupt:
        pass
    finally:
        if session:
            session.close()
        client.close()


if __name__ == '__main__':
    main()
