#!/usr/bin/env python3
"""CLI regressions using generated PDF text layers. Never calls the OCR engine."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


def make_pdf(path, texts, page_sizes=None):
    """Write a small real PDF with one simple text stream per page."""
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b""]
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    page_ids = []
    for index, text in enumerate(texts):
        width, height = page_sizes[index] if page_sizes else (300, 400)
        page_id = len(objects) + 1
        page_ids.append(page_id)
        stream_id = page_id + 1
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] "
            f"/Resources << /Font << /F1 3 0 R >> >> /Contents {stream_id} 0 R >>".encode()
        )
        escaped = (text or "").replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        content = f"BT /F1 18 Tf 40 300 Td ({escaped}) Tj ET".encode("ascii") if text else b""
        objects.append(f"<< /Length {len(content)} >>\nstream\n".encode() + content + b"\nendstream")
    kids = " ".join(f"{page_id} 0 R" for page_id in page_ids)
    objects[1] = f"<< /Type /Pages /Kids [{kids}] /Count {len(page_ids)} >>".encode()
    data = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{number} 0 obj\n".encode() + obj + b"\nendobj\n")
    startxref = len(data)
    data.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{startxref}\n%%EOF\n".encode())
    path.write_bytes(data)


class CLITests(unittest.TestCase):
    binary = str(Path(sys.argv[1]).resolve())

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ocr-cli-")
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.pdf = self.directory / "three pages.pdf"
        make_pdf(self.pdf, ["Alpha first page", "Beta second page", "Gamma third page"])

    def call(self, *args, code=0):
        result = subprocess.run(
            [self.binary, *map(str, args)], cwd=self.directory,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, code, f"args={args}\nstdout={result.stdout}\nstderr={result.stderr}")
        return result

    def test_help_and_version(self):
        self.assertIn("--pages", self.call("--help").stdout)
        self.assertIn("0.2.0", self.call("--version").stdout)

    def test_dpi_rejects_invalid_and_unbounded_values(self):
        for value in ["nan", "inf", "-inf", "-1", "0", "banana"]:
            with self.subTest(value=value):
                self.call("--dpi", value, self.pdf, code=2)

    def test_malformed_arguments(self):
        cases = [
            ["--pages", "0"], ["--pages", "3-1"], ["--pages", "1,,2"],
            ["--pages", "1-"], ["--langs", ""], ["--langs", "en-US,,zh-Hans"],
            ["--rotate", "45"], ["--region", "0,0,2,1"], ["--region", "0,0,1,1,invalid"], ["--candidates", "0"],
            ["--json", "--jsonl"], ["--mode", "unknown"], ["--unknown"],
        ]
        for args in cases:
            with self.subTest(args=args):
                self.call(*args, self.pdf, code=2)
        self.call("--dpi", code=2)

    def test_missing_file_has_json_error(self):
        document = json.loads(self.call("--json", self.directory / "missing.pdf", code=1).stdout)[0]
        self.assertEqual(document["status"], "error")
        self.assertTrue(document["error"]["message"])
        self.assertEqual(document["pages"], [])

    def test_corrupt_inputs_have_json_errors(self):
        for name in ["corrupt.pdf", "corrupt.png"]:
            with self.subTest(name=name):
                path = self.directory / name
                path.write_text("not an image or PDF", encoding="utf-8")
                doc = json.loads(self.call("--json", path, code=1).stdout)[0]
                self.assertEqual(doc["status"], "error")
                self.assertTrue(doc["error"])

    def test_partial_batch_preserves_successful_document(self):
        result = self.call("--mode", "text", "--json", self.pdf, self.directory / "missing.pdf", code=1)
        documents = json.loads(result.stdout)
        self.assertEqual(len(documents), 2)
        self.assertEqual(documents[0]["status"], "ok")
        self.assertEqual(documents[1]["status"], "error")
        self.assertEqual([p["page"] for p in documents[0]["pages"]], [0, 1, 2])

    def test_page_failure_keeps_original_page_indexes(self):
        # Rendering the blank first page exceeds the pixel guard before Vision
        # is invoked; the second page follows the direct text extraction path.
        path = self.directory / "partial-pages.pdf"
        make_pdf(path, [None, "Recovered second page"], [(1000000, 1000000), (300, 400)])
        document = json.loads(self.call("--mode", "auto", "--json", path, code=1).stdout)[0]
        self.assertEqual(document["status"], "partial")
        self.assertEqual(document["failedPages"], 1)
        self.assertEqual([page["page"] for page in document["pages"]], [0, 1])
        self.assertEqual(document["pages"][0]["status"], "error")
        self.assertEqual(document["pages"][1]["source"], "text")
        self.assertIn("Recovered", document["pages"][1]["lines"][0]["text"])

    def test_selection_is_unique_and_keeps_source_page_number(self):
        document = json.loads(self.call("--mode", "text", "--pages", "3,1,3", "--json", self.pdf).stdout)[0]
        self.assertEqual([p["page"] for p in document["pages"]], [0, 2])
        self.assertIn("Alpha", " ".join(line["text"] for line in document["pages"][0]["lines"]))
        self.assertIn("Gamma", " ".join(line["text"] for line in document["pages"][1]["lines"]))
        self.assertEqual(document["schemaVersion"], 2)
        for page in document["pages"]:
            self.assertEqual(page["source"], "text")
            self.assertEqual(page["unit"], "pt")
            self.assertEqual(page["width"], 300)
            self.assertEqual(page["height"], 400)

    def test_jsonl_has_page_records_and_completion(self):
        result = self.call("--mode", "text", "--jsonl", "--pages", "2-3", "--progress", self.pdf)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        pages = [record for record in records if record["type"] == "page"]
        self.assertEqual([page["page"] for page in pages], [1, 2])
        self.assertEqual(records[-1]["type"], "file_end")
        self.assertTrue(result.stderr.strip())

    def test_auto_extracts_usable_text_without_ocr(self):
        doc = json.loads(self.call("--mode", "auto", "--json", self.pdf).stdout)[0]
        self.assertEqual([page["source"] for page in doc["pages"]], ["text", "text", "text"])

    def test_corrupt_text_layer_does_not_silently_fall_back_to_ocr(self):
        path = self.directory / "cid.pdf"
        make_pdf(path, ["/G21 /G22 /G23", "Valid next page"])
        for mode in ["text", "auto"]:
            with self.subTest(mode=mode):
                doc = json.loads(self.call("--mode", mode, "--json", path, code=1).stdout)[0]
                self.assertEqual(doc["status"], "partial")
                self.assertEqual(doc["pages"][0]["error"]["code"], "text_layer_unusable")
                self.assertEqual(doc["pages"][1]["page"], 1)

    def test_blank_text_page_is_successful_empty_result(self):
        blank = self.directory / "blank.pdf"
        make_pdf(blank, [None])
        doc = json.loads(self.call("--mode", "text", "--json", blank).stdout)[0]
        self.assertEqual(doc["pages"][0]["status"], "empty")
        self.assertEqual(doc["pages"][0]["lines"], [])

    def test_output_file_atomically_replaces_previous_contents(self):
        output = self.directory / "output.json"
        output.write_text("previous result", encoding="utf-8")
        result = self.call("--mode", "text", "--json", "--output", output, self.pdf)
        self.assertEqual(result.stdout, "")
        self.assertEqual(json.loads(output.read_text())[0]["status"], "ok")
        self.assertFalse(list(self.directory.glob(".*.ocr-*.tmp")))

    def test_invalid_arguments_leave_existing_output_untouched(self):
        output = self.directory / "output.json"
        output.write_text("keep me", encoding="utf-8")
        self.call("--output", output, "--dpi", "nan", self.pdf, code=2)
        self.assertEqual(output.read_text(), "keep me")

    def test_output_cannot_overwrite_input_or_hardlink(self):
        original = self.pdf.read_bytes()
        for output in [self.pdf, self.directory / "hardlink.pdf"]:
            with self.subTest(output=output):
                if output != self.pdf:
                    os.link(self.pdf, output)
                self.call("--mode", "text", "--output", output, self.pdf, code=1)
                self.assertEqual(self.pdf.read_bytes(), original)

    def test_output_rejects_symlink_and_directory(self):
        original = self.directory / "important.txt"
        original.write_text("keep me", encoding="utf-8")
        link = self.directory / "output-link"
        link.symlink_to(original)
        for path in [link, self.directory]:
            with self.subTest(path=path):
                self.call("--mode", "text", "--output", path, self.pdf, code=1)
        self.assertEqual(original.read_text(), "keep me")

    def test_dash_prefixed_filename_after_separator(self):
        path = self.directory / "-document.pdf"
        make_pdf(path, ["Dash file"])
        self.assertIn("Dash file", self.call("--mode", "text", "--", path.name).stdout)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: cli_tests.py /path/to/ocr")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
