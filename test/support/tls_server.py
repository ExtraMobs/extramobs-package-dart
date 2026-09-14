"""Loopback TDS/TLS fixture. No database, real credentials or SQL execution.

Requires Python 3 and the OpenSSL command-line tool. Generates disposable
self-signed certificates and reports their paths and listening ports as JSON.
"""
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading


def exact(read, size):
    data = bytearray()
    while len(data) < size:
        block = read(size - len(data))
        if not block:
            raise EOFError()
        data.extend(block)
    return bytes(data)


def packet(read):
    body = bytearray()
    while True:
        header = exact(read, 8)
        size = int.from_bytes(header[2:4], 'big')
        if size < 8:
            raise ValueError('Invalid TDS length')
        body.extend(exact(read, size - 8))
        if header[1] & 1:
            return header[0], bytes(body)


def reply(body):
    return struct.pack('>BBHHBB', 4, 1, len(body) + 8, 0, 1, 0) + body


class Transport:
    def __init__(self, sock, context, framed):
        self.sock = sock
        self.incoming, self.outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        self.tls = context.wrap_bio(self.incoming, self.outgoing, server_side=True)
        while True:
            try:
                self.tls.do_handshake()
                self.flush(framed)
                break
            except ssl.SSLWantReadError:
                self.flush(framed)
                data = packet(sock.recv)[1] if framed else sock.recv(65536)
                if not data:
                    raise EOFError()
                self.incoming.write(data)

    def flush(self, framed=False):
        data = self.outgoing.read()
        if data:
            self.sock.sendall(reply(data) if framed else data)

    def read(self, size):
        while True:
            try:
                return self.tls.read(size)
            except ssl.SSLWantReadError:
                self.flush()
                data = self.sock.recv(65536)
                if not data:
                    raise EOFError()
                self.incoming.write(data)

    def write(self, data):
        self.tls.write(data)
        self.flush()


DONE = b'\xfd' + bytes(12)
# LOGINACK: SQL interface, TDS 7.4, empty program name, server version 15.0.
LOGIN_ACK = b'\xad\x0a\x00\x01\x74\x00\x00\x04\x00\x0f\x00\x00\x00' + DONE


def serve(sock, mode, context):
    with sock:
        sock.settimeout(10)
        try:
            read, write = sock.recv, sock.sendall
            if mode == 'strict':
                transport = Transport(sock, context, False)
                read, write = transport.read, transport.write
            kind, _ = packet(read)
            if kind != 0x12:
                raise ValueError('Expected PRELOGIN')
            encryption = {'plain': 2, 'login': 0, 'full': 1, 'strict': 1}[mode]
            # Include MARS=off so FreeTDS retains modern TDS/DONE lengths.
            write(reply(bytes([1, 0, 11, 0, 1, 4, 0, 12, 0, 1, 255, encryption, 0])))
            if mode in ('login', 'full'):
                transport = Transport(sock, context, True)
                read, write = transport.read, transport.write
            kind, _ = packet(read)
            if kind != 0x10:
                raise ValueError('Expected LOGIN7')
            if mode == 'login':
                read, write = sock.recv, sock.sendall
            write(reply(LOGIN_ACK))
            while True:
                packet(read)
                write(reply(DONE))
        except (EOFError, OSError, ssl.SSLError):
            pass  # Expected when clients reject trust or close their session.


def listen(server, mode, context):
    while True:
        sock, _ = server.accept()
        threading.Thread(target=serve, args=(sock, mode, context), daemon=True).start()


with tempfile.TemporaryDirectory(prefix='mssql-tls-server-') as directory:
    root = Path(directory)
    openssl = os.environ.get('MSSQL_TEST_OPENSSL', 'openssl')
    for name in ('server', 'other'):
        subprocess.run([
            openssl, 'req', '-config', os.devnull, '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
            '-keyout', str(root / (name + '.key')), '-out', str(root / (name + '.pem')),
            '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ports = {}
    servers = []
    for mode in ('plain', 'login', 'full', 'strict'):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        if mode != 'strict':
            context.maximum_version = ssl.TLSVersion.TLSv1_2
        context.set_alpn_protocols(['tds/8.0'])
        context.load_cert_chain(str(root / 'server.pem'), str(root / 'server.key'))
        server = socket.socket()
        server.bind(('127.0.0.1', 0))
        server.listen()
        servers.append(server)
        ports[mode] = server.getsockname()[1]
        threading.Thread(target=listen, args=(server, mode, context), daemon=True).start()
    print(json.dumps({'ports': ports, 'pem': str(root / 'server.pem'),
                      'wrongPem': str(root / 'other.pem')}), flush=True)
    sys.stdin.readline()
