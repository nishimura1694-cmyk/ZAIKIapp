import argparse
import json
import os
import sys
from io import BytesIO
from pathlib import Path

import dropbox
import pdfplumber


def download_pdf_bytes(token: str, dropbox_path: str) -> bytes:
    dbx = dropbox.Dropbox(token)
    _, response = dbx.files_download(dropbox_path)
    return response.content


def extract_text_pages(pdf_bytes: bytes) -> list[dict]:
    pages = []
    with pdfplumber.open(BytesIO(pdf_bytes)) as pdf:
        for i, page in enumerate(pdf.pages, start=1):
            text = page.extract_text() or ""
            pages.append(
                {
                    "page": i,
                    "char_count": len(text),
                    "text": text,
                }
            )
    return pages


def build_output(dropbox_path: str, pages: list[dict]) -> dict:
    return {
        "source": {
            "type": "dropbox",
            "path": dropbox_path,
        },
        "page_count": len(pages),
        "pages": pages,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download a text-based PDF from Dropbox and export text as JSON."
    )
    parser.add_argument(
        "--dropbox-path",
        required=True,
        help="Dropbox path to PDF, e.g. /docs/sample.pdf",
    )
    parser.add_argument(
        "--output",
        default="output/pdf_text.json",
        help="Output JSON path (default: output/pdf_text.json)",
    )
    parser.add_argument(
        "--token",
        default=os.getenv("DROPBOX_ACCESS_TOKEN", ""),
        help="Dropbox access token. If omitted, uses DROPBOX_ACCESS_TOKEN env var.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    token = args.token.strip()
    if not token:
        print(
            "Dropbox token is missing. Set --token or DROPBOX_ACCESS_TOKEN.",
            file=sys.stderr,
        )
        return 1

    dropbox_path = args.dropbox_path.strip()
    if not dropbox_path.startswith("/"):
        print("--dropbox-path must start with '/'.", file=sys.stderr)
        return 1

    try:
        pdf_bytes = download_pdf_bytes(token=token, dropbox_path=dropbox_path)
    except Exception as exc:
        print(f"Failed to download PDF from Dropbox: {exc}", file=sys.stderr)
        return 1

    try:
        pages = extract_text_pages(pdf_bytes)
    except Exception as exc:
        print(f"Failed to extract text from PDF: {exc}", file=sys.stderr)
        return 1

    output = build_output(dropbox_path=dropbox_path, pages=pages)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Saved JSON: {out_path}")
    print(f"Pages: {len(pages)}")
    print(f"Total chars: {sum(page['char_count'] for page in pages)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())