"""Exercise the real shell workflow with a fake CLI; no cluster or credentials."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
HELM = os.environ.get("HELM", "helm")
CHART = ROOT / "charts/openshell-opencode"
FAKE_CLI = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
work = Path(os.environ['WORK'])
scenario = os.environ['SCENARIO']
with (work / 'calls.jsonl').open('a') as log:
    log.write(json.dumps({'args': args, 'credential': 'LLM_API_KEY' in os.environ}) + '\n')
if args[:2] == ['sandbox', 'list']:
    if scenario == 'auth':
        print('Unauthenticated secret-key', file=sys.stderr); sys.exit(1)
    current = {'name':'opencode', 'phase':'Ready', 'annotations':{'openshell-opencode/config-hash':os.environ['HASH']}}
    if scenario == 'drift': current['annotations'] = {}
    if scenario.startswith('v2-'):
        current['annotations'] = {'openshell-opencode/static-config-hash':os.environ['STATIC_HASH']}
    if scenario in ['v2-static-drift', 'recreate', 'recreate-delete-error']:
        current['annotations']['openshell-opencode/static-config-hash'] = 'different'
    if scenario == 'stopped': current['phase'] = 'Stopped'
    if '--page-token' not in args:
        print(json.dumps({'sandboxes':[], 'next_page_token':'page2'}))
    else:
        print(json.dumps({'sandboxes':[] if scenario == 'fresh' or (work / 'deleted').exists() else [current]}))
elif args[:2] == ['sandbox', 'delete']:
    if scenario == 'recreate-delete-error': sys.exit(1)
    (work / 'deleted').touch()
elif args[:2] == ['policy', 'get']:
    policy = json.loads(os.environ['INITIAL_POLICY'])
    policy['filesystem_policy']['read_write'].append('/runtime-added')
    if '--rev' in args:
        rev = int(args[args.index('--rev') + 1])
        print(json.dumps({'version':rev, 'active_version':rev,
                          'status':'superseded' if scenario == 'policy-superseded' else 'loaded',
                          'policy':policy}))
    else:
        print(json.dumps({'policy_source':'global' if scenario == 'global-policy' else 'sandbox', 'policy':policy}))
elif args[:2] == ['policy', 'set']:
    policy = json.loads(Path(args[args.index('--policy') + 1]).read_text())
    (work / 'submitted-policy.json').write_text(json.dumps(policy))
    if scenario == 'policy-error':
        print('Policy rejected', file=sys.stderr); sys.exit(1)
    if scenario == 'policy-timeout': sys.exit(124)
    if scenario == 'policy-unchanged':
        print('· Policy unchanged (version 2, hash: abc)', file=sys.stderr)
    else:
        print('✓ Policy version 2 submitted (hash: abc)', file=sys.stderr)
elif args[:2] == ['profile', 'export']:
    if scenario == 'fresh':
        print('NotFound', file=sys.stderr); sys.exit(1)
    if scenario == 'profile-error':
        print('Unauthenticated secret-key', file=sys.stderr); sys.exit(1)
    print('{"resource_version":4}')
elif args[:2] == ['provider', 'list']:
    print(json.dumps({'providers':[] if scenario == 'fresh' else [{'name':'opencode-llm'}]}))
elif args[:2] == ['sandbox', 'get']:
    print(json.dumps({'phase':'Error' if scenario == 'runtime-error' else 'Ready'}))
elif args[:2] == ['sandbox', 'exec']:
    if 'opencode run' in ' '.join(args):
        if scenario == 'model-error': print('{"type":"error"}')
        elif scenario != 'silent': print('{"type":"text","part":{"text":"MODEL_OK"}}')
    elif 'opencode.json.new' in ' '.join(args):
        (work / 'uploaded.json').write_text(sys.stdin.read())
    else: print('1.19.6')
else: print('ok')
'''


class SetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = cls.render('https://llm.example.com:8443/api/v1/')

    @staticmethod
    def render(url):
        output = subprocess.check_output([
            HELM, 'template', 'openshell-opencode', str(CHART),
            '--set-string', 'model.baseURL=' + url,
            '--set-string', 'model.id=my/model',
            '--set', 'openshell.agentSandbox.preflight.enabled=false',
        ], text=True, stderr=subprocess.PIPE)
        return next(doc['data'] for doc in yaml.safe_load_all(output)
                    if doc and doc['kind'] == 'ConfigMap' and 'setup.sh' in doc.get('data', {}))

    def test_rendered_configuration(self):
        profile = json.loads(self.data['provider.json'])
        endpoint = profile['endpoints'][0]
        self.assertEqual((endpoint['host'], endpoint['port'], endpoint['path']),
                         ('llm.example.com', 8443, '/api/v1/**'))
        config = json.loads(self.data['opencode.json'])
        self.assertEqual(config['model'], 'custom/my/model')
        self.assertEqual(config['provider']['custom']['options']['apiKey'], '{env:LLM_API_KEY}')
        ipv6 = json.loads(self.render('https://[2001:db8::1]/v1')['provider.json'])
        self.assertEqual(ipv6['endpoints'][0]['host'], '2001:db8::1')
        self.assertEqual(ipv6['endpoints'][0]['port'], 443)

    def test_openshift_security_contexts(self):
        output = subprocess.check_output([
            HELM, 'template', 'openshell-opencode', str(CHART),
            '-f', str(CHART / 'values.yaml'),
            '--set', 'openshell.agentSandbox.preflight.enabled=false',
        ], text=True, stderr=subprocess.PIPE)
        documents = [doc for doc in yaml.safe_load_all(output) if doc]
        gateway = next(doc for doc in documents
                       if doc['kind'] == 'StatefulSet' and doc['metadata']['name'] == 'openshell')
        pod = gateway['spec']['template']['spec']
        for key in ['runAsUser', 'runAsGroup', 'fsGroup']:
            self.assertIsNone((pod.get('securityContext') or {}).get(key))
        container = next(c for c in pod['containers'] if c['name'] == 'openshell-gateway')
        context = container['securityContext']
        self.assertIsNone(context.get('runAsUser'))
        self.assertTrue(context['runAsNonRoot'])
        self.assertFalse(context['allowPrivilegeEscalation'])
        self.assertIn('ALL', context['capabilities']['drop'])
        self.assertEqual(context['seccompProfile']['type'], 'RuntimeDefault')

    def test_invalid_endpoints(self):
        for url in ['http://llm/v1', 'https://user:secret@llm/v1', 'https://llm/v1?key=x', 'https://llm/v1#x']:
            with self.subTest(url=url), self.assertRaises(subprocess.CalledProcessError):
                self.render(url)

    def exercise(self, scenario, checksum_ok=True):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            base = Path(directory)
            config, work, tls, binaries = [base / x for x in ['config', 'work', 'tls', 'bin']]
            for path in [config, work, tls, binaries]: path.mkdir()
            for name, value in self.data.items(): (config / name).write_text(value)
            for name in ['ca.crt', 'tls.crt', 'tls.key']: (tls / name).write_text('certificate')
            key = base / 'key'; key.write_text('secret-key\n')
            archive = base / 'cli.tar.gz'
            binary = FAKE_CLI.encode()
            with tarfile.open(archive, 'w:gz') as tar:
                member = tarfile.TarInfo('openshell'); member.size = len(binary)
                tar.addfile(member, io.BytesIO(binary))
            settings = json.loads(self.data['settings.json'])
            settings['sandbox']['recreate'] = scenario.startswith('recreate')
            settings['setup']['cliChecksums'][os.uname().machine] = hashlib.sha256(archive.read_bytes()).hexdigest() if checksum_ok else '0' * 64
            (config / 'settings.json').write_text(json.dumps(settings))
            # Compare shell hash with the original Python implementation, including
            # quotes, separator characters, backslashes and non-ASCII strings.
            settings['sandbox']['networkPolicies'] = {'test': {'description': 'é "a,b: c" \\ 😀'}}
            policy = json.loads(self.data['policy.json'])
            policy['network_policies'] = settings['sandbox']['networkPolicies']
            (config / 'settings.json').write_text(json.dumps(settings))
            (config / 'policy.json').write_text(json.dumps(policy))
            initial_policy = json.loads(json.dumps(policy))
            original_settings = json.loads(json.dumps(settings))
            if scenario in ['legacy-network-change', 'v2-network-change', 'v2-network-remove']:
                initial_policy['network_policies'] = {} if scenario == 'legacy-network-change' else {'old': {'endpoints':[]}}
                original_settings['sandbox']['networkPolicies'] = initial_policy['network_policies']
            if scenario == 'v2-network-remove':
                policy['network_policies'] = {}
                settings['sandbox']['networkPolicies'] = {}
                (config / 'policy.json').write_text(json.dumps(policy))
                (config / 'settings.json').write_text(json.dumps(settings))
            static = {'sandbox':{k:v for k,v in settings['sandbox'].items() if k not in ['networkPolicies', 'filesystemPolicy', 'landlock', 'process', 'networkMiddlewares', 'recreate']},
                      'policy':{k:v for k,v in policy.items() if k != 'network_policies'}, 'layoutVersion':2}
            static_hash = hashlib.sha256((json.dumps(static, sort_keys=True, separators=(',', ':')) + '\n').encode()).hexdigest()
            for policy_key in ['filesystemPolicy', 'landlock', 'process', 'networkMiddlewares', 'recreate']:
                original_settings['sandbox'].pop(policy_key, None)
            fingerprint = hashlib.sha256(json.dumps({'sandbox':original_settings['sandbox'], 'policy':initial_policy, 'layoutVersion':1}, sort_keys=True).encode()).hexdigest()
            for name, script in {
                'curl': '#!/bin/sh\nwhile [ "$1" != "-o" ]; do shift; done\ncp "$ARCHIVE" "$2"\n',
                'sleep': '#!/bin/sh\nexit 0\n',
            }.items():
                (binaries / name).write_text(script); (binaries / name).chmod(0o755)
            env = dict(os.environ, CONFIG=str(config), WORK=str(work), TLS=str(tls), KEY_FILE=str(key),
                       XDG_CONFIG_HOME=str(work / 'config'), SCENARIO=scenario, HASH=fingerprint, STATIC_HASH=static_hash, INITIAL_POLICY=json.dumps(initial_policy),
                       ARCHIVE=str(archive), PATH=str(binaries) + ':' + os.environ['PATH'])
            result = subprocess.run(['bash', str(config / 'setup.sh')], env=env, text=True, capture_output=True, timeout=30)
            calls_file = work / 'calls.jsonl'
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
            self.assertNotIn('secret-key', result.stdout + result.stderr + json.dumps(calls))
            self.assertEqual(sum(c['args'][:2] == ['sandbox', 'delete'] for c in calls), int(scenario.startswith('recreate')))
            self.assertTrue(all(not c['credential'] or c['args'][:2] in [['provider','create'], ['provider','update']] for c in calls))
            if scenario in ['fresh', 'existing', 'legacy-network-change', 'v2-network-change',
                            'v2-network-remove', 'stopped', 'policy-unchanged', 'recreate'] and checksum_ok:
                self.assertEqual(result.returncode, 0, result.stderr)
                submitted = json.loads((work / 'submitted-policy.json').read_text())
                self.assertEqual(submitted['network_policies'], policy['network_policies'])
                self.assertIn('/runtime-added', submitted['filesystem_policy']['read_write'])
                sets = [c['args'] for c in calls if c['args'][:2] == ['policy', 'set']]
                self.assertEqual(len(sets), 1)
                self.assertIn('--wait', sets[0])
                self.assertTrue(any(c['args'][:4] == ['policy', 'get', 'opencode', '--rev'] and
                                    c['args'][4] == '2' for c in calls))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((work / 'uploaded.json').read_text()), json.loads(self.data['opencode.json']))
                creates = [c for c in calls if c['args'][:2] == ['sandbox', 'create']]
                self.assertEqual(len(creates), int(scenario in ['fresh', 'recreate']))
                if creates:
                    self.assertIn('openshell-opencode/static-config-hash=' + static_hash, creates[0]['args'])
                    self.assertIn('--detach', creates[0]['args'])
                    self.assertIn('ghcr.io/anomalyco/opencode:1.19.6', creates[0]['args'])
                else:
                    self.assertEqual(json.loads((work / 'provider.json').read_text())['resource_version'], 4)
            else:
                self.assertNotEqual(result.returncode, 0)
                if scenario in ['v2-static-drift', 'drift']:
                    self.assertFalse(any(c['args'][0] in ['profile', 'provider', 'policy'] for c in calls))
                if scenario in ['policy-error', 'policy-timeout', 'policy-superseded', 'global-policy']:
                    self.assertFalse(any(c['args'][:2] == ['sandbox', 'exec'] for c in calls))
                if scenario in ['auth', 'drift', 'profile-error', 'recreate-delete-error'] or not checksum_ok:
                    self.assertFalse(any(c['args'][:2] == ['sandbox','create'] for c in calls))

    def test_recreate_static_drift(self): self.exercise('recreate')
    def test_recreate_delete_failure(self): self.exercise('recreate-delete-error')
    def test_fresh_install(self): self.exercise('fresh')
    def test_existing_preserved_and_legacy_hash_compatible(self): self.exercise('existing')
    def test_legacy_network_change(self): self.exercise('legacy-network-change')
    def test_network_change(self): self.exercise('v2-network-change')
    def test_network_removal(self): self.exercise('v2-network-remove')
    def test_static_change_rejected(self): self.exercise('v2-static-drift')
    def test_policy_rejection(self): self.exercise('policy-error')
    def test_policy_timeout(self): self.exercise('policy-timeout')
    def test_superseded_policy_rejected(self): self.exercise('policy-superseded')
    def test_unchanged_policy_verified(self): self.exercise('policy-unchanged')
    def test_global_policy_rejected(self): self.exercise('global-policy')
    def test_stopped_sandbox(self): self.exercise('stopped')
    def test_drift_rejected(self): self.exercise('drift')
    def test_auth_failure_and_redaction(self): self.exercise('auth')
    def test_profile_error_not_treated_as_absence(self): self.exercise('profile-error')
    def test_runtime_failure(self): self.exercise('runtime-error')
    def test_smoke_error(self): self.exercise('model-error')
    def test_smoke_silent(self): self.exercise('silent')
    def test_checksum_failure(self): self.exercise('fresh', checksum_ok=False)


if __name__ == '__main__':
    unittest.main()
