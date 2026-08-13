param(
  [int]$ParentId,
  [string]$Source,
  [string]$Destination,
  [string]$ScriptPath
)

function Resolve-FullPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return (Join-Path -Path $PWD.ProviderPath -ChildPath $Path)
}

$Source = Resolve-FullPath $Source
$Destination = Resolve-FullPath $Destination
$ScriptPath = Resolve-FullPath $ScriptPath

$exitCode = 1
$lastError = $null

try {
  Wait-Process -Id $ParentId -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 50; $i++) {
    try {
      [System.IO.File]::Replace($Source, $Destination, [NullString]::Value, $true)
      $exitCode = 0
      break
    } catch {
      $lastError = $_
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

if ($exitCode -ne 0 -and $null -ne $lastError) {
  [Console]::Error.WriteLine("failed to replace ${Destination} with ${Source}: $lastError")
}

exit $exitCode
