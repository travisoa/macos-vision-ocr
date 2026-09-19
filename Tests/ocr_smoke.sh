#!/bin/bash
# Optional end-to-end Vision check; requires the host's normal ANE access.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OCR_SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ocr-smoke.XXXXXX")"
trap 'rm -rf "$OCR_SMOKE_DIR"' EXIT
if [[ -n "${OCR_BINARY:-}" ]]; then
  OCR_SMOKE_BINARY="$OCR_BINARY"
else
  OCR_SMOKE_BINARY="$DIR/build/ocr"
fi
[[ -x "$OCR_SMOKE_BINARY" ]] || { echo "Run ./build.sh first, or set OCR_BINARY to an existing executable." >&2; exit 1; }
mkdir -p "$DIR/.build/fixture-cache"
xcrun swiftc -module-cache-path "$DIR/.build/fixture-cache" "$DIR/Tests/fixtures/SmokeFixture.swift" -o "$OCR_SMOKE_DIR/fixtures"
"$OCR_SMOKE_DIR/fixtures" "$OCR_SMOKE_DIR" >/dev/null
"$OCR_SMOKE_BINARY" --json --no-correction --candidates 2 "$OCR_SMOKE_DIR/sample.png" > "$OCR_SMOKE_DIR/image.json"
"$OCR_SMOKE_BINARY" --jsonl --pages 2 --dpi 144 --rotate 270 "$OCR_SMOKE_DIR/scanned.pdf" > "$OCR_SMOKE_DIR/pdf.jsonl"
"$OCR_SMOKE_BINARY" --json --region 0,0,1,0.22 "$OCR_SMOKE_DIR/sample.png" > "$OCR_SMOKE_DIR/region.json"
"$OCR_SMOKE_BINARY" --tables --json "$OCR_SMOKE_DIR/sample.png" > "$OCR_SMOKE_DIR/table.json"
"$OCR_SMOKE_BINARY" --format csv "$OCR_SMOKE_DIR/sample.png" > "$OCR_SMOKE_DIR/table.csv"
python3 - "$OCR_SMOKE_DIR" <<'PY'
import csv, json, sys
from pathlib import Path
p = Path(sys.argv[1])
image = json.loads((p/'image.json').read_text())[0]['pages'][0]
assert image['status'] == 'ok' and image['unit'] == 'px'
text = '\n'.join(line['text'] for line in image['lines'])
assert '7258' in text and '4520' in text and '车辆' in text, text
assert all('confidence' in line and 'candidates' in line for line in image['lines'])
pages = [json.loads(line) for line in (p/'pdf.jsonl').read_text().splitlines()]
page = next(item for item in pages if item['type']=='page')
assert page['page'] == 1 and page['unit'] == 'pt' and page['rotation'] == 0
assert page['dpi'] == 144 and page['width'] == 600 and page['height'] == 450
assert '4520' in '\n'.join(line['text'] for line in page['lines'])
region = json.loads((p/'region.json').read_text())[0]['pages'][0]
assert '7258' in '\n'.join(line['text'] for line in region['lines'])
assert '4520' not in '\n'.join(line['text'] for line in region['lines'])
assert region['width'] == 1200 and region['height'] == 900
assert all(0 <= line['bbox'][1] <= line['bbox'][3] <= 200 for line in region['lines'])
table = json.loads((p/'table.json').read_text())[0]['pages'][0]
assert table['tables'], table
assert any('4520' in cell['text'] for t in table['tables'] for cell in t['cells'])
rows = list(csv.DictReader((p/'table.csv').open()))
assert any('4520' in row['text'] for row in rows), rows
print('Vision smoke passed: Chinese/English image, rotated PDF, region, candidates, table JSON/CSV')
PY
