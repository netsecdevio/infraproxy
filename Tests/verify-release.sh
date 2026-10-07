#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT=${1:?Usage: bash Tests/verify-release.sh dist/version}
Vendor/Sparkle/bin/sign_update --account com.dynadobe.infraproxy --verify "$OUTPUT/appcast.xml"
python3 - "$OUTPUT" <<'PY'
import pathlib, subprocess, sys, tempfile, xml.etree.ElementTree as ET
root = pathlib.Path(sys.argv[1]).resolve()
feed = ET.parse(root / 'appcast.xml')
item = feed.find('./channel/item')
assert item is not None
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
enclosure = item.find('enclosure')
assert enclosure is not None
signature = enclosure.attrib[ns + 'edSignature']
archive = next(root.glob('*.dmg'))
assert int(enclosure.attrib['length']) == archive.stat().st_size
assert enclosure.attrib['url'].startswith('https://github.com/netsecdevio/infraproxy/releases/download/v')
assert enclosure.attrib['url'].endswith('/' + archive.name)
assert item.find(ns + 'version') is not None
assert item.find(ns + 'minimumSystemVersion').text == '15.5'
tool = str(pathlib.Path('Vendor/Sparkle/bin/sign_update').resolve())
verify = [tool, '--account', 'com.dynadobe.infraproxy', '--verify']
subprocess.run(verify + [str(archive), signature], check=True)
with tempfile.TemporaryDirectory() as tmp:
    tampered = pathlib.Path(tmp) / 'tampered.dmg'
    data = bytearray(archive.read_bytes())
    data[len(data) // 2] ^= 1
    tampered.write_bytes(data)
    result = subprocess.run(verify + [str(tampered), signature], capture_output=True)
    assert result.returncode != 0, 'Modified archive unexpectedly passed signature verification'
    altered_feed = pathlib.Path(tmp) / 'appcast.xml'
    altered_feed.write_bytes((root / 'appcast.xml').read_bytes().replace(b'<title>', b'<title>Modified ', 1))
    result = subprocess.run(verify + [str(altered_feed)], capture_output=True)
    assert result.returncode != 0, 'Modified feed unexpectedly passed signature verification'
print('PASS: feed metadata, archive signature, tampered archive rejection, tampered feed rejection')
PY
