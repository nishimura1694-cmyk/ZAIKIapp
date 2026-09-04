# 毎日10時のタスクスケジューラから呼び出され、Dropboxデスクトップアプリの同期フォルダ
# （既定パスは fetch_estimate_data.py の --local-root 既定値）から見積データ抽出.xlsxを
# 読み込んで assets/data/estimate_YYYY_MM.json / index.json を更新するラッパー。
# Dropbox APIトークンは不要（ローカル同期フォルダを直接読むため）。

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$logFile = Join-Path $logDir ("fetch_estimate_data_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

Set-Location $repoRoot

python "scripts\fetch_estimate_data.py" *>&1 | Tee-Object -FilePath $logFile
$fetchExitCode = $LASTEXITCODE

$changed = git status --porcelain -- assets/data
if ($changed) {
    "assets/data changed, committing locally" | Tee-Object -FilePath $logFile -Append
    git add assets/data | Out-Null
    $commitMessage = "Auto-update estimate data ({0:yyyy-MM-dd})" -f (Get-Date)
    git commit -m $commitMessage *>&1 | Tee-Object -FilePath $logFile -Append | Out-Null
} else {
    "assets/data unchanged, skipping commit" | Tee-Object -FilePath $logFile -Append
}

exit $fetchExitCode
