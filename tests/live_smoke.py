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
from urllib.parse import unquote, urlsplit

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


def read_exact(sock, size):
    data = b''
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError('unexpected SOCKS EOF')
        data += chunk
    return data


def test_udp_over_tcp(socks_port):
    # Native UDP on the local SOCKS side is carried over the SS TCP connection.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as target:
        target.bind(('127.0.0.1', 0)); target.settimeout(5)
        target_port = target.getsockname()[1]

        def echo():
            packet, peer = target.recvfrom(4096)
            target.sendto(packet, peer)

        thread = threading.Thread(target=echo, daemon=True); thread.start()
        with socket.create_connection(('127.0.0.1', socks_port), timeout=5) as control:
            control.sendall(b'\x05\x01\x00')
            assert read_exact(control, 2) == b'\x05\x00'
            control.sendall(b'\x05\x03\x00\x01' + b'\x00' * 6)
            header = read_exact(control, 4)
            assert header[:3] == b'\x05\x00\x00', header
            if header[3] == 1:
                host = socket.inet_ntop(socket.AF_INET, read_exact(control, 4))
                family = socket.AF_INET
                if host == '0.0.0.0':
                    host = '127.0.0.1'
            elif header[3] == 4:
                host = socket.inet_ntop(socket.AF_INET6, read_exact(control, 16))
                family = socket.AF_INET6
                if host == '::':
                    host = '::1'
            else:
                raise RuntimeError(f'unexpected SOCKS bind address type: {header[3]}')
            port = int.from_bytes(read_exact(control, 2), 'big')
            payload = b'shoes-ss2022-uot-ok'
            request = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + target_port.to_bytes(2, 'big') + payload
            with socket.socket(family, socket.SOCK_DGRAM) as udp:
                udp.settimeout(5)
                udp.sendto(request, (host, port))
                response, _ = udp.recvfrom(4096)
                assert response[:4] == b'\x00\x00\x00\x01', response
                assert response[10:] == payload, response
        thread.join(timeout=5)


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
HOST_IP=127.0.0.1; COUNTRY=TEST
write_ss2022_link "$WORK_DIR/ss2022.txt"
validate_config "$CANDIDATE" "$WORK_DIR/server.yaml"
jq -n --arg bin "$CANDIDATE" --arg pub "$PUBLIC_KEY" --arg sid "$SHID" --arg uuid "$UUID" \
  --arg sni "$SNI" --argjson vless "$VLESS_PORT" --argjson anytls "$ANYTLS_PORT" --argjson ss2022 "$SS2022_PORT" \
  '{bin:$bin,pub:$pub,sid:$sid,uuid:$uuid,sni:$sni,vless:$vless,anytls:$anytls,ss2022:$ss2022}' > "$WORK_DIR/params.json"
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
            configs = config if isinstance(config, list) else [config]
            proc = subprocess.Popen([binary, *map(str, configs)], stdout=log, stderr=subprocess.STDOUT)
            processes.append(proc)
            return proc

        try:
            server = start('server', d / 'server.yaml')
            for kind in ('anytls', 'vless', 'ss2022'):
                wait_port(p[kind], server)
                socks_port = free_port()
                if kind == 'anytls':
                    protocol = {'type': 'tls', 'verify': False, 'sni_hostname': 'www.bing.com',
                                'protocol': {'type': 'anytls', 'password': p['pub'], 'udp_enabled': True}}
                elif kind == 'vless':
                    protocol = {'type': 'reality', 'vision': True, 'public_key': p['pub'],
                                'short_id': p['sid'], 'sni_hostname': p['sni'],
                                'protocol': {'type': 'vless', 'user_id': p['uuid'], 'udp_enabled': True}}
                else:
                    # Build the client from the actual exported SIP002 link.
                    link = urlsplit((d / 'ss2022.txt').read_text().strip())
                    assert link.port == p[kind]
                    protocol = {'type': 'shadowsocks', 'cipher': unquote(link.username),
                                'password': unquote(link.password)}
                config = [{'address': f'127.0.0.1:{socks_port}', 'protocol': {'type': 'socks'},
                           'rules': [{'masks': '0.0.0.0/0', 'action': 'allow', 'client_chain': {
                               'address': f'127.0.0.1:{p[kind]}', 'protocol': protocol}}]}]
                client_file = d / (kind + '-client.json')
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
                if kind == 'ss2022':
                    test_udp_over_tcp(socks_port)
                    print('ss2022: UDP over TCP payload passed', flush=True)
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
