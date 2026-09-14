param([Parameter(Mandatory)][string]$Out, [ValidateSet('x64','ARM64')][string]$Arch = 'x64')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$buildRoot = (Resolve-Path -LiteralPath $Out).Path
$source = & python (Join-Path $PSScriptRoot 'fetch-openssl.py') (Join-Path $buildRoot 'source')
if ($LASTEXITCODE -ne 0) { throw 'OpenSSL source verification failed' }
$target = if ($Arch -eq 'ARM64') { 'VC-WIN64-ARM' } else { 'VC-WIN64A' }
Push-Location -LiteralPath $source
try {
    & perl Configure $target no-shared no-tests no-asm --libdir=lib "--prefix=$buildRoot/prefix"
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSL configuration failed' }
    # Embed debug information in objects; avoid a shared compiler PDB lock.
    $makefile = Join-Path $source 'makefile'
    $contents = [IO.File]::ReadAllText($makefile).Replace('/Zi', '/Z7')
    # /Z7 embeds symbols in objects, so there is no standalone PDB to install.
    $contents = $contents.Replace(' "$(PERL)" "$(SRCDIR)\util\copy.pl" ossl_static.pdb', ' if exist ossl_static.pdb "$(PERL)" "$(SRCDIR)\util\copy.pl" ossl_static.pdb')
    [IO.File]::WriteAllText($makefile, $contents)
    & nmake /NOLOGO
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSL build failed' }
    & nmake /NOLOGO install_sw
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSL installation failed' }
} finally { Pop-Location }
