"""Run isolated regression tests; no host service or installed binary is modified."""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
FAKE_CORE = '''#!/bin/sh
case "$1" in
  --version) echo 'shoes 0.3.2';;
  generate-reality-keypair)
    echo 'REALITY private key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    echo 'REALITY public key: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';;
  --dry-run) [ "${FAIL_VALIDATION:-0}" != 1 ];;
  *) exit 1;;
esac
'''


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        self.conf = self.d / 'etc/shoes'
        for sub in ('bin', 'etc', 'units', 'init', 'state'):
            (self.d / sub).mkdir()
        self.core = self.d / 'fixture-core'
        self.core.write_text(FAKE_CORE)
        self.core.chmod(0o755)
        self.bin = self.d / 'bin/shoes'
        values = {
            'SHOES_BIN': self.bin, 'SHOES_CONF_DIR': self.conf,
            'SHOES_CONF_FILE': self.conf / 'config.yaml',
            'SHOES_LINK_FILE': self.conf / 'config.txt',
            'SYSTEMD_FILE': self.d / 'units/shoes.service',
            'OPENRC_FILE': self.d / 'init/shoes', 'LOG_FILE': self.d / 'log',
            'LOCK_FILE': self.d / 'lock', 'STATE': self.d / 'state',
            'FIXTURE_CORE': self.core, 'SERVICE_MANAGER': 'systemd', 'OS_ID': 'debian',
        }
        self.prefix = 'set -o pipefail\nsource ' + shlex.quote(str(ROOT / 'shoes.sh')) + '\n'
        self.prefix += '\n'.join(k + '=' + shlex.quote(str(v)) for k, v in values.items()) + '\n'
        self.mocks = r'''
ensure_dependencies(){ :; }
systemctl(){ printf '%s\n' "$*" >> "$STATE/systemctl"; }
rc-update(){ printf '%s\n' "$*" >> "$STATE/rc-update"; }
service_action(){
    printf '%s\n' "$1" >> "$STATE/actions"
    [ "${FAIL_START:-0}" != 1 ] || return 1
    case "$1" in start|restart) touch "$STATE/running";; stop) rm -f "$STATE/running";; esac
}
check_running(){ test -f "$STATE/running"; }
wait_running(){ check_running; }
show_recent_logs(){ echo 'mock startup failure details'; }
'''
        self.install_mocks = r'''
download_shoes(){
    echo download >> "$STATE/downloads"
    RELEASE_TAG=v0.3.2
    CANDIDATE="$WORK_DIR/shoes"
    cp "$FIXTURE_CORE" "$CANDIDATE" && chmod 755 "$CANDIDATE"
}
get_public_ip(){ HOST_IP=192.0.2.10; COUNTRY=ZZ; }
choose_port(){ if [ -z "${1:-}" ]; then echo 40001; else echo 40002; fi; }
'''

    def run_sh(self, body, install=False, stdin='', timeout=10):
        return subprocess.run(['bash', '-c', self.prefix + self.mocks +
                               (self.install_mocks if install else '') + body],
                              input=stdin, text=True, capture_output=True, timeout=timeout)

    def installed(self):
        p = self.run_sh('install_shoes', install=True)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        return p

    def test_install_generates_private_config_and_complete_anytls_link(self):
        self.installed()
        self.assertEqual((self.conf.stat().st_mode & 0o777), 0o700)
        for name in ('config.yaml', 'config.txt', 'key.pem', 'cert.pem'):
            self.assertEqual((self.conf / name).stat().st_mode & 0o777, 0o600)
        links = (self.conf / 'config.txt').read_text().splitlines()
        link = urlsplit(links[1]); query = parse_qs(link.query)
        self.assertEqual(link.hostname, '192.0.2.10')
        self.assertEqual(query['insecure'], ['1'])
        self.assertEqual(query['headerType'], ['none'])
        self.assertNotIn('allowInsecure', query)
        self.assertIn('password: "' + link.username + '"', (self.conf / 'config.yaml').read_text())
        self.assertEqual(list((self.d / 'bin').glob('.shoes-stage.*')), [])

    def test_reinstall_preserves_config_and_repairs_old_link(self):
        self.installed()
        before = {n: (self.conf / n).read_bytes() for n in ('config.yaml', 'key.pem', 'cert.pem')}
        link = self.conf / 'config.txt'
        link.write_text(link.read_text().replace('insecure=1', 'allowInsecure=1'))
        p = self.run_sh('install_shoes', install=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(before, {n: (self.conf / n).read_bytes() for n in before})
        self.assertNotIn('allowInsecure', link.read_text())
        self.assertEqual((self.d / 'state/downloads').read_text().splitlines(), ['download'])

    def test_start_failure_is_not_reported_as_success(self):
        p = self.run_sh('FAIL_START=1; install_shoes', install=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn('Shoes 安装完成', p.stdout)
        self.assertIn('mock startup failure details', p.stderr)

    def test_invalid_config_does_not_install_binary(self):
        p = self.run_sh('export FAIL_VALIDATION=1; install_shoes', install=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(self.bin.exists())
        self.assertFalse((self.conf / 'config.yaml').exists())
        self.assertEqual(list((self.d / 'bin').glob('.shoes-stage.*')), [])

    def test_update_preserves_credentials_and_restarts_running_service(self):
        self.installed()
        before = {p.name: p.read_bytes() for p in self.conf.iterdir()}
        p = self.run_sh('update_shoes', install=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.conf.iterdir()})
        self.assertEqual((self.d / 'state/actions').read_text().splitlines(), ['start', 'restart'])

    def test_update_keeps_stopped_service_stopped(self):
        self.installed()
        (self.d / 'state/running').unlink()
        p = self.run_sh('update_shoes', install=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse((self.d / 'state/running').exists())
        self.assertEqual((self.d / 'state/actions').read_text().splitlines(), ['start'])

    def test_incompatible_update_keeps_old_binary(self):
        self.installed()
        self.bin.write_text(FAKE_CORE + '# old version\n')
        old = self.bin.read_bytes()
        p = self.run_sh('export FAIL_VALIDATION=1; update_shoes', install=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(old, self.bin.read_bytes())
        self.assertEqual((self.d / 'state/actions').read_text().splitlines(), ['start'])

    def test_update_restart_failure_is_reported(self):
        self.installed()
        p = self.run_sh('FAIL_START=1; update_shoes', install=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn('内核已更新到', p.stdout)

    def test_openrc_service_has_validation_and_private_logs(self):
        p = self.run_sh('SERVICE_MANAGER=openrc; OS_ID=alpine; install_shoes', install=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        service = (self.d / 'init/shoes').read_text()
        self.assertIn('command_background="yes"', service)
        self.assertIn('--dry-run', service)
        self.assertIn('checkpath -f -m 0600', service)
        self.assertEqual((self.d / 'state/rc-update').read_text().strip(), 'add shoes default')
        syntax = subprocess.run(['sh', '-n', str(self.d / 'init/shoes')], capture_output=True)
        self.assertEqual(syntax.returncode, 0)

    def test_eof_exits_menu(self):
        p = self.run_sh('require_root(){ :; }; detect_system(){ :; }; main', timeout=2)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout.count('=== Shoes 管理工具 ==='), 1)

    def test_empty_or_invalid_ip_aborts_without_installing(self):
        for response in ('', '999.1.1.1\n', 'not-an-ip\n'):
            p = self.run_sh('curl(){ return 1; }; get_public_ip', stdin=response)
            self.assertNotEqual(p.returncode, 0)
        p = self.run_sh('curl(){ return 1; }; get_public_ip; printf "ip=%s country=%s" "$HOST_IP" "$COUNTRY"', stdin='192.0.2.20\n')
        self.assertEqual(p.returncode, 0)
        self.assertIn('ip=192.0.2.20 country=Shoes', p.stdout)

    def test_port_selection_skips_used_and_reserved_ports(self):
        p = self.run_sh(r'''
shuf(){ local n=0; [ ! -f "$STATE/port" ] || read -r n < "$STATE/port"; n=$((n+1)); echo "$n" > "$STATE/port"; echo $((40000+n)); }
ss(){ if [[ "$*" == *40002* ]]; then echo 'listener'; fi; }
choose_port 40001
''')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), '40003')

    def test_port_inspection_failure_aborts(self):
        p = self.run_sh('shuf(){ echo 40001; }; ss(){ return 1; }; choose_port')
        self.assertNotEqual(p.returncode, 0)

    def test_uninstall_cancel_and_failed_stop_keep_installation(self):
        self.installed()
        p = self.run_sh('uninstall_shoes', stdin='n\n')
        self.assertEqual(p.returncode, 0)
        self.assertTrue(self.bin.exists())
        p = self.run_sh('FAIL_START=1; uninstall_shoes', stdin='y\n')
        self.assertNotEqual(p.returncode, 0)
        self.assertTrue(self.bin.exists())
        self.assertTrue((self.conf / 'config.yaml').exists())

    def test_supported_os_detection(self):
        for distro, manager in [('debian', 'systemd'), ('ubuntu', 'systemd'), ('alpine', 'openrc')]:
            path = self.d / 'os-release'; path.write_text(f'ID={distro}\n')
            p = self.run_sh('OS_RELEASE_FILE=' + shlex.quote(str(path)) + '; detect_system && echo "$SERVICE_MANAGER"')
            self.assertEqual(p.returncode, 0)
            self.assertEqual(p.stdout.strip(), manager)

    def prepare_download(self, gnu=None, musl=None, corrupt_digest=False):
        assets = []
        for flavor, core in [('gnu', gnu), ('musl', musl)]:
            path = self.d / ('shoes-x86_64-unknown-linux-' + flavor + '.tar.gz')
            if core is None:
                path.write_bytes(b'corrupt archive')
            else:
                data = core.encode()
                with tarfile.open(path, 'w:gz') as archive:
                    entry = tarfile.TarInfo('shoes'); entry.size = len(data); entry.mode = 0o755
                    archive.addfile(entry, io.BytesIO(data))
            assets.append({'name': path.name,
                           'browser_download_url': 'https://github.com/cfal/shoes/releases/download/v0.3.2/' + path.name,
                           'digest': 'sha256:' + ('0' * 64 if corrupt_digest else hashlib.sha256(path.read_bytes()).hexdigest())})
        (self.d / 'release.json').write_text(json.dumps({'tag_name': 'v0.3.2', 'assets': assets}))
        return 'DOWNLOAD_FIXTURES=' + shlex.quote(str(self.d)) + r'''
check_arch(){ ARCH=x86_64; }
fetch_file(){ local name="${1##*/}"; [[ "$name" != latest ]] || name=release.json; cp "$DOWNLOAD_FIXTURES/$name" "$2"; }
begin_operation && download_shoes
'''

    def test_corrupt_archives_do_not_report_success_or_replace_old_binary(self):
        self.bin.write_text(FAKE_CORE); self.bin.chmod(0o755)
        p = self.run_sh(self.prepare_download())
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.bin.read_text(), FAKE_CORE)
        self.assertNotIn('运行检查通过', p.stdout)

    def test_unusable_gnu_binary_falls_back_to_musl(self):
        p = self.run_sh(self.prepare_download('#!/bin/sh\nexit 1\n', FAKE_CORE))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('MUSL 内核运行检查通过', p.stdout)
        self.assertFalse(self.bin.exists())

    def test_checksum_mismatch_is_rejected(self):
        p = self.run_sh(self.prepare_download(FAKE_CORE, FAKE_CORE, corrupt_digest=True))
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('下载校验失败', p.stderr)

    def test_alpine_never_attempts_gnu(self):
        p = self.run_sh('OS_ID=alpine\n' + self.prepare_download(FAKE_CORE, FAKE_CORE))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('GNU', p.stdout)


class DomainTests(unittest.TestCase):
    def run_case(self, source, initial='old.example,fqdn\n', failed=False):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td); output = d / 'new/sub/domainlist.csv'
            if initial is not None:
                output.parent.mkdir(parents=True); output.write_text(initial)
            (d / 'source').write_text(source)
            code = 'OUT=' + shlex.quote(str(output)) + '; export OUT\n'
            if failed:
                code += 'curl(){ return 22; }; export -f curl\n'
            else:
                code += 'FIXTURE=' + shlex.quote(str(d / 'source')) + '; export FIXTURE\n'
                code += 'curl(){ while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then cp "$FIXTURE" "$2"; return; fi; shift; done; }; export -f curl\n'
            code += 'bash ' + shlex.quote(str(ROOT / 'domainlist.sh'))
            p = subprocess.run(['bash', '-c', code], capture_output=True, text=True, timeout=5)
            data = output.read_text() if output.exists() else None
            mode = output.stat().st_mode & 0o777 if output.exists() else None
            self.assertEqual(list(d.rglob('.domainlist.*')), [])
            return p, data, mode

    def test_normal_and_supported_wildcard_rules_create_parent_and_deduplicate(self):
        p, data, mode = self.run_case('DOMAIN,Example.com\n+.netflix.com\nDOMAIN-WILDCARD,*.openai.com\nDOMAIN-WILDCARD,google.*\nDOMAIN,Example.com\n', initial=None)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(data.splitlines(), ['.openai.com,suffix', 'example.com,fqdn', 'google.,prefix', 'netflix.com,suffix'])
        self.assertEqual(mode, 0o644)

    def test_empty_result_keeps_old_rules(self):
        p, data, _ = self.run_case('# only comments\n')
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(data, 'old.example,fqdn\n')

    def test_download_failure_keeps_old_rules(self):
        p, data, _ = self.run_case('', failed=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(data, 'old.example,fqdn\n')

    def test_unsupported_wildcard_or_invalid_domain_keeps_old_rules(self):
        for source in ('DOMAIN-WILDCARD,foo*bar.example\n', 'DOMAIN-SUFFIX,\n', 'DOMAIN,a..com\n'):
            p, data, _ = self.run_case(source)
            self.assertNotEqual(p.returncode, 0)
            self.assertEqual(data, 'old.example,fqdn\n')


if __name__ == '__main__':
    unittest.main()
