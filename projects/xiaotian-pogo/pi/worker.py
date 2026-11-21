"""Private stdio adapter for the QML launcher; no listening network socket.

One worker owns the ESP session. Host login/logout commands must come from the
terminal's authenticated account controller, not from untrusted module input.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from node_client import NetworkClient, SerialClient, LoginSession, set_enabled


class Controller:
    def __init__(self, client, emit, record_dir):
        self.client, self.emit, self.record_dir = client, emit, Path(record_dir)
        self.recording = None
        self.record_file = None
        self.user = None
        self.boot = None
        self.desired = None

    def publish(self, data):
        # Never pass pairing secrets or private event records to the live page.
        data = {k: v for k, v in data.items() if k not in ('token', 'password', 'events', 'request_id')}
        self.emit(dict(type='status', data=data, authenticated=self.user is not None))

    def stop_recording(self):
        if self.recording:
            self.recording.close()
            self.recording = None
        if self.record_file:
            self.record_file.close()
            self.record_file = None

    def logout(self):
        self.user = None
        self.stop_recording()

    def command(self, command):
        op = command.get('op')
        if op == 'enable':
            status = set_enabled(self.client, True)
            self.desired = True
            self.publish(status)
        elif op == 'disable':
            # Remember stop intent even if the stop ACK is lost. Never restore
            # monitoring on reboot following an unconfirmed disable request.
            self.desired = False
            self.stop_recording()
            self.publish(set_enabled(self.client, False))
        elif op == 'login':
            self.logout()
            user = command.get('user_key')
            if not isinstance(user, str) or not 1 <= len(user) <= 128:
                raise ValueError('Invalid authenticated user key')
            self.user = user
        elif op == 'logout':
            self.logout()
        elif op == 'record_start':
            if not self.user:
                raise ValueError('Login through the terminal first')
            if self.recording:
                return
            # Hash user IDs for path safety; record contents retain account link.
            self.record_dir.mkdir(parents=True, exist_ok=True)
            name = hashlib.sha256(self.user.encode()).hexdigest() + '.jsonl'
            fd = os.open(str(self.record_dir / name), os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
            self.record_file = os.fdopen(fd, 'a', encoding='utf-8')
            def consume(row):
                self.record_file.write(json.dumps(row, ensure_ascii=False) + '\n')
                self.record_file.flush()
            try:
                self.recording = LoginSession(self.client, self.user, consume)
            except Exception:
                self.stop_recording()
                raise
        elif op == 'record_stop':
            self.stop_recording()
        else:
            raise ValueError('Unknown local command')

    def tick(self):
        status = self.client.call('status')
        if self.boot and status['boot_id'] != self.boot:
            self.stop_recording()  # Reboot never restores a personal session.
            if self.desired is True:
                status = set_enabled(self.client, True)
        self.boot = status['boot_id']
        if self.recording:
            status = self.recording.poll()
        self.publish(status)

    def connection_failed(self):
        self.stop_recording()
        self.emit(dict(type='offline', message='连接中断，当前状态未知；个人记录已停止'))


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser()
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--device', type=Path)
    target.add_argument('--serial')
    parser.add_argument('--host')
    parser.add_argument('--record-dir', type=Path, default=Path.home() / '.local/share/xiaotian/records')
    args = parser.parse_args()
    client = SerialClient(args.serial) if args.serial else NetworkClient(json.loads(args.device.read_text(encoding='utf-8-sig')), args.host)
    commands = queue.Queue(maxsize=32)
    eof = threading.Event()
    def read_commands():
        try:
            for line in sys.stdin:
                try:
                    data = json.loads(line)
                    commands.put_nowait(data)
                except (ValueError, queue.Full):
                    emit(dict(type='error', message='本地命令格式错误或队列已满'))
        finally:
            eof.set()
    threading.Thread(target=read_commands, daemon=True).start()
    controller = Controller(client, emit, args.record_dir)
    try:
        while not eof.is_set():
            try:
                command = commands.get(timeout=0.05)
            except queue.Empty:
                command = None
            if command is not None:
                try:
                    controller.command(command)
                    emit(dict(type='ack', op=command.get('op'), ok=True))
                except Exception as exc:
                    emit(dict(type='ack', op=command.get('op'), ok=False, message=type(exc).__name__))
            try:
                controller.tick()
            except Exception:
                controller.connection_failed()
            # Process up to one command between polls; avoid blocking the GUI.
            try:
                command = commands.get(timeout=0.8)
                commands.task_done()
                try:
                    controller.command(command)
                    emit(dict(type='ack', op=command.get('op'), ok=True))
                except Exception as exc:
                    emit(dict(type='ack', op=command.get('op'), ok=False, message=type(exc).__name__))
            except queue.Empty:
                pass
    finally:
        controller.logout()
        client.close()


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    main()
