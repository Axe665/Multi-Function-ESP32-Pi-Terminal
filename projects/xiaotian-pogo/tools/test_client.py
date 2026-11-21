import hashlib
import ssl
import unittest
from unittest.mock import patch
from node_client import PinnedConnection, NetworkClient, LoginSession, RpcError


class FakeSocket:
    def getpeercert(self, binary_form=False):
        return b'known-certificate'

    def close(self):
        pass


class PinTests(unittest.TestCase):
    def test_bad_pin_sends_no_request(self):
        config = dict(host='test', port=8443, pin_sha256='0'*64, token='secret')
        def connect(conn):
            conn.sock = FakeSocket()
        with patch('http.client.HTTPSConnection.connect', connect), patch('http.client.HTTPSConnection.request') as request:
            with self.assertRaises(ssl.SSLError):
                NetworkClient(config).call('enable')
            request.assert_not_called()

    def test_good_pin(self):
        pin = hashlib.sha256(b'known-certificate').hexdigest()
        conn = PinnedConnection('test', 8443, pin)
        with patch('http.client.HTTPSConnection.connect', lambda c: setattr(c, 'sock', FakeSocket())):
            conn.connect()
        conn.close()

    def test_missing_pin_rejected(self):
        with self.assertRaises(ValueError):
            PinnedConnection('test', 8443, '')


class FakeClient:
    def __init__(self):
        self.calls = []
        self.fail = False
        self.gap = False
    def call(self, op, **kwargs):
        self.calls.append((op, kwargs))
        if self.fail and op == 'record_keepalive':
            raise TimeoutError()
        row = dict(ok=True, enabled=True, seq=3, boot_id='boot', record_epoch=2, device_id='device')
        if op == 'events':
            row.update(gap=self.gap, events=[dict(seq=4, record_epoch=2, stable=0)])
        return row


class SessionTests(unittest.TestCase):
    def test_logout_stops_local_callbacks_and_does_not_disable(self):
        client, rows = FakeClient(), []
        session = LoginSession(client, 'private-user', rows.append)
        session.poll()
        self.assertEqual(rows[0]['user_key'], 'private-user')
        self.assertNotIn('private-user', repr(client.calls))
        session.close()
        self.assertTrue(session.closed)
        with self.assertRaises(RpcError):
            session.poll()
        self.assertNotIn('disable', [op for op, _ in client.calls])
        self.assertEqual(client.calls[-1][0], 'record_stop')

    def test_connection_failure_cannot_resume_old_user(self):
        client = FakeClient()
        session = LoginSession(client, 'user-a', lambda e: None)
        client.fail = True
        with self.assertRaises(TimeoutError):
            session.poll()
        self.assertTrue(session.closed)
        self.assertIsNone(session.user_key)

    def test_overflow_rejected_before_delivery(self):
        client, rows = FakeClient(), []
        client.gap = True
        session = LoginSession(client, 'user', rows.append)
        with self.assertRaises(RpcError):
            session.poll()
        self.assertFalse(rows)
        self.assertTrue(session.closed)


if __name__ == '__main__':
    unittest.main()
