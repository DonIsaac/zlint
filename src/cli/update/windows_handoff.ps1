param(
  [int]$ParentId,
  [string]$Source,
  [string]$Destination,
  [string]$ScriptPath
)

$backup = "$Source.bak"
$exitCode = 1

try {
  Wait-Process -Id $ParentId -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 50; $i++) {
    try {
      [System.IO.File]::Replace($Source, $Destination, $backup, $true)
      $exitCode = 0
      break
    } catch {
      Start-Sleep -Milliseconds 100
    }
  }
} finally {
  if ($exitCode -eq 0) {
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
  } else {
    if ((-not (Test-Path -LiteralPath $Destination)) -and (Test-Path -LiteralPath $backup)) {
      Move-Item -LiteralPath $backup -Destination $Destination -Force
    }
    Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
}

exit $exitCode
