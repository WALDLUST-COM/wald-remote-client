# Waldlust (wald-remote-client) Windows x64 local build -> portable folder.
# Reproduces .github/workflows/wald-windows.yml (+ bridge.yml) on a Windows 11 host.
#
# Usage:  powershell -ExecutionPolicy Bypass -File <wald-remote-docs>\wald-build\build-windows-local.ps1 [-Ref <commit|branch>]
#         [-Variant bidirectional|incoming] [-Target dummy|mock|prodtest|release] [-Inno] [-Brand <alias>]
#         (default ref: waldlust, default variant: bidirectional, default target: dummy)
# Result: C:\wald-build\waldlust-<ver>-windows-localtest[-incoming]\ (prodtest: -windows-prodtest; unsigned portable folder, run wald-remote.exe)
#         With -Inno also C:\wald-build\dist\<ver>-<sha>-<target>\waldlust-remote[-incoming]-<ver>-windows-x64[-<target>].exe
#         (installer name rule - decision D36: no -<target> for release, e.g. waldlust-remote-incoming-1.5.0-windows-x64.exe)
#         + manifest-<variant>.txt (needs Inno Setup 6 - tools\inno, installed per-user)
# Logs:   C:\wald-build\logs\windows-*.log
#
# Rules
# - Unmanaged build: WALDLUST_PRESET_PASSWORD is removed from the environment.
# - No reports to the production admin: WALDLUST_HEARTBEAT_URL is compiled in (option_env!) as
#   dummy: http://127.0.0.1:9/api/heartbeat (nothing listens; WALDLUST_API_SERVER is taken from the caller if set)
#   mock:  http://127.0.0.1:8787/api/heartbeat + WALDLUST_API_SERVER=http://127.0.0.1:8787/rd
#          (wald-remote-docs\tools\rd-mock - start it before running the app)
#   prodtest: test build that talks to the production server (plan ADMIN_LOCAL_PLAN C4, decision D16 - 2026-10-14):
#          heartbeat https://remote.waldpay.co.kr/api/heartbeat + WALDLUST_API_SERVER=https://remote.waldpay.co.kr/rd.
#          Still unmanaged/unsigned - not for field deployment (before the repo transfer). The test machine shows up in the
#          production list as unassigned. Output is named prodtest (not localtest), so dummy/mock builds are not overwritten.
#   release: official build (plan ADMIN_LOCAL_PLAN 4-1, decisions D33-D35 - 2026-10-14). Same addresses as prodtest.
#          -Ref must be a wald-v<ver>-r<N> tag pushed to origin (WALDLUST-COM) whose version is the source version (D36),
#          and -Inno is required. Incoming-only takes only
#          -IncomingEnv C:\wald-build\incoming-prod.env. Before ISCC, NOTICE.txt, LICENCE.txt and THIRD_PARTY_NOTICES.txt
#          (res\wald-build\collect-notices.py) are put into the installer payload, and copied to dist. Unsigned (D34).
#          Needs cargo-about 0.6.4 (cargo install cargo-about --version 0.6.4 --locked).
# - Incoming-only variant (DSK-01): the test password and salt come from C:\wald-build\incoming-test.env
#   (WALDLUST_INCOMING_PASSWORD=..., WALDLUST_INCOMING_SALT=...; test values, not the production ones, outside git).
#   They are hashed with res\wald-variant\preset_hash.py; only the hash goes into the build. Values are never printed.
#   -IncomingEnv C:\wald-build\incoming-prod.env builds with the production shared password (same format).
# - Brand-only build (DSK-01, decision D53): -Brand <alias> reads C:\wald-build\brand-<alias>.env (outside git):
#     WALDLUST_BRAND=<code issued by the admin: 8-12 lowercase letters and digits>
#     WALDLUST_INCOMING_PASSWORD=..., WALDLUST_INCOMING_SALT=...   (incoming-only: the brand's own password, required)
#   The code goes into the build (login, heartbeat, update check); the server narrows the scope with it. Output names get
#   -<code> (portable folder, installer, manifest-<variant>-<code>.txt with a 'brand:' line). After the build the script
#   looks for the mark wald-brand-build:<code> in the binary (wald-brand-build:none for a general build).
#   Without -Brand, WALDLUST_BRAND is removed from the environment - a value left in the shell cannot leak into a general build.
# - The shared working folder is not touched: build in a fresh git worktree (wt-windows);
#   cargo target lives outside it (target-windows) and is linked in as a junction.
# - Short root (C:\wald-build) because LongPathsEnabled is 0 on this host (vcpkg/cmake/flutter hit MAX_PATH).
#
# Prerequisites (installed once, all under C:\wald-build unless noted):
#   Visual Studio 2022 (MSVC 14.44, Windows SDK), rustup in %USERPROFILE%\.cargo (default 1.75 + rustfmt),
#   cargo-expand 1.0.95, flutter_rust_bridge_codegen 1.80.1 (--features uuid),
#   tools\flutter = Flutter 3.24.5 git clone (autocrlf off) + rustdesk engine windows-x64-release + dropdown patch,
#   tools\llvm = LLVM 15.0.6 (extracted from the NSIS installer with 7-Zip, no admin),
#   tools\python = Python 3.12 (NuGet package, not on PATH), vcpkg = microsoft/vcpkg 120deac (bootstrapped).
param(
  [string]$Ref = 'waldlust',
  [string]$Client = (Join-Path $env:USERPROFILE 'Documents\GitHub\wald-remote-client'),
  [string]$Out = 'C:\wald-build',
  [ValidateSet('bidirectional', 'incoming')][string]$Variant = 'bidirectional',
  [ValidateSet('dummy', 'mock', 'prodtest', 'release')][string]$Target = 'dummy',
  [switch]$Inno,
  [string]$IncomingEnv = 'C:\wald-build\incoming-test.env',  # production values: C:\wald-build\incoming-prod.env
  [string]$Brand = '',      # brand-only build: alias of C:\wald-build\brand-<alias>.env
  [string]$BrandEnv = ''    # default: <Out>\brand-<alias>.env
)
$Suffix = if ($Variant -eq 'incoming') { '-incoming' } else { '' }
$Kind = if ($Target -eq 'prodtest' -or $Target -eq 'release') { $Target } else { 'localtest' }
$Prod = ($Target -eq 'prodtest' -or $Target -eq 'release')  # built against the production server
$ErrorActionPreference = 'Continue'  # native tools write progress to stderr; exit codes are checked instead
$W = Join-Path $Out 'wt-windows'
$T = Join-Path $Out 'target-windows'
$LOG = Join-Path $Out 'logs'
$Tools = Join-Path $Out 'tools'
New-Item -ItemType Directory -Force $LOG, $T | Out-Null

$env:PATH = "$env:USERPROFILE\.cargo\bin;$Tools\flutter\bin;$Tools\python;$Tools\python\Scripts;$Tools\llvm\bin;$env:PATH"
$env:RUSTUP_TOOLCHAIN = '1.75'
$env:VCPKG_ROOT = Join-Path $Out 'vcpkg'
$env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
$env:VCPKG_DISABLE_METRICS = '1'
$env:LIBCLANG_PATH = "$Tools\llvm\bin"
$env:WALDLUST_HEARTBEAT_URL = 'http://127.0.0.1:9/api/heartbeat'
if ($Target -eq 'mock') {
  $env:WALDLUST_HEARTBEAT_URL = 'http://127.0.0.1:8787/api/heartbeat'
  $env:WALDLUST_API_SERVER = 'http://127.0.0.1:8787/rd'
}
if ($Prod) {
  $env:WALDLUST_HEARTBEAT_URL = 'https://remote.waldpay.co.kr/api/heartbeat'
  $env:WALDLUST_API_SERVER = 'https://remote.waldpay.co.kr/rd'
}
Remove-Item Env:WALDLUST_PRESET_PASSWORD -ErrorAction SilentlyContinue
foreach ($k in 'WALDLUST_VARIANT', 'WALDLUST_INCOMING_PW_STORAGE', 'WALDLUST_INCOMING_PW_SALT', 'WALDLUST_INCOMING_PASSWORD', 'WALDLUST_INCOMING_SALT', 'WALDLUST_BRAND') {
  Remove-Item "Env:$k" -ErrorAction SilentlyContinue
}

function Step([string]$Name) { Write-Output "== $Name $(Get-Date -Format HH:mm:ss)" }
function Die([string]$Msg) { Write-Output "FAIL: $Msg (logs: $LOG)"; exit 1 }
# Run a command line through cmd so stderr goes to the log file instead of becoming PowerShell errors.
function Run([string]$Name, [string]$Cmd) {
  cmd /c "$Cmd >> `"$LOG\windows-$Name.log`" 2>&1"
  if ($LASTEXITCODE -ne 0) { Die "$Name (exit $LASTEXITCODE)" }
}

# Brand-only build (DSK-01, decision D53). See the header. Values are never printed (the code is not a secret, the password is).
$Code = ''
if ($Brand) {
  if ($Brand -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { Die "-Brand takes an alias made of letters, digits, - and _" }
  if (-not $BrandEnv) { $BrandEnv = Join-Path $Out "brand-$Brand.env" }
  if (-not (Test-Path -LiteralPath $BrandEnv)) { Die "$BrandEnv not found (WALDLUST_BRAND=<code>; incoming-only also WALDLUST_INCOMING_PASSWORD, WALDLUST_INCOMING_SALT)" }
  $brandVals = @{}
  foreach ($line in Get-Content -LiteralPath $BrandEnv) {
    if ($line -match '^\s*(WALDLUST_BRAND|WALDLUST_INCOMING_PASSWORD|WALDLUST_INCOMING_SALT)=(.*)$') { $brandVals[$Matches[1]] = $Matches[2] }
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
  $brandVals = $null
  $env:WALDLUST_BRAND = $Code
}
$BrandTag = if ($Code) { "-$Code" } else { '' }

# release: a wald-v* tag that exists on origin with the same commit, -Inno, the production password, cargo-about.
$CargoAbout = Join-Path $env:USERPROFILE '.cargo\bin\cargo-about.exe'
if ($Target -eq 'release') {
  if ($Ref -notmatch '^wald-v\d+\.\d+\.\d+-r\d+$') { Die "release takes only a wald-v<ver>-r<N> tag (got $Ref)" }
  $rc = ((git -C $Client ls-remote origin "refs/tags/$Ref^{}") -split '\s+')[0]
  if (-not $rc) { $rc = ((git -C $Client ls-remote origin "refs/tags/$Ref") -split '\s+')[0] }
  $lc = git -C $Client rev-parse -q --verify "$Ref^{commit}"
  if (-not $rc -or $rc -ne $lc) { Die "tag $Ref is not on origin or differs from the local tag (origin '$rc', local '$lc') - git fetch --tags" }
  if (-not $Inno) { Die 'release needs -Inno' }
  if ($Variant -eq 'incoming' -and -not $Code -and (Split-Path -Leaf $IncomingEnv) -ne 'incoming-prod.env') { Die 'release incoming-only takes only -IncomingEnv C:\wald-build\incoming-prod.env' }
  if (-not (Test-Path -LiteralPath $CargoAbout)) { Die 'cargo-about not found (cargo install cargo-about --version 0.6.4 --locked)' }
}

# 0) Fresh worktree. Remove the target junction first so nothing follows it into the cargo cache.
Step "worktree $Ref"
if (Test-Path -LiteralPath $W) {
  $link = Get-Item -LiteralPath (Join-Path $W 'target') -Force -ErrorAction SilentlyContinue
  if ($link -and $link.LinkType) { $link.Delete() }
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
New-Item -ItemType Junction -Path (Join-Path $W 'target') -Target $T | Out-Null
Get-ChildItem $LOG -Filter 'windows-*.log' | Remove-Item

# Incoming-only variant: hash the test password. The plain values live only in this block's environment.
if ($Variant -eq 'incoming') {
  Step "variant incoming"
  $envFile = $IncomingEnv
  if (-not (Test-Path -LiteralPath $envFile)) { Die "$envFile not found (WALDLUST_INCOMING_PASSWORD, WALDLUST_INCOMING_SALT; test values)" }
  $helper = Join-Path $W 'res\wald-variant\preset_hash.py'
  if (-not (Test-Path -LiteralPath $helper)) { Die "$Ref has no incoming-only variant (res\wald-variant)" }
  foreach ($line in Get-Content -LiteralPath $envFile) {
    if ($line -match '^\s*(WALDLUST_INCOMING_PASSWORD|WALDLUST_INCOMING_SALT)=(.*)$') {
      Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
    }
  }
  $env:PYTHONUTF8 = '1'
  $hashOut = python $helper
  $hashExit = $LASTEXITCODE
  Remove-Item Env:WALDLUST_INCOMING_PASSWORD, Env:WALDLUST_INCOMING_SALT -ErrorAction SilentlyContinue
  if ($hashExit -ne 0) { Die "password hash (preset_hash.py)" }
  foreach ($line in $hashOut) {
    $kv = $line.Split('=', 2)
    Set-Item -Path "Env:$($kv[0])" -Value $kv[1]
  }
  $env:WALDLUST_VARIANT = 'incoming'
  # Incoming-only icons (down-arrow badge, DSK-10). Older refs without the script are skipped (build.rs does not check them).
  $iconHelper = Join-Path $W 'res\wald-variant\apply_icons.py'
  if (Test-Path -LiteralPath $iconHelper) {
    python $iconHelper
    if ($LASTEXITCODE -ne 0) { Die "incoming icons (apply_icons.py)" }
  }
  # Fingerprint (first 5 hex of SHA-256 over the storage hash) to compare machines; same as set-incoming-env.ps1.
  $h2 = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($env:WALDLUST_INCOMING_PW_STORAGE))
  $Fp = (($h2 | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 5)
  Write-Output "incoming password fingerprint $Fp ($envFile)"
}

# 1) Bridge. CI generates it on Linux with Flutter 3.22.3; here it is generated with the same 3.24.5 as the app
#    (the Mac script does the same). ffigen gets libclang from tools\llvm.
Step bridge
Run bridge "cd /d `"$W\flutter`" && call flutter pub get"
Run bridge "cd /d `"$W`" && flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h --llvm-path `"$Tools\llvm`""
Copy-Item (Join-Path $W 'flutter\macos\Runner\bridge_generated.h') (Join-Path $W 'flutter\ios\Runner\bridge_generated.h')

# 2) vcpkg dependencies (x64-windows-static, manifest mode). Fast when already installed.
Step vcpkg
Run vcpkg "cd /d `"$W`" && `"$env:VCPKG_ROOT\vcpkg.exe`" install --triplet x64-windows-static --x-install-root=`"$env:VCPKG_ROOT\installed`""

# 3) Build (wald-windows.yml 'Build rustdesk').
Step build
Run build "cd /d `"$W`" && python build.py --portable --flutter --skip-portable-pack --hwcodec --vram"

# 4) Copy the portable folder out of the worktree.
Step copy
$ver = ((Select-String -Path (Join-Path $W 'flutter\pubspec.yaml') -Pattern '^version:').Line -split '\s+')[1].Split('+')[0]
$src = Join-Path $W 'flutter\build\windows\x64\runner\Release'
$dest = Join-Path $Out "waldlust-$ver-windows-$Kind$Suffix$BrandTag"
if (-not (Test-Path -LiteralPath (Join-Path $src 'wald-remote.exe'))) { Die "wald-remote.exe not found in $src" }
if (Test-Path -LiteralPath $dest) { Remove-Item -Recurse -Force -LiteralPath $dest }
Copy-Item -Recurse -LiteralPath $src -Destination $dest

# 5) Verify the heartbeat address (expected >= 1, production 0 - for prodtest the expected one is production) and the API server if one was set.
#    Do not run the app if this fails. ('-' = not set: PowerShell 5.1 drops empty native arguments.)
Step verify
$hbNeedle = $env:WALDLUST_HEARTBEAT_URL -replace '^https?://', ''
$apiNeedle = '-'
if ($env:WALDLUST_API_SERVER) { $apiNeedle = $env:WALDLUST_API_SERVER.Trim().TrimEnd('/') -replace '^https?://', '' }
# Brand mark (DSK-01, decision D53): the binary must carry wald-brand-build:<code> for a brand build and
# wald-brand-build:none for a general one. Refs older than the brand support have no mark (general builds only).
$markNeedle = '-'
if (Test-Path -LiteralPath (Join-Path $W 'src\wald_brand.rs')) {
  $markNeedle = if ($Code) { "wald-brand-build:$Code" } else { 'wald-brand-build:none' }
}
$counts = python -c "import sys;d=open(sys.argv[1],'rb').read();print(*[d.count(x.encode()) if x != '-' else -1 for x in sys.argv[2:]])" (Join-Path $dest 'librustdesk.dll') $hbNeedle 'remote.waldpay.co.kr/api/heartbeat' $apiNeedle $markNeedle
$hb, $prod, $api, $mark = $counts -split ' ' | ForEach-Object { [int]$_ }
$Check = "heartbeat $hbNeedle=$hb production=$prod / api-server $apiNeedle=$api / brand $markNeedle=$mark"
Write-Output $Check
if ($hb -lt 1 -or ($prod -ne 0 -and -not $Prod)) { Die "heartbeat address check failed - do not run this build" }
if ($apiNeedle -ne '-' -and $api -lt 1) { Die "api-server value is not in the build - do not run this build" }
if ($markNeedle -ne '-' -and $mark -lt 1) { Die "brand mark check failed ($markNeedle is not in the build) - do not run this build" }
Write-Output "done: $dest\wald-remote.exe"

# 6) Optional Inno installer (wald-windows-inno.yml 'Package with Inno Setup'). Same AppId for both variants.
if ($Inno) {
  Step inno
  $iscc = @((Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'), (Join-Path $Tools 'inno\ISCC.exe')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $iscc) { Die "ISCC.exe not found (install Inno Setup 6 or put it in $Tools\inno)" }
  $issDir = Join-Path $W 'res\inno'
  Copy-Item -Recurse -LiteralPath $dest -Destination (Join-Path $issDir 'rustdesk')
  # release: open source notices (D35) go into the payload, so [Files] installs them next to Waldlust.exe.
  if ($Target -eq 'release') {
    Step notices
    $Notices = Join-Path $LOG 'THIRD_PARTY_NOTICES-windows-x64.txt'
    $env:PYTHONUTF8 = '1'
    Run notices "cd /d `"$W`" && python res\wald-build\collect-notices.py --platform windows-x64 --out `"$Notices`" --release $Ref --flutter-notices `"$dest\data\flutter_assets\NOTICES.Z`" --vcpkg-share `"$env:VCPKG_ROOT\installed\x64-windows-static\share`" --cargo-about `"$CargoAbout`""
    $payload = Join-Path $issDir 'rustdesk'
    Copy-Item -LiteralPath (Join-Path $W 'NOTICE') -Destination (Join-Path $payload 'NOTICE.txt')
    Copy-Item -LiteralPath (Join-Path $W 'LICENCE') -Destination (Join-Path $payload 'LICENCE.txt')
    Copy-Item -LiteralPath $Notices -Destination (Join-Path $payload 'THIRD_PARTY_NOTICES.txt')
  }
  $defs = "/DMyAppVersion=$ver"
  if ($Suffix) { $defs += " /DMyVariantSuffix=$Suffix" }
  Run inno "cd /d `"$issDir`" && `"$iscc`" $defs waldlust.iss"
  # Inno output: waldlust-remote[-incoming]-<ver>-windows-x64.exe (older tags: waldlust-setup-<ver>-x86_64[-incoming].exe).
  $setup = Get-ChildItem -LiteralPath $issDir -Recurse -Filter 'waldlust-*.exe' | Select-Object -First 1
  if (-not $setup) { Die "installer not found under $issDir" }
  # Collect into dist\<ver>-<sha>-<target>\ under the D36 name (whatever the tag's .iss called it). Test installers keep
  # the target in the name, so they are not mistaken for releases.
  $commit = git -C $W rev-parse HEAD
  $dist = Join-Path $Out "dist\$ver-$($commit.Substring(0, 9))-$Target"
  New-Item -ItemType Directory -Force $dist | Out-Null
  $tsuf = if ($Target -eq 'release') { '' } else { "-$Target" }
  $installer = Join-Path $dist "waldlust-remote$Suffix$BrandTag-$ver-windows-x64$tsuf.exe"
  Copy-Item -LiteralPath $setup.FullName -Destination $installer -Force
  $file = Get-Item -LiteralPath $installer
  $apiText = if ($env:WALDLUST_API_SERVER) { $env:WALDLUST_API_SERVER } else { '(none - account features disabled)' }
  $manifest = @(
    "ref: $Ref ($commit)",
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
  [System.IO.File]::WriteAllLines((Join-Path $dist "manifest-$Variant$BrandTag.txt"), $manifest, (New-Object System.Text.UTF8Encoding $false))
  if ($Target -eq 'release') {
    Copy-Item -LiteralPath (Join-Path $W 'NOTICE') -Destination (Join-Path $dist 'NOTICE.txt') -Force
    Copy-Item -LiteralPath (Join-Path $W 'LICENCE') -Destination (Join-Path $dist 'LICENCE.txt') -Force
    Copy-Item -LiteralPath $Notices -Destination (Join-Path $dist 'THIRD_PARTY_NOTICES-windows-x64.txt') -Force
  }
  Write-Output "installer: $installer"
}
