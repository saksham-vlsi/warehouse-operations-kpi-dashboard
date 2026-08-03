<#
  Warehouse Operations KPI Dashboard -- end-to-end pipeline.

      .\run_pipeline.ps1

  Steps:  build star schema  ->  data-quality gate  ->  publish KPI marts
  Output: outputs\*.csv  (consumed by Power BI, Excel and dashboard\index.html)

  The pipeline is idempotent -- rerun it any time; it rebuilds from data\raw.
#>
param(
    [switch]$SkipDownload,
    [string]$DuckDb = ".\tools\duckdb.exe"
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# ---- 0. dependencies --------------------------------------------------------
if (-not (Test-Path $DuckDb)) {
    Write-Host "DuckDB CLI not found - fetching portable binary..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path ".\tools" | Out-Null
    (New-Object System.Net.WebClient).DownloadFile(
        "https://github.com/duckdb/duckdb/releases/download/v1.5.5/duckdb_cli-windows-amd64.zip",
        ".\tools\duckdb.zip")
    Expand-Archive ".\tools\duckdb.zip" -DestinationPath ".\tools" -Force
    Remove-Item ".\tools\duckdb.zip" -Force
}

if (-not $SkipDownload -and -not (Test-Path ".\data\raw\olist_orders_dataset.csv")) {
    Write-Host "Raw data missing - downloading..." -ForegroundColor Yellow
    & powershell -ExecutionPolicy Bypass -File ".\data\download_data.ps1"
}

New-Item -ItemType Directory -Force -Path ".\outputs" | Out-Null
$db = ".\outputs\warehouse.duckdb"
if (Test-Path $db) { Remove-Item $db -Force }

# ---- 1..3 -------------------------------------------------------------------
$steps = @(
    @{ n = "1/3  Building star schema";    f = "sql/01_build_model.sql"  },
    @{ n = "2/3  Data-quality gate";       f = "sql/02_data_quality.sql" },
    @{ n = "3/3  Publishing KPI marts";    f = "sql/03_kpi_marts.sql"    }
)
foreach ($s in $steps) {
    Write-Host ""
    Write-Host ("[{0}]" -f $s.n) -ForegroundColor Cyan
    & $DuckDb $db -c (".read {0}" -f $s.f)
    if ($LASTEXITCODE -ne 0) { throw "FAILED: $($s.f)" }
}

Write-Host ""
Write-Host "Pipeline complete. Published marts:" -ForegroundColor Green
Get-ChildItem ".\outputs" -Filter *.csv | Sort-Object Name |
    ForEach-Object { "   {0,-36} {1,9:N0} KB" -f $_.Name, ($_.Length / 1KB) }
Write-Host ""
Write-Host "Open dashboard\index.html for the executive view." -ForegroundColor Green
