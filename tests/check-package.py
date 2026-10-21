"""Validate the actual production archives; run from a committed repository root."""
import json
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree


def validate(files, label):
    expected = {'package.json', 'plugin.xml', 'README.md'}
    tracked = subprocess.check_output(['git', 'ls-files'], text=True).splitlines()
    expected.update(p for p in tracked if p.startswith(('src/', 'www/', 'hooks/')))
    assert set(files) == expected, (label, 'Unexpected or missing files', set(files) ^ expected)
    for name, content in files.items():
        # Git checkouts may use CRLF on Windows; all current plugin inputs are text.
        assert content.replace(b'\r\n', b'\n') == Path(name).read_bytes().replace(b'\r\n', b'\n'), (
            label, 'Changed content', name
        )
    package = json.loads(files['package.json'])
    plugin = ElementTree.fromstring(files['plugin.xml'])
    assert package['version'] == plugin.attrib['version'], 'Version mismatch'
    assert package['cordova']['id'] == plugin.attrib['id'], 'Plugin ID mismatch'
    assert package['main'] in files, 'Missing JS entry point'
    assert set(package['cordova']['platforms']) == {'android', 'ios'}
    for element in plugin.iter():
        name = element.tag.rsplit('}', 1)[-1]
        if name in {'js-module', 'source-file', 'header-file', 'resource-file', 'hook', 'lib-file'} or (
            name == 'framework' and element.get('custom') == 'true'
        ):
            assert element.attrib['src'] in files, (label, 'Missing build input', element.attrib['src'])
    print(f'{label}: {len(files)} files, all build inputs present and unchanged')


with tempfile.TemporaryDirectory() as directory:
    archive = Path(directory) / 'plugin.zip'
    subprocess.run(['git', 'archive', '--format=zip', f'--output={archive}', 'HEAD'], check=True)
    with zipfile.ZipFile(archive) as zipped:
        validate({i.filename: zipped.read(i) for i in zipped.infolist() if not i.is_dir()}, 'Git ZIP')
    npm = shutil.which('npm.cmd') or shutil.which('npm')
    assert npm, 'npm is required for package validation'
    result = subprocess.check_output(
        [npm, 'pack', '--ignore-scripts', '--json', '--pack-destination', directory], text=True
    )
    packed = Path(directory) / json.loads(result)[0]['filename']
    with tarfile.open(packed, 'r:gz') as tar:
        validate({i.name.removeprefix('package/'): tar.extractfile(i).read()
                  for i in tar.getmembers() if i.isfile()}, 'npm tarball')
