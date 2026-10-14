#!/usr/bin/env python3
"""Read-only probe. Never prints titles, artists, lyrics, or raw payloads."""
import json
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parent.parent
command = ['/usr/bin/perl', str(root / 'Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl'), str(root / '.build/adapter/MediaRemoteAdapter.framework'), 'get', '--micros', '--no-artwork']
try:
    result = subprocess.run(command, capture_output=True, timeout=10)
    payload = json.loads(result.stdout)
    print(json.dumps({'exitCode': result.returncode, 'sessionPresent': bool(payload), 'fieldsPresent': sorted(payload) if payload else [], 'positionPresent': bool(payload and payload.get('elapsedTimeMicros') is not None)}, indent=2))
except subprocess.TimeoutExpired:
    print('MediaRemote timed out; compatibility is not confirmed.')
    raise SystemExit(1)
except (ValueError, OSError):
    print('MediaRemote returned no valid JSON; compatibility is not confirmed.')
    raise SystemExit(1)
