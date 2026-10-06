"""Exercise the released core using generated configs and local TLS/proxy peers."""
import functools
import http.server
import json
import os
from pathlib import Path
import shlex
import socket
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def wait_port(port, proc):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f'core exited with {proc.returncode}')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.2):
                return
        except OSError:
            time.sleep(.1)
    raise RuntimeError(f'port {port} did not start')


def main():
    processes = []
    with tempfile.TemporaryDirectory(prefix='shoes-live-') as td:
        d = Path(td)
        code = 'set -euo pipefail\nsource ' + shlex.quote(str(ROOT / 'shoes.sh')) + '\n'
        code += 'WORK_DIR=' + shlex.quote(td) + '\ndetect_system\n'
        # Use the same downloader, with a fixed upstream release for reproducible CI.
        code += r'''
curl(){
    local arg
    local -a args=()
    for arg in "$@"; do
        [[ "$arg" != https://api.github.com/repos/cfal/shoes/releases/latest ]] || arg=https://api.github.com/repos/cfal/shoes/releases/tags/v0.3.2
        args+=("$arg")
    done
    command curl "${args[@]}"
}
download_shoes
generate_credentials
write_config "$WORK_DIR/server.yaml" "$WORK_DIR"
validate_config "$CANDIDATE" "$WORK_DIR/server.yaml"
jq -n --arg bin "$CANDIDATE" --arg pub "$PUBLIC_KEY" --arg sid "$SHID" --arg uuid "$UUID" \
  --arg sni "$SNI" --argjson vless "$VLESS_PORT" --argjson anytls "$ANYTLS_PORT" \
  '{bin:$bin,pub:$pub,sid:$sid,uuid:$uuid,sni:$sni,vless:$vless,anytls:$anytls}' > "$WORK_DIR/params.json"
'''
        subprocess.run(['bash', '-c', code], check=True, timeout=300)
        p = json.loads((d / 'params.json').read_text())
        binary = p['bin']
        # Local TLS cover target removes third-party DNS/uptime from Reality tests.
        cover_port = free_port()
        cfg = (d / 'server.yaml').read_text().replace(
            f'dest: "{p["sni"]}:443"', f'dest: "localhost:{cover_port}"')
        (d / 'server.yaml').write_text(cfg)
        (d / 'probe').write_text('shoes-local-proxy-ok\n')
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=td)
        web = http.server.ThreadingHTTPServer(('127.0.0.1', cover_port), handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(d / 'cert.pem', d / 'key.pem')
        web.socket = tls.wrap_socket(web.socket, server_side=True)
        thread = threading.Thread(target=web.serve_forever, daemon=True); thread.start()
        logs = []

        def start(name, config):
            log = (d / (name + '.log')).open('w+')
            logs.append((name, log))
            proc = subprocess.Popen([binary, str(config)], stdout=log, stderr=subprocess.STDOUT)
            processes.append(proc)
            return proc

        try:
            server = start('server', d / 'server.yaml')
            wait_port(p['vless'], server); wait_port(p['anytls'], server)
            for kind in ('anytls', 'vless'):
                socks_port = free_port()
                if kind == 'anytls':
                    protocol = {'type': 'tls', 'verify': False, 'sni_hostname': 'www.bing.com',
                                'protocol': {'type': 'anytls', 'password': p['pub'], 'udp_enabled': True}}
                else:
                    protocol = {'type': 'reality', 'vision': True, 'public_key': p['pub'],
                                'short_id': p['sid'], 'sni_hostname': p['sni'],
                                'protocol': {'type': 'vless', 'user_id': p['uuid'], 'udp_enabled': True}}
                config = [{'address': f'127.0.0.1:{socks_port}', 'protocol': {'type': 'socks'},
                           'rules': [{'masks': '0.0.0.0/0', 'action': 'allow', 'client_chain': {
                               'address': f'127.0.0.1:{p[kind]}', 'protocol': protocol}}]}]
                client_file = d / (kind + '.json')
                client_file.write_text(json.dumps(config))  # JSON is valid YAML.
                subprocess.run([binary, '--dry-run', str(client_file)], check=True, timeout=15)
                client = start(kind, client_file)
                wait_port(socks_port, client)
                response = subprocess.run([
                    'curl', '--fail', '--silent', '--show-error', '--insecure', '--noproxy', '',
                    '--max-time', '15', '--socks5-hostname', f'127.0.0.1:{socks_port}',
                    f'https://127.0.0.1:{cover_port}/probe'], text=True, capture_output=True, timeout=20)
                if response.returncode or response.stdout != 'shoes-local-proxy-ok\n':
                    raise RuntimeError(f'{kind} proxy transfer failed: {response.stderr}')
                print(f'{kind}: released v0.3.2 core, generated server config, HTTPS payload passed', flush=True)
        except Exception:
            for name, log in logs:
                log.flush(); log.seek(0)
                print(f'--- {name} log ---\n{log.read()}', flush=True)
            raise
        finally:
            for proc in reversed(processes):
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill(); proc.wait()
            web.shutdown(); web.server_close()
            for _, log in logs:
                log.close()


if __name__ == '__main__':
    main()
