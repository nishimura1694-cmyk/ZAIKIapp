# Dropbox PDF to Google Sheets Extractor

DropboxのPDFからテーブル・テキストを抽出して、Google Sheetsに自動出力するツールです。複数のPDFを一括処理できます。

## セットアップ手順

### 1. 依存関係のインストール

```bash
cd scripts
pip install -r requirements-pdf-extract.txt
```

### 2. Google Cloud 認証設定

#### 2.1 Google Cloud プロジェクトの作成

1. [Google Cloud Console](https://console.cloud.google.com/) にアクセス
2. 新しいプロジェクトを作成
3. プロジェクトを選択

#### 2.2 Google Sheets API の有効化

1. コンソール左上の「APIとサービス」をクリック
2. 「+APIとサービスを有効にする」をクリック
3. 検索欄で「Google Sheets API」を検索
4. クリックして有効化する
5. 同様に「Google Drive API」も有効化

#### 2.3 認証情報の作成

1. 「APIとサービス」 → 「認証情報」をクリック
2. 「+ 認証情報を作成」 → 「OAuth クライアント ID」
3. アプリケーションの種類: 「デスクトップアプリ」を選択
4. 作成後、ダウンロードボタンをクリック
5. ダウンロードしたファイルを `scripts/credentials.json` に保存
   - ブラウザのダウンロード フォルダにダウンロードされます（ファイル名は `client_secret_xxxxx.json` など）
   - このファイルを右クリック → 「コピー」
   - エクスプローラーで `zaiki_app/scripts/` フォルダを開く
   - 空白エリアで右クリック → 「貼り付け」
   - 貼り付けたファイルを右クリック → 「名前変更」
   - ファイル名を `credentials.json` に変更

### 3. Dropbox アクセストークンの取得

1. [Dropbox Developers](https://www.dropbox.com/developers/apps) にアクセス
2. 「Create App」をクリック
3. API選択: 「Scoped access」
4. アクセスレベル: 「App folder」または「Full Dropbox」
5. アプリ名を入力して作成
6. 「Permissions」タブで以下をチェック:
   - `files.metadata.read`
   - `files.content.read`
7. 「Generate」をクリックしてアクセストークンを生成
8. トークンをコピー

## 使い方

### 基本的な使用方法

```bash
python dropbox_pdf_to_gsheets.py \
  --dropbox-token "YOUR_DROPBOX_TOKEN" \
  --dropbox-folder "/Documents/PDFs" \
  --credentials credentials.json \
  --sheet-title "My PDF Extract"
```

### コマンドラインオプション

- `--dropbox-token`: Dropboxアクセストークン（環境変数 `DROPBOX_ACCESS_TOKEN` でも指定可）
- `--dropbox-folder`: **必須** PDFを含むDropboxフォルダパス（例：`/documents`）
- `--credentials`: Google認証情報ファイルのパス（デフォルト: `credentials.json`）
- `--sheet-title`: 作成するGoogle Sheetのタイトル
- `--mode`: 抽出モード
  - `tables`: 表データのみ抽出（デフォルト）
  - `text`: 全テキスト行を抽出
  - `both`: 両方抽出

### 環境変数での設定

Dropboxトークンを環境変数に設定すれば、コマンドラインで毎回指定する必要がありません：

#### Windows (PowerShell)

```powershell
$env:DROPBOX_ACCESS_TOKEN = "YOUR_DROPBOX_TOKEN"
```

#### Windows (Command Prompt)

```cmd
set DROPBOX_ACCESS_TOKEN=YOUR_DROPBOX_TOKEN
```

#### macOS / Linux

```bash
export DROPBOX_ACCESS_TOKEN="YOUR_DROPBOX_TOKEN"
```

その後は簡潔に実行できます：

```bash
python dropbox_pdf_to_gsheets.py \
  --dropbox-folder "/Documents/PDFs" \
  --sheet-title "My PDF Extract"
```

## 実行例

### 例1: 表データのみを抽出

```bash
python dropbox_pdf_to_gsheets.py \
  --dropbox-folder "/MyPDFs" \
  --sheet-title "Tables from PDFs" \
  --mode tables
```

### 例2: 全テキストを抽出

```bash
python dropbox_pdf_to_gsheets.py \
  --dropbox-folder "/MyPDFs" \
  --sheet-title "Text from PDFs" \
  --mode text
```

### 例3: 表とテキストの両方を抽出

```bash
python dropbox_pdf_to_gsheets.py \
  --dropbox-folder "/MyPDFs" \
  --sheet-title "Full Extract" \
  --mode both
```

## 出力フォーマット

### 表モード (`tables`)

- 各PDFの各テーブルが別のシートに出力される
- シート名: `{PDF名}_T{テーブル番号}` （例: `invoice_T1`, `invoice_T2`）
- 最初の行がヘッダー、以降がデータ行

### テキストモード (`text`)

- 各PDFの各ページが別のシートに出力される
- シート名: `{PDF名}_P{ページ番号}` （例: `report_P1`, `report_P2`）
- 各行が1セルに出力される

## トラブルシューティング

### 認証エラーが出る

- `credentials.json` が正しい場所にあるか確認
- 初回実行時はブラウザで認証を行う必要があります

### PDFが見つからない

- Dropboxフォルダパスが正しいか確認
  - パスは必ず `/` で始まる必要があります
  - 例：正しい: `/Documents/PDFs`、間違い: `Documents/PDFs`

### Google Sheetsへのアクセス権がない

- Dropboxトークンが正しいか確認
- 必要なパーミッションが有効になっているか確認

## 既存スクリプト

- `dropbox_pdf_to_json.py`: PDFをJSON形式で出力（従来の方法）
  - 使用方法：
    ```bash
    python dropbox_pdf_to_json.py \
      --dropbox-path "/Documents/sample.pdf" \
      --output output/pdf_text.json
    ```

## サポート

エラーや問題が発生した場合は、ターミナルの出力メッセージを確認してください。
