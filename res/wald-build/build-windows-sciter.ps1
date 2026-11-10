# Waldlust (wald-remote-client) Windows 32-bit (i686) legacy Sciter UI build -> portable folder (+ optional x86 Inno installer).
# Reproduces upstream rustdesk CI job 'build-for-windows-sciter' (.github/workflows/flutter-build.yml) on a Windows x64 host.
# Spec DSK-07 '32-bit Windows (Sciter) incoming-only', appendix A-19. The 32-bit target is incoming-only (F-50).
#
# Usage:  powershell -ExecutionPolicy Bypass -File <wald-remote-docs>\wald-build\build-windows-sciter.ps1 [-Ref <commit|branch>]
#         [-Variant incoming|bidirectional] [-Target dummy|mock|release] [-Inno] [-Brand <alias>]
#         (default ref: feat/dsk-07-win32-sciter, default variant: incoming, default target: mock)
# Result: C:\wald-build\waldlust-<ver>-windows-x86-sciter[-incoming]-<target>\ (wald-remote.exe + sciter.dll, unsigned)
#         With -Inno also C:\wald-build\dist\<ver>-<sha>-<target>\waldlust-remote[-incoming]-<ver>-windows-x86[-<target>].exe + manifest
#         (installer name rule - decision D36: no -<target> for release, e.g. waldlust-remote-incoming-1.5.0-windows-x86.exe)
# Logs:   C:\wald-build\logs\sciter-x86-*.log
#
# Rules (same as build-windows-local.ps1)
# - Unmanaged build: WALDLUST_PRESET_PASSWORD is removed. Heartbeat is compiled in as dummy (127.0.0.1:9) or mock
#   (127.0.0.1:8787 + WALDLUST_API_SERVER=http://127.0.0.1:8787/rd). Only release talks to the production admin.
# - release: official build (plan ADMIN_LOCAL_PLAN 4-1, decisions D33-D35 - 2026-10-14). heartbeat
#   https://remote.waldpay.co.kr/api/heartbeat + WALDLUST_API_SERVER=https://remote.waldpay.co.kr/rd (same as the x64 release).
#   -Ref must be a wald-v* tag pushed to origin (WALDLUST-COM), -Inno and -Variant incoming are required, and only
#   -IncomingEnv C:\wald-build\incoming-prod.env is accepted. NOTICE.txt, LICENCE.txt and THIRD_PARTY_NOTICES.txt
#   (res\wald-build\collect-notices.py --platform windows-x86: Sciter notice included) go into the installer payload
#   and dist. Unsigned (D34). Needs cargo-about 0.6.4 (cargo install cargo-about --version 0.6.4 --locked).
# - Incoming-only: test password from C:\wald-build\incoming-test.env is hashed with preset_hash.py; only the hash goes in.
#   The binary is checked: hash present, plain password absent. Values are never printed (fingerprint only).
# - Brand-only build (DSK-01, decision D53): -Brand <alias> reads C:\wald-build\brand-<alias>.env (outside git):
#     WALDLUST_BRAND=<code issued by the admin: 8-12 lowercase letters and digits>
#     WALDLUST_INCOMING_PASSWORD=..., WALDLUST_INCOMING_SALT=...   (incoming-only: the brand's own password, required)
#   The code goes into the build (login, heartbeat, update check); the server narrows the scope with it. Output names get
#   -<code> (portable folder, installer, manifest-<variant>-<code>.txt with a 'brand:' line). After the build the script
#   looks for the mark wald-brand-build:<code> in the binary (wald-brand-build:none for a general build).
#   Without -Brand, WALDLUST_BRAND is removed from the environment - a value left in the shell cannot leak into a general build.
# - Fresh detached worktree wt-sciter-build; cargo target C:\wald-build\target-sciter-x86 (outside the worktree).
#   The sciter-rs switch to branch dyn_x86 (Cargo.toml/Cargo.lock) happens only in that worktree, never committed.
#
# Prerequisites (once, under C:\wald-build unless noted):
#   rustup toolchain nightly-2023-10-13-i686-pc-windows-msvc (+rustfmt, --force-non-host; sciter-rs dyn_x86 needs abi_thiscall),
#   tools\llvm-x86 = LLVM 15.0.6 win32 (7-Zip extracted; build scripts run as i686 and need a 32-bit libclang),
#   vcpkg-x86 = microsoft/vcpkg 120deac (separate root: one manifest install root per tree), x86-windows-static installed
#   (host triplet x86-windows-static, as CI), dl\sciter\x32\sciter.dll (c-smile/sciter-sdk f33df075, sha256 below),
#   Visual Studio 2022 MSVC x86 tools, tools\python, tools\inno (ISCC 6).
param(
  [string]$Ref = 'feat/dsk-07-win32-sciter',
  [string]$Client = (Join-Path $env:USERPROFILE 'Documents\GitHub\wald-remote-client'),
  [string]$Out = 'C:\wald-build',
  [ValidateSet('bidirectional', 'incoming')][string]$Variant = 'incoming',
  [ValidateSet('dummy', 'mock', 'release')][string]$Target = 'mock',
  [switch]$Inno,
  [string]$IncomingEnv = 'C:\wald-build\incoming-test.env',
  [string]$Brand = '',      # brand-only build: alias of C:\wald-build\brand-<alias>.env
  [string]$BrandEnv = ''    # default: <Out>\brand-<alias>.env
)
$Suffix = if ($Variant -eq 'incoming') { '-incoming' } else { '' }
$Prod = ($Target -eq 'release')  # built against the production server
$ErrorActionPreference = 'Continue'  # native tools write progress to stderr; exit codes are checked instead
$W = Join-Path $Out 'wt-sciter-build'
$T = Join-Path $Out 'target-sciter-x86'
$LOG = Join-Path $Out 'logs'
$Tools = Join-Path $Out 'tools'
$SciterDll = Join-Path $Out 'dl\sciter\x32\sciter.dll'
$SciterSha = '285f3e6a051a7c61845cd7e4d2120781b6bdf411239f70a85c65b38a52d38f28'
$SciterRsX86 = '674e07d3066ca9a92ced3816203ab6b652629d1e'  # rustdesk-org/rust-sciter dyn_x86 (pinned like upstream CI)
New-Item -ItemType Directory -Force $LOG, $T | Out-Null

$env:PATH = "$env:USERPROFILE\.cargo\bin;$Tools\python;$Tools\python\Scripts;$Tools\llvm-x86\bin;$env:PATH"
$env:RUSTUP_TOOLCHAIN = 'nightly-2023-10-13-i686-pc-windows-msvc'
$env:VCPKG_ROOT = Join-Path $Out 'vcpkg-x86'
$env:VCPKG_DEFAULT_HOST_TRIPLET = 'x86-windows-static'
$env:VCPKG_DISABLE_METRICS = '1'
$env:VCPKG_DOWNLOADS = Join-Path $Out 'vcpkg\downloads'
$env:LIBCLANG_PATH = "$Tools\llvm-x86\bin"
$env:CARGO_TARGET_DIR = $T
$env:PYTHONUTF8 = '1'
$env:WALDLUST_HEARTBEAT_URL = 'http://127.0.0.1:9/api/heartbeat'
Remove-Item Env:WALDLUST_API_SERVER -ErrorAction SilentlyContinue
if ($Target -eq 'mock') {
  $env:WALDLUST_HEARTBEAT_URL = 'http://127.0.0.1:8787/api/heartbeat'
  $env:WALDLUST_API_SERVER = 'http://127.0.0.1:8787/rd'
}
if ($Prod) {
  $env:WALDLUST_HEARTBEAT_URL = 'https://remote.waldpay.co.kr/api/heartbeat'
  $env:WALDLUST_API_SERVER = 'https://remote.waldpay.co.kr/rd'
}
Remove-Item Env:WALDLUST_PRESET_PASSWORD -ErrorAction SilentlyContinue
foreach ($k in 'WALDLUST_VARIANT', 'WALDLUST_INCOMING_PW_STORAGE', 'WALDLUST_INCOMING_PW_SALT', 'WALDLUST_INCOMING_PASSWORD', 'WALDLUST_INCOMING_SALT', 'WALDLUST_BRAND', 'WALDLUST_BRAND_NAME') {
  Remove-Item "Env:$k" -ErrorAction SilentlyContinue
}

function Step([string]$Name) { Write-Output "== $Name $(Get-Date -Format HH:mm:ss)" }
function Die([string]$Msg) { Write-Output "FAIL: $Msg (logs: $LOG)"; exit 1 }
function Run([string]$Name, [string]$Cmd) {
  cmd /c "$Cmd >> `"$LOG\sciter-x86-$Name.log`" 2>&1"
  if ($LASTEXITCODE -ne 0) { Die "$Name (exit $LASTEXITCODE)" }
}

foreach ($p in "$Tools\llvm-x86\bin\libclang.dll", (Join-Path $env:VCPKG_ROOT 'installed\x86-windows-static'), $SciterDll) {
  if (-not (Test-Path -LiteralPath $p)) { Die "missing prerequisite: $p" }
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $SciterDll).Hash.ToLower() -ne $SciterSha) { Die "unexpected $SciterDll" }
# release: a wald-v* tag that exists on origin with the same commit, -Inno, incoming-only, the production password, cargo-about.
# Brand-only build (DSK-01, decision D53). See the header. Values are never printed (the code is not a secret, the password is).
$Code = ''
if ($Brand) {
  if ($Brand -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { Die "-Brand takes an alias made of letters, digits, - and _" }
  if (-not $BrandEnv) { $BrandEnv = Join-Path $Out "brand-$Brand.env" }
  if (-not (Test-Path -LiteralPath $BrandEnv)) { Die "$BrandEnv not found (WALDLUST_BRAND=<code>; incoming-only also WALDLUST_INCOMING_PASSWORD, WALDLUST_INCOMING_SALT)" }
  $brandVals = @{}
  # UTF-8: the display name (WALDLUST_BRAND_NAME) may be non-ASCII; PowerShell 5.1 reads ANSI by default.
  foreach ($line in Get-Content -LiteralPath $BrandEnv -Encoding UTF8) {
    if ($line -match '^\s*(WALDLUST_BRAND|WALDLUST_BRAND_NAME|WALDLUST_INCOMING_PASSWORD|WALDLUST_INCOMING_SALT)=(.*)$') { $brandVals[$Matches[1]] = $Matches[2] }
  }
  $Code = "$($brandVals['WALDLUST_BRAND'])".Trim()
  if ($Code -cnotmatch '^[a-z0-9]{8,12}$') { Die "${BrandEnv}: WALDLUST_BRAND must be 8-12 lowercase letters and digits" }
  if ($Variant -eq 'incoming') {
    # The brand's own password is required: a brand build must never fall back to the shared password files.
    if (-not $brandVals['WALDLUST_INCOMING_PASSWORD'] -or -not $brandVals['WALDLUST_INCOMING_SALT']) {
      Die "${BrandEnv}: WALDLUST_INCOMING_PASSWORD and WALDLUST_INCOMING_SALT are required for a brand incoming-only build"
    }
    foreach ($shared in 'incoming-prod.env', 'incoming-test.env') {
      $sharedFile = Join-Path $Out $shared
      if (Test-Path -LiteralPath $sharedFile) {
        foreach ($line in Get-Content -LiteralPath $sharedFile) {
          if ($line -match '^\s*WALDLUST_INCOMING_PASSWORD=(.*)$' -and $Matches[1] -ceq $brandVals['WALDLUST_INCOMING_PASSWORD']) {
            Die "${BrandEnv}: the brand password is the same as the shared one in $shared - use a different password"
          }
        }
      }
    }
    $IncomingEnv = $BrandEnv
  }
  # Optional display name shown in the app (info dialog; incoming-only home). build.rs checks the format (<= 30 chars).
  $BrandName = "$($brandVals['WALDLUST_BRAND_NAME'])".Trim()
  $brandVals = $null
  $env:WALDLUST_BRAND = $Code
  if ($BrandName) { $env:WALDLUST_BRAND_NAME = $BrandName }
  Write-Output "brand $Code, display name: $(if ($BrandName) { 'set' } else { 'none' })"
}
$BrandTag = if ($Code) { "-$Code" } else { '' }

$CargoAbout = Join-Path $env:USERPROFILE '.cargo\bin\cargo-about.exe'
if ($Target -eq 'release') {
  if ($Ref -notmatch '^wald-v\d+\.\d+\.\d+-r\d+$') { Die "release takes only a wald-v<ver>-r<N> tag (got $Ref)" }
  $rc = ((git -C $Client ls-remote origin "refs/tags/$Ref^{}") -split '\s+')[0]
  if (-not $rc) { $rc = ((git -C $Client ls-remote origin "refs/tags/$Ref") -split '\s+')[0] }
  $lc = git -C $Client rev-parse -q --verify "$Ref^{commit}"
  if (-not $rc -or $rc -ne $lc) { Die "tag $Ref is not on origin or differs from the local tag (origin '$rc', local '$lc') - git fetch --tags" }
  if (-not $Inno) { Die 'release needs -Inno' }
  if ($Variant -ne 'incoming') { Die 'the 32-bit release is incoming-only (F-50)' }
  if (-not $Code -and (Split-Path -Leaf $IncomingEnv) -ne 'incoming-prod.env') { Die 'release takes only -IncomingEnv C:\wald-build\incoming-prod.env' }
  if (-not (Test-Path -LiteralPath $CargoAbout)) { Die 'cargo-about not found (cargo install cargo-about --version 0.6.4 --locked)' }
}

# 0) Fresh worktree.
Step "worktree $Ref"
if (Test-Path -LiteralPath $W) {
  git -C $Client worktree remove --force $W
  if (Test-Path -LiteralPath $W) { Die "could not remove old worktree $W" }
}
git -C $Client worktree add --detach $W $Ref
if ($LASTEXITCODE -ne 0) { Die worktree }
if ($Code -and -not (Test-Path -LiteralPath (Join-Path $W 'src\wald_brand.rs'))) { Die "$Ref has no brand build support (src\wald_brand.rs)" }
if ($Target -eq 'release') {
  # The tag version (wald-v<ver>-r<N>) must be the source version (decision D36).
  $tagVer = ($Ref -replace '^wald-v', '') -replace '-r\d+$', ''
  $srcVer = ((Select-String -Path (Join-Path $W 'flutter\pubspec.yaml') -Pattern '^version:').Line -split '\s+')[1].Split('+')[0]
  $cargoVer = ((Select-String -Path (Join-Path $W 'Cargo.toml') -Pattern '^version\s*=' | Select-Object -First 1).Line -split '"')[1]
  if ($tagVer -ne $srcVer -or $tagVer -ne $cargoVer) { Die "tag version $tagVer differs from the source (pubspec $srcVer, Cargo.toml $cargoVer)" }
}
$want = (git -C $Client ls-tree $Ref libs/hbb_common) -split '\s+' | Select-Object -Index 2
$have = git -C (Join-Path $Client 'libs\hbb_common') rev-parse HEAD
if ($want -ne $have) { Die "hbb_common mismatch (ref $want, shared folder $have) - run git submodule update in $Client" }
robocopy (Join-Path $Client 'libs\hbb_common') (Join-Path $W 'libs\hbb_common') /E /XD .git /XF .git /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { Die "submodule copy" }
Get-ChildItem $LOG -Filter 'sciter-x86-*.log' | Remove-Item
Set-Location $W

# Incoming-only variant: hash the test password (plain values only live in this process until the binary check).
$Plain = $null
if ($Variant -eq 'incoming') {
  Step "variant incoming"
  if (-not (Test-Path -LiteralPath $IncomingEnv)) { Die "$IncomingEnv not found (WALDLUST_INCOMING_PASSWORD, WALDLUST_INCOMING_SALT)" }
  foreach ($line in Get-Content -LiteralPath $IncomingEnv) {
    if ($line -match '^\s*(WALDLUST_INCOMING_PASSWORD|WALDLUST_INCOMING_SALT)=(.*)$') {
      Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
    }
  }
  $Plain = $env:WALDLUST_INCOMING_PASSWORD
  $hashOut = python res\wald-variant\preset_hash.py
  $hashExit = $LASTEXITCODE
  Remove-Item Env:WALDLUST_INCOMING_PASSWORD, Env:WALDLUST_INCOMING_SALT -ErrorAction SilentlyContinue
  if ($hashExit -ne 0) { Die "password hash (preset_hash.py)" }
  foreach ($line in $hashOut) {
    $kv = $line.Split('=', 2)
    Set-Item -Path "Env:$($kv[0])" -Value $kv[1]
  }
  $env:WALDLUST_VARIANT = 'incoming'
  python res\wald-variant\apply_icons.py
  if ($LASTEXITCODE -ne 0) { Die "incoming icons (apply_icons.py)" }
  $h2 = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($env:WALDLUST_INCOMING_PW_STORAGE))
  $Fp = (($h2 | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 5)
  Write-Output "incoming password fingerprint $Fp ($IncomingEnv)"
}

# 1) Inline the Sciter UI (src/ui/*.html/css/tis -> src/ui/inline.rs) and switch sciter-rs to the x86 branch (worktree only).
Step "inline + sciter-rs dyn_x86"
Run inline "python res\inline-sciter.py"
$cargoToml = Join-Path $W 'Cargo.toml'
$toml = [System.IO.File]::ReadAllText($cargoToml)
if (-not $toml.Contains('branch = "dyn"')) { Die "sciter-rs branch = ""dyn"" not found in Cargo.toml" }
[System.IO.File]::WriteAllText($cargoToml, $toml.Replace('branch = "dyn"', 'branch = "dyn_x86"'))
Run sciter-rs "cargo update -p sciter-rs --precise $SciterRsX86"

# 2) Build (CI: cargo build --locked --features inline,vram,hwcodec --release --bins). The i686 host toolchain targets i686.
Step "cargo build release (target $T)"
Run cargo "cargo build --locked --features inline,vram,hwcodec --release --bin rustdesk"
$exe = Join-Path $T 'release\rustdesk.exe'
if (-not (Test-Path -LiteralPath $exe)) { Die "$exe not built" }

# 3) Verify: PE machine i386, heartbeat (mock/dummy >= 1, production 0), api-server, incoming hash 1 / plain 0, version info.
Step verify
$fs = [System.IO.File]::OpenRead($exe)
$br = New-Object System.IO.BinaryReader($fs)
$fs.Seek(0x3C, 'Begin') | Out-Null; $pe = $br.ReadInt32(); $fs.Seek($pe + 4, 'Begin') | Out-Null; $machine = $br.ReadUInt16()
$br.Close()
if ($machine -ne 0x14c) { Die ("PE machine 0x{0:x} is not i386" -f $machine) }
$hbNeedle = $env:WALDLUST_HEARTBEAT_URL -replace '^https?://', ''
$apiNeedle = '-'
if ($env:WALDLUST_API_SERVER) { $apiNeedle = $env:WALDLUST_API_SERVER.Trim().TrimEnd('/') -replace '^https?://', '' }
# The hash and the plain password go to python through the environment, never on a command line.
$env:WALD_NEEDLE_HASH = if ($env:WALDLUST_INCOMING_PW_STORAGE) { $env:WALDLUST_INCOMING_PW_STORAGE } else { '-' }
$env:WALD_NEEDLE_PLAIN = if ($Plain) { $Plain } else { '-' }
# Brand mark (DSK-01, decision D53): the binary must carry wald-brand-build:<code> for a brand build and
# wald-brand-build:none for a general one. Refs older than the brand support have no mark (general builds only).
$markNeedle = '-'
if (Test-Path -LiteralPath (Join-Path $W 'src\wald_brand.rs')) {
  $markNeedle = if ($Code) { "wald-brand-build:$Code" } else { 'wald-brand-build:none' }
}
$counts = python -c "import os,sys;d=open(sys.argv[1],'rb').read();n=sys.argv[2:]+[os.environ['WALD_NEEDLE_HASH'],os.environ['WALD_NEEDLE_PLAIN']];print(*[d.count(x.encode()) if x != '-' else -1 for x in n])" $exe $hbNeedle 'remote.waldpay.co.kr/api/heartbeat' $apiNeedle $markNeedle
Remove-Item Env:WALD_NEEDLE_HASH, Env:WALD_NEEDLE_PLAIN -ErrorAction SilentlyContinue
$Plain = $null
$hb, $prod, $api, $mark, $hash, $plainCount = $counts -split ' ' | ForEach-Object { [int]$_ }
$Check = "pe i386 / heartbeat $hbNeedle=$hb production=$prod / api-server $apiNeedle=$api / brand $markNeedle=$mark"
if ($Variant -eq 'incoming') { $Check += " / incoming hash=$hash plain=$plainCount" }
Write-Output $Check
if ($hb -lt 1 -or ($prod -ne 0 -and -not $Prod)) { Die "heartbeat address check failed - do not run this build" }
if ($apiNeedle -ne '-' -and $api -lt 1) { Die "api-server value is not in the build - do not run this build" }
if ($markNeedle -ne '-' -and $mark -lt 1) { Die "brand mark check failed ($markNeedle is not in the build) - do not run this build" }
if ($Variant -eq 'incoming' -and ($hash -lt 1 -or $plainCount -ne 0)) { Die "incoming password check failed (hash $hash, plain $plainCount) - do not run this build" }
$vi = (Get-Item -LiteralPath $exe).VersionInfo
Write-Output "version info: ProductName='$($vi.ProductName)' FileDescription='$($vi.FileDescription)' FileVersion='$($vi.FileVersion)'"

# 4) Portable folder: wald-remote.exe (the Inno script renames it to Waldlust.exe) + sciter.dll.
Step copy
$ver = ((Select-String -Path (Join-Path $W 'Cargo.toml') -Pattern '^version\s*=' | Select-Object -First 1).Line -split '"')[1]
$dest = Join-Path $Out "waldlust-$ver-windows-x86-sciter$Suffix$BrandTag-$Target"
if (Test-Path -LiteralPath $dest) { Remove-Item -Recurse -Force -LiteralPath $dest }
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item -LiteralPath $exe -Destination (Join-Path $dest 'wald-remote.exe')
Copy-Item -LiteralPath $SciterDll -Destination (Join-Path $dest 'sciter.dll')
Write-Output "done: $dest\wald-remote.exe"

# 5) Optional x86 Inno installer (same AppId as x64: installs to Program Files (x86)\Waldlust Remote on 64-bit Windows).
if ($Inno) {
  Step inno
  $iscc = @((Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'), (Join-Path $Tools 'inno\ISCC.exe')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $iscc) { Die "ISCC.exe not found (install Inno Setup 6 or put it in $Tools\inno)" }
  $issDir = Join-Path $W 'res\inno'
  Copy-Item -Recurse -LiteralPath $dest -Destination (Join-Path $issDir 'rustdesk')
  # release: open source notices (D35, Sciter notice included) go into the payload, so [Files] installs them.
  if ($Target -eq 'release') {
    Step notices
    $Notices = Join-Path $LOG 'THIRD_PARTY_NOTICES-windows-x86.txt'
    Run notices "cd /d `"$W`" && python res\wald-build\collect-notices.py --platform windows-x86 --out `"$Notices`" --release $Ref --vcpkg-share `"$env:VCPKG_ROOT\installed\x86-windows-static\share`" --cargo-about `"$CargoAbout`""
    $payload = Join-Path $issDir 'rustdesk'
    Copy-Item -LiteralPath (Join-Path $W 'NOTICE') -Destination (Join-Path $payload 'NOTICE.txt')
    Copy-Item -LiteralPath (Join-Path $W 'LICENCE') -Destination (Join-Path $payload 'LICENCE.txt')
    Copy-Item -LiteralPath $Notices -Destination (Join-Path $payload 'THIRD_PARTY_NOTICES.txt')
  }
  $defs = "/DMyAppVersion=$ver /DMyArch=x86"
  if ($Suffix) { $defs += " /DMyVariantSuffix=$Suffix" }
  Run inno "cd /d `"$issDir`" && `"$iscc`" $defs waldlust.iss"
  # Inno output: waldlust-remote[-incoming]-<ver>-windows-x86.exe (older tags: waldlust-setup-<ver>-x86[-incoming].exe).
  $setup = Get-ChildItem -LiteralPath $issDir -Recurse -Filter 'waldlust-*.exe' | Select-Object -First 1
  if (-not $setup) { Die "installer not found under $issDir" }
  $commit = git -C $W rev-parse HEAD
  $dist = Join-Path $Out "dist\$ver-$($commit.Substring(0, 9))-$Target"
  New-Item -ItemType Directory -Force $dist | Out-Null
  # D36 name (whatever the tag's .iss called it); test installers keep the target in the name.
  $tsuf = if ($Target -eq 'release') { '' } else { "-$Target" }
  $installer = Join-Path $dist "waldlust-remote$Suffix$BrandTag-$ver-windows-x86$tsuf.exe"
  Copy-Item -LiteralPath $setup.FullName -Destination $installer -Force
  $file = Get-Item -LiteralPath $installer
  $apiText = if ($env:WALDLUST_API_SERVER) { $env:WALDLUST_API_SERVER } else { '(none - account features disabled)' }
  $manifest = @(
    "ref: $Ref ($commit)",
    "ui: sciter (i686, sciter.dll sha256 $SciterSha)",
    "variant: $Variant",
    "target: $Target",
    "api-server: $apiText",
    "heartbeat: $env:WALDLUST_HEARTBEAT_URL",
    "check: $Check",
    "signature: unsigned"
  )
  if ($Variant -eq 'incoming') { $manifest += "incoming password fingerprint: $Fp" }
  if ($Code) { $manifest += "brand: $Code" }
  $manifest += @(
    "installer: $($file.Name)",
    "size: $($file.Length)",
    "sha256: $((Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLower())",
    "built: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  )
  [System.IO.File]::WriteAllLines((Join-Path $dist "manifest-x86-$Variant$BrandTag.txt"), $manifest, (New-Object System.Text.UTF8Encoding $false))
  if ($Target -eq 'release') {
    Copy-Item -LiteralPath (Join-Path $W 'NOTICE') -Destination (Join-Path $dist 'NOTICE.txt') -Force
    Copy-Item -LiteralPath (Join-Path $W 'LICENCE') -Destination (Join-Path $dist 'LICENCE.txt') -Force
    Copy-Item -LiteralPath $Notices -Destination (Join-Path $dist 'THIRD_PARTY_NOTICES-windows-x86.txt') -Force
  }
  Write-Output "installer: $installer"
}
