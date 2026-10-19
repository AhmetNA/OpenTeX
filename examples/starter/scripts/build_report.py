#!/usr/bin/env python3
"""Compile the example locally; a failed build preserves the last successful PDF."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
report = root / 'report'
output = root / 'output/pdf'
engine = shutil.which('tectonic')
if not engine:
    raise SystemExit('Tectonic is missing. Install it with: brew install tectonic')
build = report / 'build'
build.mkdir(parents=True, exist_ok=True)
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='run-', dir=build) as folder:
    result = subprocess.run([engine, '--untrusted', '--keep-logs', '--outdir', folder, 'rapor.tex'], cwd=report)
    if result.returncode:
        raise SystemExit(result.returncode)
    pdf = Path(folder) / 'rapor.pdf'
    if not pdf.is_file() or not pdf.read_bytes().startswith(b'%PDF-'):
        raise SystemExit('No valid PDF was generated.')
    staged = output / '.bitirme-raporu.pdf.tmp'
    shutil.copy2(pdf, staged)
    os.replace(staged, output / 'bitirme-raporu.pdf')
print('PDF ready:', output / 'bitirme-raporu.pdf')
