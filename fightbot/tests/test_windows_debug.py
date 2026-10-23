"""Native BG3SE protocol behavior from pinned LuaDebugMessages.cpp, not the permissive Linux fake."""
import socket
import struct
import threading
import unittest
from unittest import mock

from bg3ai.luadebug import LuaDebugClient, _fields, _first, _uint_field, _bytes_field


class NativeProtocolTest(unittest.TestCase):
    def test_unmatched_connect_reply_reconnect_reset_and_sequenced_settings(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        listener.settimeout(3)
        port = listener.getsockname()[1]
        received, errors = [], []

        def exact(s, n):
            out = b""
            while len(out) < n:
                b = s.recv(n - len(out))
                if not b:
                    raise EOFError("unexpected disconnect")
                out += b
            return out

        def packet(s):
            size = struct.unpack("<I", exact(s, 4))[0]
            return _fields(exact(s, size - 4))

        def send(s, body):
            s.sendall(struct.pack("<I", len(body) + 4) + body)

        def backend():
            try:
                for requested in (4, 5):
                    with listener.accept()[0] as s:
                        s.settimeout(3)
                        connect = packet(s)
                        self.assertEqual(_first(connect, 1), 1)
                        self.assertEqual(_first(_fields(_first(connect, 3)), 1), requested)
                        # Native SendConnectResponse does not set reply_seq_no.
                        send(s, _uint_field(1, 1) + _bytes_field(3, _uint_field(1, 5)))
                        if requested == 4:
                            continue
                        settings = packet(s)
                        received.append(settings)
                        self.assertEqual(_first(settings, 1), 2)
                        self.assertIn(4, settings)
                        send(s, _uint_field(1, 2) + _uint_field(2, 2) + _bytes_field(9, b""))
                        evaluate = packet(s)
                        self.assertEqual(_first(evaluate, 1), 3)
                        self.assertIn(7, evaluate)
                        evaluation = _fields(_first(evaluate, 7))
                        self.assertEqual(_first(evaluation, 3), (1 << 64) - 1)
                        value = _uint_field(1, 4) + _bytes_field(5, b"33")
                        response = _bytes_field(1, value)
                        send(s, _uint_field(1, 3) + _uint_field(2, 3) + _bytes_field(5, response))
            except BaseException as e:
                errors.append(e)
            finally:
                listener.close()

        thread = threading.Thread(target=backend, daemon=True)
        thread.start()
        try:
            with LuaDebugClient(port=port, protocol_version=4, connect_timeout=2) as client:
                self.assertEqual(client.server_version, 5)
                self.assertEqual(client.evaluate("return Ext.Utils.Version()"), "33")
        finally:
            listener.close()
            thread.join(timeout=4)
        self.assertFalse(thread.is_alive())
        self.assertFalse(errors, repr(errors))
        self.assertEqual(len(received), 1)

    def test_platform_default_and_explicit_override(self):
        for platform, expected in (("win32", 5), ("linux", 4), ("darwin", 4)):
            with self.subTest(platform=platform), mock.patch("bg3ai.luadebug.sys.platform", platform):
                self.assertEqual(LuaDebugClient().requested_version, expected)
                self.assertEqual(LuaDebugClient(protocol_version=4).requested_version, 4)
                self.assertEqual(LuaDebugClient(protocol_version=5).requested_version, 5)

    def test_windows_default_connects_once_without_version_mismatch(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        listener.settimeout(3)
        port = listener.getsockname()[1]
        requested, errors = [], []

        def exact(s, n):
            out = b""
            while len(out) < n:
                b = s.recv(n - len(out))
                if not b:
                    raise EOFError("unexpected disconnect")
                out += b
            return out

        def packet(s):
            size = struct.unpack("<I", exact(s, 4))[0]
            return _fields(exact(s, size - 4))

        def send(s, body):
            s.sendall(struct.pack("<I", len(body) + 4) + body)

        def backend():
            try:
                with listener.accept()[0] as s:
                    s.settimeout(3)
                    connect = packet(s)
                    requested.append(_first(_fields(_first(connect, 3)), 1))
                    self.assertEqual(requested, [5])
                    self.assertEqual(_first(connect, 1), 1)
                    send(s, _uint_field(1, 1) + _bytes_field(3, _uint_field(1, 5)))
                    settings = packet(s)
                    self.assertEqual(_first(settings, 1), 2)
                    self.assertIn(4, settings)
                    # The next packet on this same connection must be evaluation.
                    evaluate = packet(s)
                    self.assertEqual(_first(evaluate, 1), 3)
                    self.assertIn(7, evaluate)
                    value = _uint_field(1, 4) + _bytes_field(5, b"33")
                    send(s, _uint_field(1, 2) + _uint_field(2, 3) + _bytes_field(5, _bytes_field(1, value)))
            except BaseException as exc:
                errors.append(exc)
            finally:
                listener.close()

        thread = threading.Thread(target=backend, daemon=True)
        thread.start()
        try:
            with mock.patch("bg3ai.luadebug.sys.platform", "win32"):
                with LuaDebugClient(port=port, connect_timeout=2) as client:
                    self.assertEqual(client.server_version, 5)
                    self.assertEqual(client.evaluate("return Ext.Utils.Version()"), "33")
        finally:
            listener.close()
            thread.join(timeout=4)
        self.assertFalse(thread.is_alive())
        self.assertFalse(errors, repr(errors))
        self.assertEqual(requested, [5])


if __name__ == "__main__":
    unittest.main()
