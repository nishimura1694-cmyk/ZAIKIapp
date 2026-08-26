import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from io import BytesIO
from pathlib import Path
from typing import Optional

import dropbox
import pdfplumber
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google.oauth2.service_account import Credentials as ServiceAccountCredentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build


# Google Sheets API設定
SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]
_SHEET_TITLE_CACHE: dict[str, set[str]] = {}


def configure_console_output() -> None:
    """Use UTF-8 for console logs when the runtime supports stream reconfiguration."""
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors="replace")


def authenticate_google_sheets(
    credentials_file: str = "credentials.json",
    token_file: str = "token.json",
) -> any:
    """Google Sheets APIに認証する"""
    creds = None

    if Path(token_file).exists():
        creds = Credentials.from_authorized_user_file(token_file, SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(credentials_file, SCOPES)
            creds = flow.run_local_server(port=0)

        Path(token_file).write_text(creds.to_json())

    return build("sheets", "v4", credentials=creds)


def download_pdf_bytes(token: str, dropbox_path: str) -> bytes:
    """DropboxからPDFをダウンロード"""
    dbx = dropbox.Dropbox(token)
    _, response = dbx.files_download(dropbox_path)
    return response.content


def extract_tables_from_pdf(pdf_bytes: bytes) -> list[dict]:
    """PDFから表データを抽出"""
    tables = []
    with pdfplumber.open(BytesIO(pdf_bytes)) as pdf:
        for page_num, page in enumerate(pdf.pages, start=1):
            page_tables = page.extract_tables()
            if page_tables:
                for table_idx, table in enumerate(page_tables):
                    tables.append(
                        {
                            "page": page_num,
                            "table_index": table_idx,
                            "headers": table[0] if table else [],
                            "rows": table[1:] if len(table) > 1 else [],
                        }
                    )
    return tables


def extract_text_lines_from_pdf(pdf_bytes: bytes) -> list[dict]:
    """PDFからテキスト行を抽出"""
    pages = []
    with pdfplumber.open(BytesIO(pdf_bytes)) as pdf:
        for i, page in enumerate(pdf.pages, start=1):
            text = page.extract_text() or ""
            lines = [line.strip() for line in text.split("\n") if line.strip()]
            pages.append(
                {
                    "page": i,
                    "lines": lines,
                }
            )
    return pages


def create_google_sheet(service: any, title: str) -> str:
    """新しいGoogle Sheetを作成"""
    body = {"properties": {"title": title}}
    sheet = service.spreadsheets().create(body=body).execute()
    return sheet["spreadsheetId"]


def sanitize_sheet_title(title: str, max_len: int = 90) -> str:
    """Google Sheetsの制約に合わせてシート名を安全化する"""
    cleaned = re.sub(r"[\[\]\*\?/\\:]", "_", title).strip()
    if not cleaned:
        cleaned = "Sheet"
    return cleaned[:max_len]


def quote_sheet_title(title: str) -> str:
    """A1参照用にシート名をクオートする"""
    return "'" + title.replace("'", "''") + "'"


def ensure_sheet_exists(service: any, spreadsheet_id: str, sheet_name: str) -> None:
    """指定シートが存在しなければ作成する"""
    titles = _SHEET_TITLE_CACHE.get(spreadsheet_id)
    if titles is None:
        meta = service.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
        titles = {
            s.get("properties", {}).get("title", "")
            for s in meta.get("sheets", [])
        }
        _SHEET_TITLE_CACHE[spreadsheet_id] = titles
    if sheet_name in titles:
        return

    body = {"requests": [{"addSheet": {"properties": {"title": sheet_name}}}]}
    service.spreadsheets().batchUpdate(spreadsheetId=spreadsheet_id, body=body).execute()
    titles.add(sheet_name)


def append_table_to_sheet(
    service: any,
    spreadsheet_id: str,
    sheet_name: str,
    table_data: list,
) -> None:
    """テーブルデータをGoogle Sheetに追加"""
    if not table_data:
        return

    safe_sheet_name = sanitize_sheet_title(sheet_name)
    ensure_sheet_exists(service, spreadsheet_id, safe_sheet_name)
    range_name = f"{quote_sheet_title(safe_sheet_name)}!A1"
    body = {"values": table_data}
    max_attempts = 5
    for attempt in range(1, max_attempts + 1):
        try:
            service.spreadsheets().values().append(
                spreadsheetId=spreadsheet_id,
                range=range_name,
                valueInputOption="RAW",
                body=body,
            ).execute()
            # Write requests per minute quotaを避けるために短時間待機
            time.sleep(1.1)
            return
        except Exception:
            if attempt == max_attempts:
                raise
            time.sleep(min(2 ** attempt, 30))


def build_flat_table_rows(pdf_path: str, tables: list[dict]) -> list[list[str]]:
    """複数テーブルを1シート向けの行データへフラット化する"""
    rows: list[list[str]] = []
    for table in tables:
        page = str(table.get("page", ""))
        table_no = str(int(table.get("table_index", 0)) + 1)

        headers = table.get("headers") or []
        if headers:
            rows.append([pdf_path, page, table_no, "header", "0", *[str(c or "") for c in headers]])

        for idx, row in enumerate(table.get("rows") or [], start=1):
            rows.append([pdf_path, page, table_no, "row", str(idx), *[str(c or "") for c in row]])

    return rows


def summarize_table_values(tables: list[dict], max_items: int = 120) -> str:
    """テーブル値をタイトル単位1行出力向けに要約する"""
    values: list[str] = []
    seen: set[str] = set()
    for table in tables:
        rows = []
        headers = table.get("headers") or []
        if headers:
            rows.append(headers)
        rows.extend(table.get("rows") or [])
        for row in rows:
            for cell in row:
                text = str(cell or "").strip()
                if not text:
                    continue
                if text in seen:
                    continue
                seen.add(text)
                values.append(text)
                if len(values) >= max_items:
                    return " | ".join(values)
    return " | ".join(values)


def build_raw_table_text(tables: list[dict]) -> str:
    """テーブル内容を可能な限り加工せずに連結する"""
    lines: list[str] = []
    for table in tables:
        rows: list[list] = []
        headers = table.get("headers") or []
        if headers:
            rows.append(headers)
        rows.extend(table.get("rows") or [])

        for row in rows:
            cells = [str(c or "").strip() for c in row]
            if any(cells):
                lines.append("\t".join(cells))
    return "\n".join(lines)


def _parse_date_from_text_fragment(text: str, today: date) -> Optional[date]:
    full_year_patterns = [
        r"(\d{4})\s*[./-]\s*(\d{1,2})\s*[./-]\s*(\d{1,2})",
        r"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日",
    ]
    for pattern in full_year_patterns:
        m = re.search(pattern, text)
        if not m:
            continue
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        try:
            return date(y, mo, d)
        except ValueError:
            continue

    mmdd_patterns = [
        r"(\d{1,2})\s*[./-]\s*(\d{1,2})",
        r"(\d{1,2})\s*月\s*(\d{1,2})\s*日",
    ]
    for pattern in mmdd_patterns:
        m = re.search(pattern, text)
        if not m:
            continue
        mo, d = int(m.group(1)), int(m.group(2))
        try:
            candidate = date(today.year, mo, d)
        except ValueError:
            continue

        # 年がない場合は今日に近い年へ寄せる
        if (candidate - today).days > 180:
            candidate = date(today.year - 1, mo, d)
        elif (today - candidate).days > 180:
            candidate = date(today.year + 1, mo, d)
        return candidate

    return None


def extract_delivery_date_from_pdf(pdf_bytes: bytes, today: date) -> Optional[date]:
    """PDF本文の「お引渡し日」右側から日付を抽出する"""
    lines: list[str] = []
    with pdfplumber.open(BytesIO(pdf_bytes)) as pdf:
        for page in pdf.pages:
            text = page.extract_text() or ""
            lines.extend([line.strip() for line in text.split("\n") if line.strip()])

    key = "お引渡し日"
    for idx, line in enumerate(lines):
        if key not in line:
            continue

        right_side = line.split(key, 1)[1]
        parsed = _parse_date_from_text_fragment(right_side, today)
        if parsed:
            return parsed

        parsed = _parse_date_from_text_fragment(line, today)
        if parsed:
            return parsed

        if idx + 1 < len(lines):
            parsed = _parse_date_from_text_fragment(lines[idx + 1], today)
            if parsed:
                return parsed

    return None


def list_dropbox_pdfs(
    token: str, folder_path: str, recursive: bool = True
) -> list[dropbox.files.FileMetadata]:
    """Dropboxフォルダ内のPDFメタデータを一覧取得"""
    dbx = dropbox.Dropbox(token)
    # Dropbox APIではルートは"/"ではなく空文字で指定する
    normalized_path = "" if folder_path.strip() == "/" else folder_path
    result = dbx.files_list_folder(normalized_path, recursive=recursive)
    pdfs: list[dropbox.files.FileMetadata] = []

    while True:
        for entry in result.entries:
            if isinstance(entry, dropbox.files.FileMetadata) and entry.name.lower().endswith(
                ".pdf"
            ):
                pdfs.append(entry)

        if not result.has_more:
            break

        result = dbx.files_list_folder_continue(result.cursor)

    return pdfs


def refresh_dropbox_access_token(
    app_key: str,
    app_secret: str,
    refresh_token: str,
) -> str:
    """Dropboxのrefresh tokenから短命access tokenを再発行する"""
    basic_auth = base64.b64encode(f"{app_key}:{app_secret}".encode("utf-8")).decode("ascii")
    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        "https://api.dropboxapi.com/oauth2/token",
        data=body,
        headers={
            "Authorization": f"Basic {basic_auth}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read().decode("utf-8"))

    access_token = str(payload.get("access_token", "")).strip()
    if not access_token:
        raise RuntimeError("Dropbox token refresh response has no access_token")
    return access_token


def resolve_dropbox_access_token(args: argparse.Namespace) -> tuple[str, str]:
    """引数/環境変数からDropbox access tokenを解決する"""
    refresh_token = args.dropbox_refresh_token.strip()
    app_key = args.dropbox_app_key.strip()
    app_secret = args.dropbox_app_secret.strip()

    # refresh token情報が揃っていれば、常に最新のaccess tokenを再発行して利用する
    if refresh_token and app_key and app_secret:
        token = refresh_dropbox_access_token(app_key, app_secret, refresh_token)
        return token, "refresh_token"

    token = args.dropbox_token.strip()
    if token:
        return token, "access_token"

    return "", ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract tables from PDFs in Dropbox and export to Google Sheets."
    )
    parser.add_argument(
        "--dropbox-token",
        default=os.getenv("DROPBOX_ACCESS_TOKEN", ""),
        help="Dropbox access token. If omitted, uses DROPBOX_ACCESS_TOKEN env var.",
    )
    parser.add_argument(
        "--dropbox-app-key",
        default=os.getenv("DROPBOX_APP_KEY", ""),
        help="Dropbox app key for refresh token flow. If omitted, uses DROPBOX_APP_KEY env var.",
    )
    parser.add_argument(
        "--dropbox-app-secret",
        default=os.getenv("DROPBOX_APP_SECRET", ""),
        help="Dropbox app secret for refresh token flow. If omitted, uses DROPBOX_APP_SECRET env var.",
    )
    parser.add_argument(
        "--dropbox-refresh-token",
        default=os.getenv("DROPBOX_REFRESH_TOKEN", ""),
        help="Dropbox refresh token. If set with app key/secret, access token is auto-refreshed.",
    )
    parser.add_argument(
        "--dropbox-folder",
        required=True,
        help="Dropbox folder path containing PDFs, e.g. /documents",
    )
    parser.add_argument(
        "--credentials",
        default="credentials.json",
        help="Path to Google credentials.json file.",
    )
    parser.add_argument(
        "--sheet-title",
        default="PDF Extract Results",
        help="Title of the Google Sheet to create.",
    )
    parser.add_argument(
        "--mode",
        choices=["tables", "text", "both"],
        default="tables",
        help="Extraction mode: 'tables' (structured), 'text' (line-by-line), or 'both'.",
    )
    parser.add_argument(
        "--no-recursive",
        action="store_true",
        help="Disable recursive search in child folders (default: recursive enabled).",
    )
    parser.add_argument(
        "--output-sheet",
        default="ExtractedTables",
        help="Output sheet name for aggregated table rows.",
    )
    parser.add_argument(
        "--max-pdfs",
        type=int,
        default=0,
        help="Limit number of PDFs to process (0 means no limit).",
    )
    parser.add_argument(
        "--name-contains",
        default="見積",
        help="Only process PDFs whose file name contains this keyword (default: 見積).",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=14,
        help="Only process PDFs whose 'お引渡し日' is within the next N days from today (default: 14). 0 means no filter.",
    )
    parser.add_argument(
        "--merge-same-title",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Merge PDFs with the same title into a single output row (default: enabled).",
    )
    parser.add_argument(
        "--merge-by",
        choices=["title", "filename"],
        default="title",
        help="Merge key when --merge-same-title is enabled: title(stem) or filename(with extension).",
    )
    return parser.parse_args()


def main() -> int:
    configure_console_output()
    args = parse_args()

    try:
        dropbox_token, token_source = resolve_dropbox_access_token(args)
    except Exception as exc:
        print(f"Failed to refresh Dropbox access token: {exc}", file=sys.stderr)
        return 1

    if not dropbox_token:
        print(
            "Dropbox token is missing. Set --dropbox-token or configure --dropbox-refresh-token with app key/secret.",
            file=sys.stderr,
        )
        return 1

    if token_source == "refresh_token":
        print("Using Dropbox access token generated from refresh token.")

    if not Path(args.credentials).exists():
        print(
            f"Google credentials file not found: {args.credentials}",
            file=sys.stderr,
        )
        print(
            "Please download credentials.json from Google Cloud Console.",
            file=sys.stderr,
        )
        return 1

    try:
        recursive = not args.no_recursive
        print(f"Listing PDFs in Dropbox folder: {args.dropbox_folder} (recursive={recursive})")
        pdf_entries = list_dropbox_pdfs(dropbox_token, args.dropbox_folder, recursive=recursive)

        keyword = args.name_contains.strip()
        if keyword:
            pdf_entries = [e for e in pdf_entries if keyword in Path(e.path_display).name]
            print(f"Filtered by name keyword '{keyword}': {len(pdf_entries)} PDF(s)")

        if args.days and args.days > 0:
            today = datetime.now().date()
            end_date_exclusive = today + timedelta(days=args.days)
            filtered_entries: list[dropbox.files.FileMetadata] = []
            pdf_bytes_cache: dict[str, bytes] = {}

            for entry in pdf_entries:
                try:
                    pdf_bytes = download_pdf_bytes(dropbox_token, entry.path_display)
                    pdf_bytes_cache[entry.path_display] = pdf_bytes
                    delivery_date = extract_delivery_date_from_pdf(pdf_bytes, today)
                    if delivery_date and today <= delivery_date < end_date_exclusive:
                        filtered_entries.append(entry)
                except Exception as exc:
                    print(f"  - Date filter skip ({entry.path_display}): {exc}")

            pdf_entries = filtered_entries
            print(
                f"Filtered by delivery date 'お引渡し日' (today to next {args.days} days): {len(pdf_entries)} PDF(s)"
            )
        else:
            pdf_bytes_cache = {}

        if args.max_pdfs and args.max_pdfs > 0:
            pdf_entries = pdf_entries[: args.max_pdfs]
        pdf_paths = [e.path_display for e in pdf_entries]
        print(f"Found {len(pdf_paths)} PDF(s)")

        if not pdf_paths:
            print("No PDFs found in the folder.", file=sys.stderr)
            return 1

    except Exception as exc:
        print(f"Failed to list Dropbox folder: {exc}", file=sys.stderr)
        return 1

    try:
        print("Authenticating with Google Sheets...")
        google_service = authenticate_google_sheets(args.credentials)
        spreadsheet_id = create_google_sheet(google_service, args.sheet_title)
        print(f"Created Google Sheet: {spreadsheet_id}")

    except Exception as exc:
        print(f"Failed to authenticate with Google Sheets: {exc}", file=sys.stderr)
        return 1

    title_aggregates: dict[str, dict] = {}

    for pdf_idx, pdf_path in enumerate(pdf_paths, start=1):
        print(f"\n[{pdf_idx}/{len(pdf_paths)}] Processing: {pdf_path}")

        try:
            pdf_bytes = pdf_bytes_cache.get(pdf_path)
            if pdf_bytes is None:
                pdf_bytes = download_pdf_bytes(dropbox_token, pdf_path)
            pdf_name = Path(pdf_path).stem

            if args.mode in ["tables", "both"]:
                print("  Extracting tables...")
                tables = extract_tables_from_pdf(pdf_bytes)
                if args.merge_same_title:
                    summary = build_raw_table_text(tables)
                    merge_key = (
                        Path(pdf_path).name if args.merge_by == "filename" else Path(pdf_path).stem
                    )
                    aggregate = title_aggregates.setdefault(
                        merge_key,
                        {
                            "title": merge_key,
                            "paths": set(),
                            "summaries": [],
                        },
                    )
                    aggregate["paths"].add(pdf_path)
                    if summary:
                        aggregate["summaries"].append(summary)
                    print(f"    ✓ Aggregated {args.merge_by} '{merge_key}'")
                else:
                    flat_rows = build_flat_table_rows(pdf_path, tables)
                    if flat_rows:
                        try:
                            append_table_to_sheet(
                                google_service,
                                spreadsheet_id,
                                args.output_sheet,
                                flat_rows,
                            )
                            print(f"    ✓ {len(flat_rows)} rows added to sheet '{args.output_sheet}'")
                        except Exception as exc:
                            print(f"    ✗ Failed to add table rows: {exc}")
                    else:
                        print("    - No table rows extracted")

            if args.mode in ["text", "both"]:
                print("  Extracting text...")
                pages = extract_text_lines_from_pdf(pdf_bytes)
                for page in pages:
                    sheet_name = f"{pdf_name}_P{page['page']}"
                    text_data = [[line] for line in page["lines"]]
                    try:
                        append_table_to_sheet(google_service, spreadsheet_id, sheet_name, text_data)
                        print(
                            f"    ✓ Page {page['page']} text added to sheet '{sheet_name}'"
                        )
                    except Exception as exc:
                        print(f"    ✗ Failed to add page {page['page']} text: {exc}")

        except Exception as exc:
            print(f"  ✗ Failed to process PDF: {exc}", file=sys.stderr)
            continue

    if args.mode in ["tables", "both"] and args.merge_same_title:
        merged_rows = [["title", "summary"]]
        for title in sorted(title_aggregates.keys()):
            aggregate = title_aggregates[title]
            summaries = [s for s in aggregate["summaries"] if s]
            merged_rows.append(
                [
                    "\n".join(sorted(aggregate["paths"])),
                    "\n\n".join(summaries),
                ]
            )
        append_table_to_sheet(google_service, spreadsheet_id, args.output_sheet, merged_rows)
        print(f"Merged by {args.merge_by} rows: {len(merged_rows) - 1}")

    print(f"\n✓ Complete! View your results: https://docs.google.com/spreadsheets/d/{spreadsheet_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
