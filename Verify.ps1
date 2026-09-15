#requires -Version 5.1
param([string]$TestRoot)
$ErrorActionPreference='Stop'
if(-not $TestRoot){$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('SaveVault-Test-'+[guid]::NewGuid().ToString('N'))}
$TestRoot=[IO.Path]::GetFullPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be a new, empty test location.'}
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
. "$PSScriptRoot\Vault.ps1"
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
foreach($file in Get-ChildItem $PSScriptRoot -Filter '*.ps1'){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0) "Syntax failure $($file.Name): $errors"}
$source=Join-Path $TestRoot 'sample saves';$backupRoot=Join-Path $TestRoot 'backups'
[IO.Directory]::CreateDirectory((Join-Path $source 'slot 1')) | Out-Null
[IO.File]::WriteAllText((Join-Path $source 'slot 1\Türkçe.sav'),'level 42 — kayıt')
[IO.File]::WriteAllBytes((Join-Path $source 'binary.dat'),[byte[]](0..255))
$profile=[pscustomobject]@{Id=[guid]::NewGuid().ToString();Name='Test Game';Source=$source}
$b=New-VaultBackup $profile $backupRoot
Assert ([IO.File]::Exists($b.Path)) 'Backup missing'
$v=Test-VaultArchive $b.Path $profile.Id;Assert ($v.Count -eq 2) 'Wrong file count'
$history=@(Get-VaultHistory $profile $backupRoot);Assert ($history.Count -eq 1 -and $history[0].Status -eq 'Ready') 'History failed'
$rejected=$false;try{New-VaultBackup $profile (Join-Path $source 'bad-backups') | Out-Null}catch{$rejected=$true};Assert $rejected 'Overlapping backup allowed'
$rejected=$false;try{Test-VaultArchive $b.Path ([guid]::NewGuid().ToString()) | Out-Null}catch{$rejected=$true};Assert $rejected 'Wrong profile accepted'
[IO.File]::WriteAllText((Join-Path $source 'binary.dat'),'NEW DATA')
[IO.File]::WriteAllText((Join-Path $source 'extra.sav'),'Keep in safety copy')
$restored=Restore-VaultBackup $profile $backupRoot $b.Path
Assert ((Get-FileHash (Join-Path $source 'binary.dat')).Hash -eq ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash([byte[]](0..255))).Replace('-',''))) 'Restore bytes mismatch'
Assert (-not (Test-Path (Join-Path $source 'extra.sav'))) 'Restore did not replace snapshot'
Assert ((Get-Content -LiteralPath (Join-Path $restored.PreservedFolder 'binary.dat') -Raw) -eq 'NEW DATA') 'Original folder not preserved'
Assert ([IO.File]::Exists($restored.SafetyBackup)) 'Safety ZIP missing'
Test-VaultArchive $restored.SafetyBackup $profile.Id | Out-Null
# Restore a registered profile whose source folder disappeared, then an empty one.
$missingProfile=[pscustomobject]@{Id=$profile.Id;Name='Missing saves test';Source=(Join-Path $TestRoot 'missing saves')}
$missingResult=Restore-VaultBackup $missingProfile $backupRoot $b.Path
Assert ((Get-Item (Join-Path $missingProfile.Source 'binary.dat')).Length -eq 256) 'Missing-folder restore failed'
$emptyProfile=[pscustomobject]@{Id=$profile.Id;Name='Empty saves test';Source=(Join-Path $TestRoot 'empty saves')}
[IO.Directory]::CreateDirectory($emptyProfile.Source) | Out-Null
$emptyResult=Restore-VaultBackup $emptyProfile $backupRoot $b.Path
Assert ([IO.Directory]::Exists($emptyResult.PreservedFolder)) 'Empty previous folder not preserved'
# Corrupt a file while keeping the manifest unchanged.
$corrupt=Join-Path $TestRoot 'corrupt.zip';[IO.File]::Copy($b.Path,$corrupt)
$zip=[IO.Compression.ZipFile]::Open($corrupt,'Update');try{$zip.GetEntry('binary.dat').Delete();$entry=$zip.CreateEntry('binary.dat');$stream=$entry.Open();try{$stream.Write([byte[]](255..0),0,256)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
$rejected=$false;try{Restore-VaultBackup $profile $backupRoot $corrupt | Out-Null}catch{$rejected=$true};Assert $rejected 'Corrupt backup restored'
Assert ((Get-Item (Join-Path $source 'binary.dat')).Length -eq 256) 'Failed restore changed source'
# A malicious archive path must never extract outside staging.
$evil=Join-Path $TestRoot 'traversal.zip';$zip=[IO.Compression.ZipFile]::Open($evil,'Create')
try{$entry=$zip.CreateEntry('../escape.txt');$writer=New-Object IO.StreamWriter ($entry.Open());$writer.Write('evil');$writer.Dispose();$manifest=[pscustomobject]@{Format='XVV.SaveVault';Version=1;ProfileId=$profile.Id;Files=@([pscustomobject]@{Path='../escape.txt';Length=4;SHA256='bad';LastWriteUtc=[DateTime]::UtcNow.ToString('o')})};$entry=$zip.CreateEntry('__savevault_manifest.json');$writer=New-Object IO.StreamWriter ($entry.Open());$writer.Write(($manifest | ConvertTo-Json -Depth 5));$writer.Dispose()}finally{$zip.Dispose()}
$rejected=$false;try{Test-VaultArchive $evil $profile.Id (Join-Path $TestRoot 'extract') | Out-Null}catch{$rejected=$true};Assert $rejected 'Traversal accepted'
Assert (-not (Test-Path (Join-Path $TestRoot 'escape.txt'))) 'Traversal wrote outside target'
# A locked game file must fail without publishing a partial ZIP.
$lock=[IO.File]::Open((Join-Path $source 'binary.dat'),'Open','ReadWrite','None')
try{$rejected=$false;try{New-VaultBackup $profile $backupRoot | Out-Null}catch{$rejected=$true};Assert $rejected 'Locked file silently backed up'}finally{$lock.Dispose()}
Assert (@(Get-ChildItem $backupRoot -Recurse -Filter '*.partial').Count -eq 0) 'Partial ZIP leaked'
$config=[pscustomobject]@{Version=1;Language='tr';BackupRoot=$backupRoot;Profiles=@($profile)}
Write-VaultConfig $config (Join-Path $TestRoot 'profiles.json');Write-VaultConfig $config (Join-Path $TestRoot 'profiles.json')
Assert ((Get-Content (Join-Path $TestRoot 'profiles.json') -Raw | ConvertFrom-Json).Profiles[0].Id -eq $profile.Id) 'Config failed'
& "$PSScriptRoot\SaveVault.ps1" -SmokeTest -TestRoot $TestRoot
'PASS: ZIP roundtrip, Unicode/binary files, restore safety copy, exact snapshot, hash tampering, traversal, locked files, overlap, profile isolation and config persistence.'
"Test artifacts retained for inspection: $TestRoot"
