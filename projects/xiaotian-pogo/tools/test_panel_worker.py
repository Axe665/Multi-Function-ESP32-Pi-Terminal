import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('worker', Path(__file__).resolve().parents[1] / 'pi/worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class FakeClient:
    def __init__(self):
        self.enabled = False
        self.recording = False
        self.boot = 'a'
        self.seq = 1
        self.calls = []
    def call(self, op, **args):
        self.calls.append((op, args))
        if op == 'enable': self.enabled = True
        if op == 'disable': self.enabled = self.recording = False
        if op == 'record_start':
            if not self.enabled: raise RuntimeError('disabled')
            self.recording = True
        if op == 'record_stop': self.recording = False
        return dict(ok=True, schema='xiaotian.node.v2', device_id='xiaotian-test',
                    enabled=self.enabled, boot_id=self.boot, revision=0,
                    seq=self.seq, record_epoch=1, recording=self.recording,
                    pogo=dict(wired=False), events=[], gap=False)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.client = FakeClient()
        self.out = []
        self.controller = worker.Controller(self.client, self.out.append, self.tmp.name)
    def tearDown(self):
        self.controller.logout()
        self.tmp.cleanup()
    def test_guest_cannot_record(self):
        self.controller.command(dict(op='enable'))
        with self.assertRaises(ValueError): self.controller.command(dict(op='record_start'))
        self.assertEqual(list(Path(self.tmp.name).glob('*')), [])
    def test_logout_keeps_sampling_and_no_history_sent_to_page(self):
        self.controller.command(dict(op='enable'))
        self.controller.command(dict(op='login', user_key='user-a'))
        self.controller.command(dict(op='record_start'))
        self.controller.tick()
        self.assertNotIn('events', self.out[-1]['data'])
        self.controller.command(dict(op='logout'))
        self.assertTrue(self.client.enabled)
        self.assertFalse(self.client.recording)
        self.assertIsNone(self.controller.recording)
    def test_reboot_restores_only_monitoring(self):
        self.controller.command(dict(op='enable'))
        self.controller.tick()
        self.controller.command(dict(op='login', user_key='user-a'))
        self.controller.command(dict(op='record_start'))
        self.client.boot='b'; self.client.enabled=False; self.client.recording=False
        self.controller.tick()
        self.assertTrue(self.client.enabled)
        self.assertIsNone(self.controller.recording)
    def test_disabled_does_not_restore_on_reboot(self):
        self.controller.command(dict(op='enable'))
        self.controller.tick()
        self.controller.command(dict(op='disable'))
        self.client.boot='b'
        self.controller.tick()
        self.assertFalse(self.client.enabled)
    def test_pogo_separation_does_not_control_monitoring(self):
        self.controller.command(dict(op='enable'))
        self.controller.tick()
        self.assertTrue(self.client.enabled)
        self.assertFalse(self.out[-1]['data']['pogo']['wired'])
    def test_connection_loss_stops_recording(self):
        self.controller.command(dict(op='enable'))
        self.controller.command(dict(op='login',user_key='user-a'))
        self.controller.command(dict(op='record_start'))
        self.controller.connection_failed()
        self.assertTrue(self.client.enabled)
        self.assertIsNone(self.controller.recording)


if __name__ == '__main__':
    unittest.main()
