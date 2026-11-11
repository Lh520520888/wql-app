param(
    [Parameter(Mandatory = $true)]
    [string]$RepoUrl
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "==> 目录: $PSScriptRoot"

if (-not (Test-Path ".git")) {
    Write-Host "==> git init"
    git init -b main | Out-Null
}

Write-Host "==> 暂存文件"
git add .

Write-Host "==> 提交"
git -c user.name="wql" -c user.email="wql@local" commit -m "wql_app: build via GitHub Actions" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "    （没有新改动，跳过提交）" }

Write-Host "==> 配置远程"
git remote remove origin 2>$null
git remote add origin $RepoUrl
git branch -M main

Write-Host "==> 推送"
git push -u origin main

Write-Host ""
Write-Host "完成。打开 $RepoUrl/actions 点 Run workflow，等待产物 WQLApp-ipa。"