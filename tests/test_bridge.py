import importlib.util
import io
import json
import os
import threading
from pathlib import Path
import unittest
from unittest.mock import patch, Mock
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bridge', ROOT / 'bridge.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
IP = '8.8.4.4'

class Firewall(b.Bridge):
    def __init__(self):
        self.base = 'https://192.168.50.1'
        self.rules = {}
        self.calls = []
        self.fail_second = False
        self.kill_fails = False
        self.serial = 0

    def api(self, path, payload=None):
        self.calls.append((path, payload))
        if path.endswith('search_rule'):
            return {'rows': list(self.rules.values())}
        if path.endswith('add_rule'):
            self.serial += 1
            if self.fail_second and self.serial == 2:
                return {'result': 'failed', 'validations': {'rule': 'invalid'}}
            uuid = 'rule-' + str(self.serial)
            self.rules[uuid] = dict(payload['rule'], uuid=uuid)
            return {'result': 'saved', 'uuid': uuid}
        if '/del_rule/' in path:
            self.rules.pop(path.rsplit('/', 1)[1], None)
            return {'result': 'deleted'}
        if '/set_rule/' in path:
            self.rules[path.rsplit('/', 1)[1]].update(payload['rule'])
            return {'result': 'saved'}
        if path.endswith('/apply'):
            return {'status': 'OK\n'}
        if path.endswith('/kill_states'):
            return {'result': 'failed' if self.kill_fails else 'ok'}
        raise AssertionError(path)

class BridgeTests(unittest.TestCase):
    def test_one_second_polling(self):
        self.assertEqual(b.next_delay({'age': 0.1, 'interval': 2}, 1), 1)
        self.assertEqual(b.next_delay({'age': 1.5, 'interval': 2}, 1), .58)

    def test_slow_rule_checks_do_not_pause_traffic(self):
        entered = threading.Event()
        release = threading.Event()
        traffic = Mock()
        host = Mock()
        traffic.poll.return_value = {'status':'ok', 'age':0.1, 'interval':2, 'flows':[]}
        def slow_rules():
            entered.set()
            release.wait(2)
            return []
        host.managed_rules.side_effect = slow_rules
        host.blocked_hosts.return_value = []
        worker = b.HostActions('https://firewall', 'unused', 2, True)
        worker.bridge = host
        emitted = []
        with patch.object(b, 'emit', side_effect=emitted.append):
            thread = threading.Thread(target=worker.execute, args=({'action':'hosts'},))
            thread.start()
            try:
                self.assertTrue(entered.wait(1))
                for _ in range(3):
                    b.emit(b.compact(traffic.poll()))
                self.assertEqual(len(emitted),3)
                self.assertTrue(all(event['status']=='ok' for event in emitted))
                self.assertTrue(thread.is_alive())
            finally:
                release.set()
                thread.join(1)
            self.assertEqual(emitted[-1]['type'],'hosts')

    def test_actions_trigger_traffic_refresh_and_host_list(self):
        worker = b.HostActions('https://firewall', 'unused', 2, True)
        worker.bridge = Mock()
        worker.bridge.change_host.return_value = IP + ' blocked'
        worker.bridge.blocked_hosts.return_value = [{'ip':IP,'complete':True}]
        messages=[]
        with patch.object(b, 'emit', side_effect=messages.append):
            worker.execute({'action':'block','ip':IP})
        self.assertTrue(worker.refresh_requested.is_set())
        self.assertEqual(messages[0]['type'],'action')
        self.assertEqual(messages[1]['hosts'][0]['ip'],IP)

    def test_compaction_keeps_hostname_and_identity(self):
        sample = {'hostnames': {IP: 'dns.google'}, 'flows': [{'origin':'192.168.50.2', 'dest':IP,
            'inside':[{'ip':'192.168.50.2','name':'laptop','interface':'LAN'}]}]}
        result = b.compact(sample)
        self.assertEqual(result['hostnames'][IP], 'dns.google')
        self.assertEqual(result['flows'][0]['dest'], IP)
        self.assertEqual(result['flows'][0]['inside'][0]['name'], 'laptop')

    def test_clock_fresh_stale_and_invalid(self):
        self.assertAlmostEqual(b.next_delay({'age':0.1,'interval':2}, 2), 1.98)
        self.assertAlmostEqual(b.next_delay({'age':1.9,'interval':2}, 2), .25)
        for sample in ({}, {'age':float('nan'),'interval':2}, {'age':0,'interval':0}):
            self.assertEqual(b.next_delay(sample, 2), 2)
        self.assertGreaterEqual(b.next_delay({'age':60.1,'interval':2}, 2), .25)

    def test_session_expiry_recovers_json_login_page(self):
        bridge = object.__new__(b.Bridge)
        bridge.logged_in = True
        outcomes = [b.BridgeError('login page'), {'status':'ok'}]
        def summary():
            result = outcomes.pop(0)
            if isinstance(result, Exception): raise result
            return result
        bridge.summary = summary
        with patch.object(bridge, 'login') as login:
            self.assertEqual(bridge.poll()['status'], 'ok')
            login.assert_called_once()

    @patch.object(b.subprocess, 'check_output', return_value=b'[{"addr_info":[{"local":"192.168.50.30"}]}]')
    def test_protect_firewall_workstation_and_special_addresses(self, _):
        for address in ('192.168.50.1','192.168.50.30','127.0.0.1','::1','224.0.0.1','0.0.0.0', IP+'/24','host;touch /tmp/x'):
            with self.subTest(address=address), self.assertRaises(b.BridgeError):
                b.validate_host(address,'https://192.168.50.1',{})
        with self.assertRaises(b.BridgeError):
            b.validate_host('2606:4700:4700::1111', 'https://192.168.50.1',
                {'locations':[{'id':'2606:4700:4700:0:0:0:0:1111','local':True}]})

    @patch.object(b.subprocess, 'check_output', return_value=b'[]')
    def test_bidirectional_block_idempotent_and_unblock(self, _):
        firewall = Firewall()
        self.assertIn('connections closed', firewall.change_host(IP, True, {}))
        rules = firewall.managed_rules()
        self.assertEqual(len(rules), 2)
        self.assertEqual({(r['source_net'],r['destination_net']) for r in rules}, {(IP,'any'),('any',IP)})
        self.assertTrue(all(r['direction']=='any' and r['interface']=='' and r['quick']=='1' for r in rules))
        firewall.change_host(IP, True, {})
        self.assertEqual(len(firewall.rules), 2)
        self.assertEqual(firewall.blocked_hosts(firewall.managed_rules()), [{'ip':IP,'complete':True}])
        firewall.change_host(IP, False, {})
        self.assertEqual(firewall.rules, {})

    @patch.object(b.subprocess, 'check_output', return_value=b'[]')
    def test_second_rule_failure_rolls_back(self, _):
        firewall = Firewall(); firewall.fail_second = True
        with self.assertRaises(b.BridgeError): firewall.change_host(IP, True, {})
        self.assertEqual(firewall.rules, {})
        self.assertFalse(any(path.endswith('/kill_states') for path,_ in firewall.calls))

    @patch.object(b.subprocess, 'check_output', return_value=b'[]')
    def test_existing_connections_warning(self, _):
        firewall = Firewall(); firewall.kill_fails = True
        message = firewall.change_host(IP, True, {})
        self.assertIn('may continue', message)
        self.assertEqual(len(firewall.managed_rules()), 2)

    @patch.object(b.subprocess, 'check_output', return_value=b'[]')
    def test_unrelated_rule_not_deleted(self, _):
        firewall = Firewall()
        firewall.rules['user-rule'] = {'uuid':'user-rule', 'action':'pass','description':b.RULE_PREFIX+IP,
            'source_net':IP,'destination_net':'any','direction':'any','quick':'1','enabled':'1'}
        firewall.change_host(IP, False, {})
        self.assertIn('user-rule',firewall.rules)

    def test_mutation_is_not_retried_after_network_error(self):
        bridge = object.__new__(b.Bridge); bridge.logged_in=True; bridge.csrf='token'
        with patch.object(bridge,'request',side_effect=urllib.error.URLError('timeout')) as request:
            with self.assertRaises(urllib.error.URLError): bridge.api('/api/firewall/filter/add_rule', {'rule':{}})
            request.assert_called_once()

    def test_csrf_layout_and_header(self):
        bridge = object.__new__(b.Bridge); bridge.logged_in=True; bridge.csrf=''
        page = b'xhr.setRequestHeader("X-CSRFToken", "token123" );'
        with patch.object(bridge,'request',side_effect=[io.BytesIO(page),io.BytesIO(b'{"result":"saved"}')]) as request:
            self.assertEqual(bridge.api('/api/example',{})['result'],'saved')
            self.assertEqual(request.call_args.args[2]['X-CSRFToken'],'token123')

    def test_multiple_commands_in_one_write(self):
        read, write = os.pipe()
        try:
            commands = b.Commands(read)
            os.write(write,b'{"action":"refresh"}\n{"action":"hosts"}\n')
            self.assertEqual(commands.read(0)['action'],'refresh')
            self.assertEqual(commands.read(0)['action'],'hosts')
            self.assertIsNone(commands.read(0))
            os.write(write,b'[]\nnot json\n')
            self.assertEqual(commands.read(0),{})
            self.assertEqual(commands.read(0),{})
        finally: os.close(read); os.close(write)

if __name__ == '__main__': unittest.main()
