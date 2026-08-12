param(
  [int]$ParentId,
  [string]$Source,
  [string]$Destination,
  [string]$ScriptPath
)

$exitCode = 1

try {
  Wait-Process -Id $ParentId -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 50; $i++) {
    try {
      [System.IO.File]::Replace($Source, $Destination, $null, $true)
      $exitCode = 0
      break
    } catch {
      Start-Sleep -Milliseconds 100
    }
  }
} finally {
  # ReplaceFile can fail with the destination already unlinked, leaving the
  # verified download at $Source. Installing it beats leaving nothing.
  if (-not (Test-Path -LiteralPath $Destination)) {
    Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
}

exit $exitCode
