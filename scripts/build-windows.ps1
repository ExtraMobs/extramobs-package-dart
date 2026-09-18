param(
    [string]$Src,
    [string]$Out,
    [Parameter(Mandatory)][string]$OpenSSLRoot,
    [ValidateSet('x64','ARM64')][string]$Arch = 'x64'
)

$ErrorActionPreference = 'Stop'
# Absolute paths
$src = (Resolve-Path $Src).Path
# Ensure output directory exists before resolving path
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$out = (Resolve-Path $Out).Path
$bld = Join-Path $out "build"

# Prepare directories
New-Item -ItemType Directory -Force -Path $bld | Out-Null
Push-Location $bld

# Configure with CMake (MSVC) and enable MSDBLIB semantics
cmake $src -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release -DENABLE_MSDBLIB=ON -A $Arch "-DOPENSSL_ROOT_DIR=$OpenSSLRoot" -DOPENSSL_USE_STATIC_LIBS=TRUE -DWITH_OPENSSL=ON
if ($LASTEXITCODE -ne 0) { throw 'FreeTDS configuration failed' }
if (-not (Select-String -LiteralPath (Join-Path $bld 'include/config.h') -SimpleMatch '#define HAVE_OPENSSL 1' -Quiet)) { throw 'TLS support was not enabled' }

# Build
cmake --build . --config Release --target sybdb
if ($LASTEXITCODE -ne 0) { throw 'FreeTDS build failed' }

Pop-Location

# Collect DLL + LIB outputs
$binDir = Join-Path $out "bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Get-ChildItem -Recurse $bld -Include *.dll,*.lib -File | Copy-Item -Destination $binDir
