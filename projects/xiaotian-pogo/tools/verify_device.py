"""Verify v2.1 on the explicitly approved board. Ends in standby, no recording."""
import argparse
import json
from pathlib import Path
import time
from node_client import SerialClient, RpcError, set_enabled, save_private

p = argparse.ArgumentParser()
p.add_argument('--port', required=True)
p.add_argument('--expected-mac', required=True)
args = p.parse_args()
root = Path(__file__).resolve().parents[1]
client = SerialClient(args.port)
rows = []
def log(name, value):
    rows.append(dict(test=name, data=value))
    print(name, json.dumps(value), flush=True)
try:
    status = client.call('status')
    assert status['device_id'] == 'xiaotian-' + args.expected_mac.replace(':', '').lower()
    assert status['version'] == '2.1.0'
    assert status['pogo']['ready'] and status['pogo']['module_id'] == 81
    log('boot_and_identity', status)
    for i in range(2):
        status = set_enabled(client, True)
        time.sleep(0.15)
        status = client.call('status')
        assert status['enabled'] and status['stable'] in (0, 1)
        log('enable_' + str(i), status)
        status = set_enabled(client, False)
        assert not status['enabled'] and status['stable'] == -1
        log('disable_' + str(i), status)
    status = set_enabled(client, True)
    params = dict(boot_id=status['boot_id'], owner='bench', session='v21-test')
    assert client.call('record_start', **params)['recording']
    log('record_stop', client.call('record_stop', **params))
    client.call('record_start', **params)
    time.sleep(5.2)
    status = client.call('status')
    assert not status['recording'] and status['enabled']
    log('lease_expired_monitoring_continues', status)
    pairing = client.call('provision')
    pairing.pop('request_id', None)
    save_private(root / '.private/device.json', pairing)
    log('private_pairing_saved', dict(device_id=pairing['device_id'], ok=True))
finally:
    try:
        log('final_standby', set_enabled(client, False))
    finally:
        client.close()
        (root / 'firmware/verification/v21-usb.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
