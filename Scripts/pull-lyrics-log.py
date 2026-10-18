#!/usr/bin/env python3
"""Copy EeveeSpotify's saved debug log from a paired iPhone using CoreDevice."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', help='CoreDevice identifier or device name; defaults to a wired iPhone')
parser.add_argument('--bundle', help='Installed Spotify bundle ID, including any signing suffix')
parser.add_argument('--output', type=Path, default=Path('Outputs/Diagnostics/eeveespotify_debug.log'))
args = parser.parse_args()

def query(arguments):
    with tempfile.TemporaryDirectory(prefix='eevee-device-') as directory:
        output = Path(directory) / 'result.json'
        result = subprocess.run(['xcrun', 'devicectl', '--timeout', '15', '--json-output', str(output), *arguments], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError((result.stderr or result.stdout)[-1200:])
        return json.loads(output.read_text()).get('result', {})

try:
    device = args.device
    if not device:
        devices = query(['list', 'devices']).get('devices', [])
        wired = [value for value in devices if value.get('connectionProperties', {}).get('transportType') == 'wired']
        if len(wired) != 1:
            raise RuntimeError('Connect one trusted iPhone by USB, or pass --device.')
        device = wired[0]['identifier']
    bundle = args.bundle
    if not bundle:
        apps = query(['device', 'info', 'apps', '--device', device]).get('apps', [])
        spotify = [value['bundleIdentifier'] for value in apps if value.get('bundleIdentifier', '').startswith('com.spotify.client')]
        if len(spotify) != 1:
            raise RuntimeError('Pass --bundle with the installed Spotify bundle ID.')
        bundle = spotify[0]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(['xcrun', 'devicectl', '--timeout', '15', 'device', 'copy', 'from', '--device', device,
        '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--source', 'tmp/eeveespotify_debug.log',
        '--destination', str(args.output.resolve())], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError('No saved log available. Enable Debug logging in EeveeSpotify settings, reproduce the problem, then retry.\n' + (result.stderr or result.stdout)[-700:])
    print(f'Saved {args.output}')
except (RuntimeError, subprocess.TimeoutExpired) as error:
    parser.exit(1, f'{error}\n')
