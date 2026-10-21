#!/usr/bin/env python3
"""Exercise the shell installer in temporary directories with fake OS commands.

Never invokes sudo, systemd, firewall or real users. This is not a VPS test.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
FAKE_COMMAND = r'''
import hashlib, os, pathlib, shutil, subprocess, sys
cmd = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
with (root/'commands.log').open('a') as f: f.write(cmd+' '+' '.join(a)+'\n')
if cmd == 'id':
    if a == ['-u']: print('0')
elif cmd == 'ss': print(os.environ.get('FIXTURE_LISTENERS',''), end='')
elif cmd in ['sleep','chown','userdel']: pass
elif cmd == 'flock':
    if os.environ.get('FIXTURE_LOCKED') == 'yes': sys.exit(1)
elif cmd == 'ufw': print('Status: inactive')
elif cmd == 'sha256sum': print(hashlib.sha256(pathlib.Path(a[0]).read_bytes()).hexdigest()+'  '+a[0])
elif cmd == 'runuser':
    sys.exit(subprocess.run(a[a.index('--')+1:]).returncode)
elif cmd == 'systemctl':
    if a[0] == 'show': print('111')
    if a[0] in ['restart','is-active']:
        new = 'NEW_BINARY' in (root/'opt/yggvion/yggvion').read_text()
        if new and os.environ.get('FIXTURE_FAIL') == a[0]: sys.exit(1)
elif cmd == 'install':
    directory = '-d' in a
    mode = int(a[a.index('-m')+1],8)
    paths=[]; i=0
    while i<len(a):
        if a[i] in ['-m','-o','-g']: i+=2
        elif a[i]=='-d': i+=1
        else: paths.append(pathlib.Path(a[i])); i+=1
    if directory:
        for p in paths: p.mkdir(parents=True,exist_ok=True); p.chmod(mode)
    else: shutil.copyfile(paths[0],paths[1]); paths[1].chmod(mode)
else: raise RuntimeError('Unexpected command '+cmd)
'''
SERVER = r'''
# NEW_BINARY
import json, os, pathlib, sys
a=sys.argv[1:]
if a[0]=='snapshot-db':
    if os.environ.get('FIXTURE_FAIL')=='snapshot': sys.exit(1)
    root=pathlib.Path(os.environ['YGGVION_DATA_DIR'])
    pathlib.Path(a[1]).write_bytes((root/'yggvion.db').read_bytes())
    (root/'safety-created').write_text('yes')
elif a[0]=='migrate':
    root=pathlib.Path(os.environ['YGGVION_DATA_DIR'])
    (root/'yggvion.db').write_text('migrated database')
    if os.environ.get('FIXTURE_FAIL')=='migrate': sys.exit(1)
elif a[0]=='bootstrap':
    root=pathlib.Path(a[a.index('--data-dir')+1])
    (root/'server.json').write_text(json.dumps({'host':a[a.index('--host')+1],'port':int(a[a.index('--port')+1])}))
    print(json.dumps({'code':'synthetic-once','private_ca':'synthetic-ca'}))
else: sys.exit(1)
'''


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='yggvion-installer-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for d in ['etc/systemd/system', 'run/systemd/system', 'opt/yggvion', 'var/lib/yggvion', 'bin']:
            (self.root/d).mkdir(parents=True)
        (self.root/'etc/os-release').write_text('ID=ubuntu\n')
        self.binary = self.root/'opt/yggvion/yggvion'
        self.binary.write_text('#!/bin/sh\n# OLD_BINARY\nexit 0\n'); self.binary.chmod(0o755)
        self.config = self.root/'var/lib/yggvion/server.json'
        self.config.write_text('{"host":"192.0.2.1","port":443}')
        self.unit = self.root/'etc/systemd/system/yggvion.service'
        self.unit.write_text('old service')
        (self.root/'var/lib/yggvion/yggvion.db').write_text('old database')
        self.payload = self.root/'payload'
        self.payload.write_text('#!'+sys.executable+'\n'+SERVER); self.payload.chmod(0o755)
        self.digest = hashlib.sha256(self.payload.read_bytes()).hexdigest()
        script = (ROOT/'deploy/install.sh').read_text()
        script = re.sub(r'/(etc|run|opt|var)/', lambda match: str(self.root)+match.group(0), script)
        self.script = self.root/'install.sh'; self.script.write_text(script)
        for cmd in ['id','ss','systemctl','install','runuser','ufw','sleep','sha256sum','chown','userdel','flock']:
            path=self.root/'bin'/cmd
            path.write_text('#!'+sys.executable+'\n'+FAKE_COMMAND); path.chmod(0o755)

    def run_install(self, action='install', **extra):
        return subprocess.run(['sh',str(self.script),'192.0.2.1','444',str(self.payload),self.digest,action],
            env={**os.environ,'PATH':str(self.root/'bin')+':/usr/bin:/bin', 'FIXTURE_ROOT':str(self.root), **extra},
            capture_output=True,text=True,timeout=20)

    def assert_old(self):
        self.assertIn('OLD_BINARY',self.binary.read_text())
        self.assertEqual(self.unit.read_text(),'old service')
        self.assertEqual(self.config.read_text(),'{"host":"192.0.2.1","port":443}')
        self.assertEqual((self.root/'var/lib/yggvion/yggvion.db').read_text(),'old database')

    def test_update_keeps_safety_copy_and_installs_hardened_service(self):
        result=self.run_install(FIXTURE_LISTENERS='LISTEN users:(("yggvion",pid=111,fd=3))\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('NEW_BINARY',self.binary.read_text())
        self.assertIn('ProtectSystem=strict',self.unit.read_text())
        self.assertIn('User=yggvion',self.unit.read_text())
        self.assertTrue((self.root/'var/lib/yggvion/safety-created').exists())
        self.assertIn('444',self.config.read_text())

    def test_fresh_install_creates_configuration(self):
        for file in [self.binary, self.config, self.unit]: file.unlink()
        result=self.run_install()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('NEW_BINARY',self.binary.read_text())
        self.assertIn('444',self.config.read_text())
        self.assertIn('CapabilityBoundingSet=CAP_NET_BIND_SERVICE',self.unit.read_text())

    def test_restart_and_late_start_failure_restore_binary_unit_and_config(self):
        for failure in ['restart','is-active']:
            with self.subTest(failure=failure):
                result=self.run_install(FIXTURE_FAIL=failure)
                self.assertNotEqual(result.returncode,0)
                self.assertTrue((self.root/'var/lib/yggvion/safety-created').exists())
                self.assertIn('Восстановлены предыдущий бинарник',result.stderr)
                self.assert_old()

    def test_occupied_port_and_failed_safety_copy_do_not_modify_installation(self):
        for extra in [dict(FIXTURE_LISTENERS='LISTEN users:(("other",pid=222,fd=3))\n'),dict(FIXTURE_FAIL='snapshot')]:
            with self.subTest(extra=extra):
                self.assertNotEqual(self.run_install(**extra).returncode,0)
                self.assert_old()

    def test_corrupt_payload_is_rejected_before_changes(self):
        self.digest='0'*64
        self.assertNotEqual(self.run_install().returncode,0)
        self.assert_old()

    def test_concurrent_maintenance_is_rejected_before_changes(self):
        result=self.run_install(FIXTURE_LOCKED='yes')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('уже выполняется',result.stderr)
        self.assert_old()

    def test_update_migrates_without_pairing_or_changing_identity(self):
        result=self.run_install(action='update')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('synthetic-once',result.stdout)
        self.assertEqual((self.root/'var/lib/yggvion/yggvion.db').read_text(),'migrated database')
        self.assertEqual(self.config.read_text(),'\x7b"host":"192.0.2.1","port":443}')
        self.assertFalse((self.root/'var/lib/yggvion/upgrade.previous.sqlite').exists())

    def test_failed_migration_or_restart_restores_database_too(self):
        for failure in ['migrate','restart','is-active']:
            with self.subTest(failure=failure):
                result=self.run_install(action='update',FIXTURE_FAIL=failure)
                self.assertNotEqual(result.returncode,0)
                self.assert_old()

    def run_uninstall(self, mode, confirmation=''):
        script=(ROOT/'deploy/uninstall.sh').read_text()
        script=re.sub(r'/(etc|run|opt|var)/', lambda m: str(self.root)+m.group(0), script)
        path=self.root/'uninstall.sh';path.write_text(script)
        return subprocess.run(['sh',str(path),mode,confirmation],env={**os.environ,'PATH':str(self.root/'bin')+':/usr/bin:/bin','FIXTURE_ROOT':str(self.root)},capture_output=True,text=True,timeout=20)

    def test_uninstall_requires_confirmation_and_preserves_data_by_default(self):
        self.assertEqual(self.run_install().returncode,0)
        self.assertNotEqual(self.run_uninstall('purge').returncode,0)
        self.assertTrue(self.binary.exists())
        result=self.run_uninstall('keep-data')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.binary.exists())
        self.assertFalse(self.unit.exists())
        self.assertTrue(self.config.exists())

    def test_full_uninstall_and_symlink_protection(self):
        self.assertEqual(self.run_install().returncode,0)
        result=self.run_uninstall('purge','DELETE-YGGVION')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((self.root/'var/lib/yggvion').exists())
        self.assertFalse(self.binary.parent.exists())
        self.binary.parent.symlink_to(self.root/'bin')
        self.assertNotEqual(self.run_uninstall('purge','DELETE-YGGVION').returncode,0)
        self.assertTrue((self.root/'bin').exists())


if __name__=='__main__': unittest.main()
