#!/usr/bin/env python3
"""Runs upstream's synthetic Now Playing self-test, with a hard timeout."""
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parent.parent
try:
    result = subprocess.run(['/usr/bin/perl', str(root/'Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl'), str(root/'.build/adapter/MediaRemoteAdapter.framework'), str(root/'.build/adapter/MediaRemoteAdapterTestClient'), 'test'], capture_output=True, timeout=20)
    print('Synthetic MediaRemote self-test exit:', result.returncode)
    raise SystemExit(result.returncode)
except subprocess.TimeoutExpired:
    print('Self-test timed out. Real playback compatibility is unverified.')
    raise SystemExit(1)
