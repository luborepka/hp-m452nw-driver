"""Black-box tests of the shipped native service, with no real printer."""
import http.client
import http.server
import json
import pathlib
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from test_ipp import Handler, attr, integer, parse, ROOT

BINARY = ROOT / 'build/hp-open-print'
DIAGNOSTICS = ROOT / 'build/hp-open-print-tests'

class NativeHarness(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        cls.pdf = pathlib.Path(cls.fixture.name) / 'test.pdf'
        subprocess.run([str(DIAGNOSTICS), '--make-test', '--output', str(cls.pdf)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.physical = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.physical.requests = []
        self.physical.error = 0
        self.physical.omit_id = False
        self.physical.job_state = 9
        self.physical.tray_level = 0
        self.thread = threading.Thread(target=self.physical.serve_forever, daemon=True)
        self.thread.start()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            self.port = listener.getsockname()[1]
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps({'uri': f'ipp://127.0.0.1:{self.physical.server_port}/ipp/print', 'uuid': 'b143c9c9-7655-5bfd-bed0-cf7166adfbb1', 'port': self.port, 'spool': str(self.root/'Jobs')}))
        self.start()

    def start(self):
        self.process = subprocess.Popen([str(BINARY), '--serve', '--config', str(self.config)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                for port in getattr(self, 'ports', [self.port]):
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        pass
                return
            except OSError:
                if self.process.poll() is not None:
                    break
                time.sleep(.05)
        self.process.terminate()
        _, error = self.process.communicate(timeout=5)
        self.fail('Native driver failed to start: ' + error.decode())

    def stop(self):
        self.process.terminate()
        self.process.communicate(timeout=5)

    def tearDown(self):
        self.stop()
        self.physical.shutdown()
        self.physical.server_close()
        self.thread.join()
        self.temp.cleanup()

    def ipp(self, operation, values=b'', document=b'', chunked=False, version=b'\x01\x01', path='/ipp/print', port=None):
        port = self.port if port is None else port
        body = version + struct.pack('>HI', operation, 1) + b'\x01' + attr(0x47, 'attributes-charset', 'utf-8') + attr(0x48, 'attributes-natural-language', 'en') + attr(0x45, 'printer-uri', f'ipp://localhost:{port}/ipp/print') + values + b'\x03' + document
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
        payload = iter(body[i:i+127] for i in range(0, len(body), 127)) if chunked else body
        connection.request('POST', path, body=payload, headers={'Content-Type': 'application/ipp'}, encode_chunked=chunked)
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        data = response.read()
        connection.close()
        self.assertEqual(data[:2], version)
        attributes, _ = parse(data)
        return struct.unpack_from('>H', data, 2)[0], attributes

    def value(self, attrs, name):
        data = next(item[3] for item in attrs if item[2] == name)
        return struct.unpack('>i', data)[0] if len(data) == 4 and name in ('job-id', 'job-state') else data.decode()

    def wait(self, job, state=9, port=None):
        for _ in range(100):
            code, attrs = self.ipp(9, attr(0x21, 'job-id', integer(job)), port=port)
            self.assertEqual(code, 0)
            if self.value(attrs, 'job-state') == state:
                return attrs
            time.sleep(.05)
        self.fail('Job did not reach expected state: ' + str(attrs))

    def prints(self):
        return [request for request in self.physical.requests if request[0] == 2]

class NativeTests(NativeHarness):
    def test_native_duplex_passes_and_pdf_pairing(self):
        code, attrs = self.ipp(2, b'\x02' + attr(0x44, 'sides', 'two-sided-long-edge'), self.pdf.read_bytes(), chunked=True)
        self.assertEqual(code, 0)
        self.wait(self.value(attrs, 'job-id'))
        prints = self.prints()
        self.assertEqual(len(prints), 2)
        for i, expected in enumerate(('tray-2', 'tray-1')):
            self.assertIn((2, 0x44, '', expected.encode()), prints[i][1])
            file = self.root / f'pass-{i}.pdf'
            file.write_bytes(prints[i][2])
            result = subprocess.run([str(DIAGNOSTICS), '--inspect', '--input', str(file)], capture_output=True, text=True, check=True)
            pages = json.loads(result.stdout)
            expected_numbers = (1, 3) if i == 0 else (4, 2)
            self.assertEqual(len(pages), 2)
            for page, number in zip(pages, expected_numbers):
                self.assertIn(f'Page {number} of 4', page['text'])
        self.assertFalse((self.root/'Jobs/1/input.pdf').exists())

    def test_simplex_preserves_input_without_rendering(self):
        original = self.pdf.read_bytes()
        code, attrs = self.ipp(2, b'', original)
        self.assertEqual(code, 0)
        self.wait(self.value(attrs, 'job-id'))
        self.assertEqual(len(self.prints()), 1)
        self.assertEqual(self.prints()[0][2], original)

    def test_loaded_tray_blocks_before_printing(self):
        self.physical.tray_level = -3
        code, attrs = self.ipp(2, b'\x02' + attr(0x44, 'sides', 'two-sided-long-edge'), self.pdf.read_bytes())
        self.assertEqual(code, 0)
        status = self.wait(self.value(attrs, 'job-id'), state=6)
        self.assertIn('Empty front Tray 1', self.value(status, 'job-state-message'))
        self.assertEqual(self.prints(), [])

    def test_invalid_pdf_does_not_print(self):
        code, _ = self.ipp(2, b'', b'not a PDF')
        self.assertEqual(code, 0x040a)
        self.assertEqual(self.prints(), [])

    def test_create_send_and_duplicate_rejection(self):
        code, attrs = self.ipp(5)
        self.assertEqual(code, 0)
        job = self.value(attrs, 'job-id')
        fields = attr(0x21, 'job-id', integer(job)) + attr(0x22, 'last-document', b'\x01')
        self.assertEqual(self.ipp(6, fields, self.pdf.read_bytes())[0], 0)
        self.assertEqual(self.ipp(6, fields, self.pdf.read_bytes())[0], 0x0404)
        self.wait(job)
        self.assertEqual(len(self.prints()), 1)

    def test_cancel_upload_and_get_jobs_groups(self):
        for expected in (1, 2):
            code, attrs = self.ipp(5)
            self.assertEqual(code, 0)
            self.assertEqual(self.value(attrs, 'job-id'), expected)
            self.assertEqual(self.ipp(8, attr(0x21, 'job-id', integer(expected)))[0], 0)
        code, attrs = self.ipp(10, attr(0x44, 'which-jobs', 'all'))
        self.assertEqual(code, 0)
        self.assertEqual([struct.unpack('>i', item[3])[0] for item in attrs if item[2] == 'job-id'], [1, 2])
        self.assertEqual(self.prints(), [])

    def test_lost_submission_survives_restart_without_replay(self):
        self.stop()
        folder = self.root/'Jobs/1'
        folder.mkdir()
        (folder/'record.json').write_text(json.dumps({'id': 1, 'title': 'test', 'user': 'local', 'state': 5, 'phase': 'submitting-fronts', 'message': 'sending', 'document_received': True, 'created': int(time.time()), 'sides': 'two-sided-long-edge', 'copies': 1, 'paper': 'a4', 'color': 'color'}))
        self.start()
        attrs = self.wait(1, state=6)
        self.assertIn('unknown after restart', self.value(attrs, 'job-state-message'))
        self.assertEqual(self.physical.requests, [])

    def test_version_two_and_chunked_validation(self):
        self.assertEqual(self.ipp(11, version=b'\x02\x00')[0], 0)
        self.assertEqual(self.ipp(4, chunked=True)[0], 0)

    def test_advertised_job_uri_is_queryable(self):
        code, attrs = self.ipp(5)
        self.assertEqual(code, 0)
        uri = self.value(attrs, 'job-uri')
        code, status = self.ipp(9, attr(0x45, 'job-uri', uri), path='/ipp/print/jobs/1')
        self.assertEqual(code, 0)
        self.assertEqual(self.value(status, 'job-id'), 1)

class MultiplePrinterTests(NativeHarness):
    def setUp(self):
        super().setUp()
        self.stop()
        self.other = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.other.requests, self.other.error, self.other.omit_id = [], 0, False
        self.other.job_state, self.other.tray_level = 9, 0
        self.other_thread = threading.Thread(target=self.other.serve_forever, daemon=True)
        self.other_thread.start()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            self.other_port = listener.getsockname()[1]
        self.assertNotEqual(self.port, self.other_port)
        first = json.loads(self.config.read_text())
        second = dict(first, uri=f'ipp://127.0.0.1:{self.other.server_port}/ipp/print', uuid='b143c9c9-7655-5bfd-bed0-cf7166adfbb2', port=self.other_port, spool=str(self.root/'OtherJobs'))
        self.config.write_text(json.dumps({'printers': [dict(id=first['uuid'], name='Office A', queue='HP_M452nw_A', config=first), dict(id=second['uuid'], name='Office B', queue='HP_M452nw_B', config=second)]}))
        self.ports = [self.port, self.other_port]
        self.start()

    def tearDown(self):
        super().tearDown()
        self.other.shutdown()
        self.other.server_close()
        self.other_thread.join()

    def test_stopped_printer_does_not_block_or_redirect_other_printer(self):
        self.physical.error = 0x0500
        first, second = (self.pdf.read_bytes() + suffix for suffix in (b'\n% Office A\n', b'\n% Office B\n'))
        code, attrs = self.ipp(2, document=first)
        self.assertEqual(code, 0)
        self.wait(self.value(attrs, 'job-id'), state=6)
        self.assertEqual(self.ipp(5)[0], 0x0507)
        code, attrs = self.ipp(2, document=second, port=self.other_port)
        self.assertEqual(code, 0)
        self.wait(self.value(attrs, 'job-id'), port=self.other_port)
        self.assertEqual(self.prints()[0][2], first)
        self.assertEqual([r[2] for r in self.other.requests if r[0] == 2], [second])
        self.assertTrue((self.root/'Jobs/1/input.pdf').exists())
        self.assertFalse((self.root/'OtherJobs/1/input.pdf').exists())

    def test_cancel_and_restart_keep_job_histories_separate(self):
        for port in self.ports:
            code, attrs = self.ipp(5, attr(0x42, 'job-name', str(port)), port=port)
            self.assertEqual(code, 0)
            self.assertEqual(self.value(attrs, 'job-id'), 1)
        self.assertEqual(self.ipp(8, attr(0x21, 'job-id', integer(1)))[0], 0)
        self.wait(1, state=3, port=self.other_port)
        self.assertEqual(self.ipp(8, attr(0x21, 'job-id', integer(1)), port=self.other_port)[0], 0)
        self.stop()
        self.start()
        identities = []
        for port in self.ports:
            attrs = self.wait(1, state=7, port=port)
            self.assertEqual(self.value(attrs, 'job-name'), str(port))
            code, caps = self.ipp(11, port=port)
            self.assertEqual(code, 0)
            identities.append(self.value(caps, 'printer-uuid'))
        self.assertNotEqual(*identities)
        self.assertEqual(self.physical.requests + self.other.requests, [])

if __name__ == '__main__':
    unittest.main(verbosity=2)
