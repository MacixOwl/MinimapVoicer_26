import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('package_source', Path(__file__).resolve().parents[1] / 'tools/package_source.py')
package_source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_source)


class SourceDistributionTest(unittest.TestCase):
    def test_excludes_local_material_and_keeps_both_models(self):
        private = ['.sign/sign-config.json5', 'material/ac/secret', 'mykey', 'mykey.pub',
                   '.env.local', 'local.properties', 'entry/.preview/image.png',
                   'entry/build/app.hap', 'oh_modules/dependency/index.js',
                   'artifacts/screenshot.png', '.npmrc', 'private.csr', 'private.p12']
        public = ['entry/src/main/resources/rawfile/local-tts/model.onnx',
                  'entry/src/main/resources/rawfile/local-tts/vocoder.onnx',
                  'entry/libs/arm64-v8a/libphonecapture.so', 'licenses/Matcha-Baker-NOTICE.txt',
                  'oh-package-lock.json5', '.gitignore']
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'source'
            for relative in private + public:
                source = root / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(relative.encode('utf-8'))
            selected = package_source.source_files(root)
            self.assertEqual({source.relative_to(root).as_posix() for source in selected}, set(public))
            output = Path(temporary) / 'source.zip'
            package_source.write_archive(root, selected, output)
            with zipfile.ZipFile(str(output)) as archive:
                names = archive.namelist()
                for relative in public:
                    self.assertEqual(archive.read('source/' + relative), relative.encode('utf-8'))
                self.assertFalse(any('source/' + relative in names for relative in private))

    def test_secret_detection_does_not_print_the_secret(self):
        secret = 'sk-' + 'z' * 40
        findings = package_source.secret_findings(Path('config.json'), ('{"apiKey":"' + secret + '"}').encode())
        self.assertTrue(findings)
        self.assertNotIn(secret, str(findings))
        private_key = ('-----BEGIN ' + 'PRIVATE KEY-----').encode()
        self.assertTrue(package_source.secret_findings(Path('data.txt'), private_key))

    def test_only_known_test_credentials_are_allowed(self):
        fixture = b"page.apiKey = 'test-key-never-log';"
        self.assertFalse(package_source.secret_findings(Path('tests/test_cloud_battle.cjs'), fixture))
        self.assertTrue(package_source.secret_findings(Path('config.js'), fixture))
        unexpected = b'api' + b"Key='unexpected-value'"
        self.assertTrue(package_source.secret_findings(Path('tests/test_cloud_battle.cjs'), unexpected))


if __name__ == '__main__':
    unittest.main()
