<#
  Downloads the raw dataset. Run once, from the repository root:
      powershell -ExecutionPolicy Bypass -File .\data\download_data.ps1

  Source : Brazilian E-Commerce Public Dataset by Olist
  Licence: CC BY-NC-SA 4.0
  Origin : https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

  The CSVs are ~63 MB and are intentionally NOT committed (see .gitignore) so
  the repository stays cloneable in seconds. This script restores them exactly.
#>
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dest = Join-Path $PSScriptRoot "raw"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$base  = "https://raw.githubusercontent.com/spdrio/Brazilian-E-Commerce-Public-Dataset-by-Olist/master/files/"
$files = @(
    "olist_orders_dataset.csv"
    "olist_order_items_dataset.csv"
    "olist_order_payments_dataset.csv"
    "olist_order_reviews_dataset.csv"
    "olist_products_dataset.csv"
    "olist_customers_dataset.csv"
    "olist_sellers_dataset.csv"
    "product_category_name_translation.csv"
)

$wc = New-Object System.Net.WebClient
foreach ($f in $files) {
    $out = Join-Path $dest $f
    Write-Host ("  downloading {0} ..." -f $f) -NoNewline
    $wc.DownloadFile($base + $f, $out)
    Write-Host (" {0:N0} KB" -f ((Get-Item $out).Length / 1KB))
}
$wc.Dispose()

Write-Host ""
Write-Host "Raw data ready. Next: .\run_pipeline.ps1" -ForegroundColor Green
