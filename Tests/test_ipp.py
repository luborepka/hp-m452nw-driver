#!/usr/bin/env python3
"""Exercise the compiled transport without sending paper to a real printer."""
import http.server
import pathlib
import struct
import subprocess
import tempfile
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/hp-open-print-tests"


def attr(tag, name, value):
    name = name.encode()
    if isinstance(value, str):
        value = value.encode()
    return bytes([tag]) + struct.pack(">H", len(name)) + name + struct.pack(">H", len(value)) + value


def integer(value):
    return struct.pack(">i", value)


def parse(data):
    offset = 8
    attributes = []
    group = None
    while offset < len(data):
        tag = data[offset]
        offset += 1
        if tag == 3:
            return attributes, data[offset:]
        if tag < 0x10:
            group = tag
            continue
        length = struct.unpack_from(">H", data, offset)[0]
        offset += 2
        name = data[offset:offset + length].decode()
        offset += length
        length = struct.unpack_from(">H", data, offset)[0]
        offset += 2
        value = data[offset:offset + length]
        offset += length
        attributes.append((group, tag, name, value))
    raise AssertionError("Missing end-of-attributes")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        data = self.rfile.read(length)
        operation = struct.unpack_from(">H", data, 2)[0]
        self.server.requests.append((operation, *parse(data)))
        status = self.server.error if operation == 2 else 0
        response = data[:2] + struct.pack(">H", status) + data[4:8]
        response += b"\x01" + attr(0x47, "attributes-charset", "utf-8") + attr(0x48, "attributes-natural-language", "en")
        if status:
            response += attr(0x41, "status-message", "Rejected by test printer")
        elif operation == 11:  # Get-Printer-Attributes
            response += b"\x04" + attr(0x41, "printer-make-and-model", "HP Color LaserJet M452nw")
            response += attr(0x23, "printer-state", integer(3)) + attr(0x22, "printer-is-accepting-jobs", b"\x01")
            response += attr(0x44, "printer-state-reasons", "none")
            response += attr(0x49, "document-format-supported", "application/pdf")
            response += attr(0x44, "media-source-supported", "tray-1")
            response += attr(0x30, "printer-input-tray", "name=tray-1;level=%d;" % self.server.tray_level)
        elif operation == 2 and not self.server.omit_id:  # Print-Job
            response += b"\x02" + attr(0x21, "job-id", integer(123))
        elif operation == 9:  # Get-Job-Attributes
            response += b"\x02" + attr(0x23, "job-state", integer(self.server.job_state))
            response += attr(0x44, "job-state-reasons", "job-completed-successfully")
        response += b"\x03"
        self.send_response(200)
        self.send_header("Content-Type", "application/ipp")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


class TransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="hp-open-print-ipp-")
        cls.pdf = pathlib.Path(cls.temp.name) / "test.pdf"
        subprocess.run([str(BINARY), "--make-test", "--output", str(cls.pdf)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.requests = []
        self.server.error = 0
        self.server.omit_id = False
        self.server.job_state = 9
        self.server.tray_level = 0
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.uri = f"ipp://127.0.0.1:{self.server.server_port}/ipp/print"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def cli(self, *args):
        return subprocess.run([str(BINARY), *args, "--uri", self.uri], capture_output=True, text=True, timeout=30)

    def test_probe(self):
        result = self.cli("--probe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PDF: true", result.stdout)
        request = self.server.requests[0]
        self.assertEqual(request[0], 11)
        self.assertNotIn(b"all", [item[3] for item in request[1]])

    def test_pdf_and_back_tray_attributes(self):
        result = self.cli("--submit", "--input", str(self.pdf), "--tray", "tray-1", "--color", "monochrome")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Job ID: 123", result.stdout)
        prints = [item for item in self.server.requests if item[0] == 2]
        self.assertEqual(len(prints), 1)
        _, attrs, document = prints[0]
        self.assertTrue(document.startswith(b"%PDF-"))
        self.assertIn((1, 0x49, "document-format", b"application/pdf"), attrs)
        self.assertIn((1, 0x22, "ipp-attribute-fidelity", b"\x01"), attrs)
        self.assertIn((2, 0x44, "sides", b"one-sided"), attrs)
        self.assertIn((2, 0x44, "print-color-mode", b"monochrome"), attrs)
        self.assertIn((2, 0x4a, "", b"media-source"), attrs)
        self.assertIn((2, 0x44, "", b"tray-1"), attrs)

    def test_rejection_is_reported_and_not_retried(self):
        self.server.error = 0x040b  # client-error-attributes-or-values-not-supported
        result = self.cli("--submit", "--input", str(self.pdf))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Check its job list", result.stderr)
        self.assertEqual(sum(item[0] == 2 for item in self.server.requests), 1)

    def test_missing_job_id_is_uncertain(self):
        self.server.omit_id = True
        result = self.cli("--submit", "--input", str(self.pdf))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not return a job ID", result.stderr)
        self.assertEqual(sum(item[0] == 2 for item in self.server.requests), 1)

    def test_status_and_cancel_target_exact_job(self):
        for state in [3, 4, 5, 6, 7, 8, 9]:
            self.server.job_state = state
            result = self.cli("--status", "--job", "123")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"state={state}", result.stdout)
        result = self.cli("--cancel", "--job", "123")
        self.assertEqual(result.returncode, 0, result.stderr)
        for operation, attrs, _ in self.server.requests:
            if operation in [8, 9]:
                self.assertIn((1, 0x21, "job-id", integer(123)), attrs)

    def test_invalid_options_do_not_reach_printer(self):
        result = self.cli("--submit", "--input", str(self.pdf), "--tray", "tray-99")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.server.requests, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
