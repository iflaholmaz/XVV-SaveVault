#requires -Version 5.1
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
function Get-FullFolder([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){throw 'Klasör seçin / Select a folder.'}
    [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}
function Test-Within([string]$Child,[string]$Parent) {
    $c=Get-FullFolder $Child;$p=Get-FullFolder $Parent
    $c.Equals($p,[StringComparison]::OrdinalIgnoreCase) -or $c.StartsWith($p+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Assert-SaveFolder([string]$Path,[switch]$AllowMissing) {
    $full=Get-FullFolder $Path
    if(-not $AllowMissing -and -not [IO.Directory]::Exists($full)){throw 'Kayıt klasörü bulunamadı / Save folder not found.'}
    if($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')){throw 'Sürücü kökü seçilemez / Drive root is not allowed.'}
    foreach($protected in @($env:windir,$env:ProgramFiles,${env:ProgramFiles(x86)})){
        if($protected -and (Test-Within $full $protected)){throw 'Sistem/Program Files klasörü kullanılamaz. Oyunun özel kayıt klasörünü seçin. / Select a dedicated save folder outside system/Program Files.'}
    }
    foreach($top in @($env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,[Environment]::GetFolderPath('MyDocuments'),$PSScriptRoot)){
        if($top -and $full.Equals((Get-FullFolder $top),[StringComparison]::OrdinalIgnoreCase)){throw 'Ana kullanıcı/uygulama klasörü yerine oyunun alt klasörünü seçin. / Select a game subfolder, not a user or application root.'}
    }
    if(Test-Within $PSScriptRoot $full){throw 'Uygulamanın bulunduğu üst klasör seçilemez / Cannot select an ancestor of this application.'}
    $current=New-Object IO.DirectoryInfo $full
    while($null -ne $current){if($current.Exists -and $current.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Bağlantılı klasörler desteklenmiyor / Linked folders are not supported.'};$current=$current.Parent}
    return $full
}
function Get-SafeFiles([string]$Root) {
    $queue=New-Object 'System.Collections.Generic.Queue[string]';$queue.Enqueue($Root)
    while($queue.Count){
        $dir=$queue.Dequeue()
        foreach($entry in Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop){
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Bağlantı bulundu / Link found: $($entry.FullName)"}
            if($entry.PSIsContainer){$queue.Enqueue($entry.FullName)}else{$entry}
        }
    }
}
function Write-VaultConfig($Config,[string]$Path) {
    $parent=[IO.Path]::GetDirectoryName($Path);[IO.Directory]::CreateDirectory($parent) | Out-Null
    $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($tmp,($Config | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $true))
    try {if([IO.File]::Exists($Path)){[IO.File]::Replace($tmp,$Path,$Path+'.previous',$true)}else{[IO.File]::Move($tmp,$Path)}}finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
function Assert-BackupLocation([string]$Path) {
    $full=Get-FullFolder $Path
    if($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')){throw 'Yedekler için bir alt klasör seçin / Select a subfolder for backups.'}
    $current=New-Object IO.DirectoryInfo $full
    while($null -ne $current){
        if($current.Exists -and ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Bağlantılı yedek konumu desteklenmiyor / Linked backup locations are not supported.'}
        $current=$current.Parent
    }
}
function New-VaultBackup($Profile,[string]$BackupRoot,[string]$Reason='Manual') {
    [void][guid]::Parse([string]$Profile.Id)
    $source=Assert-SaveFolder $Profile.Source;$destination=Get-FullFolder $BackupRoot
    if((Test-Within $destination $source) -or (Test-Within $source $destination)){throw 'Kayıt ve yedek klasörleri birbirinin içinde olamaz / Save and backup folders must not overlap.'}
    Assert-BackupLocation $destination
    $files=@(Get-SafeFiles $source)
    if(-not $files.Count){throw 'Klasör boş; yedek oluşturulmadı / Folder is empty; no backup created.'}
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $folder=Join-Path $destination ([string]$Profile.Id);[IO.Directory]::CreateDirectory($folder) | Out-Null
    $stamp=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff');$name="$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).zip"
    $final=Join-Path $folder $name;$temp=$final+'.partial';$records=New-Object 'System.Collections.Generic.List[object]'
    $archive=$null
    try {
        $archive=[IO.Compression.ZipFile]::Open($temp,[IO.Compression.ZipArchiveMode]::Create)
        foreach($file in $files){
            $relative=$file.FullName.Substring($source.Length+1).Replace('\','/')
            if($relative -eq '__savevault_manifest.json'){throw 'Ayrılmış dosya adı / Reserved filename.'}
            $inputStream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {
                $hasher=[Security.Cryptography.SHA256]::Create()
                try{$hash=[BitConverter]::ToString($hasher.ComputeHash($inputStream)).Replace('-','')}finally{$hasher.Dispose()}
                $inputStream.Position=0
                $entry=$archive.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
                $outputStream=$entry.Open();try{$inputStream.CopyTo($outputStream)}finally{$outputStream.Dispose()}
                $records.Add([pscustomobject]@{Path=$relative;Length=$inputStream.Length;SHA256=$hash;LastWriteUtc=$file.LastWriteTimeUtc.ToString('o')})
            } finally {$inputStream.Dispose()}
        }
        $manifest=[pscustomobject]@{Format='XVV.SaveVault';Version=1;ProfileId=[string]$Profile.Id;Game=[string]$Profile.Name;CreatedUtc=[DateTime]::UtcNow.ToString('o');Reason=$Reason;Files=@($records.ToArray())}
        $entry=$archive.CreateEntry('__savevault_manifest.json');$writer=New-Object IO.StreamWriter ($entry.Open()),(New-Object Text.UTF8Encoding $false)
        try{$writer.Write(($manifest | ConvertTo-Json -Depth 6))}finally{$writer.Dispose()}
        $archive.Dispose();$archive=$null
        [IO.File]::Move($temp,$final)
        [pscustomobject]@{Path=$final;Created=$manifest.CreatedUtc;Count=$records.Count;Bytes=(Get-Item -LiteralPath $final).Length;Reason=$Reason}
    } finally {if($archive){$archive.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Read-VaultManifest($Archive) {
    $entries=@($Archive.Entries | Where-Object FullName -eq '__savevault_manifest.json')
    if($entries.Count -ne 1 -or $entries[0].Length -gt 16777216){throw 'Geçersiz yedek bildirimi / Invalid backup manifest.'}
    $reader=New-Object IO.StreamReader ($entries[0].Open())
    try {$manifest=$reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop}finally{$reader.Dispose()}
    if($manifest.Format -ne 'XVV.SaveVault' -or $manifest.Version -ne 1 -or @($manifest.Files).Count -lt 1){throw 'Desteklenmeyen yedek / Unsupported backup.'}
    $manifest
}
function Get-VaultHistory($Profile,[string]$BackupRoot) {
    [void][guid]::Parse([string]$Profile.Id)
    $folder=Join-Path $BackupRoot ([string]$Profile.Id)
    if(-not [IO.Directory]::Exists($folder)){return}
    foreach($file in Get-ChildItem -LiteralPath $folder -Filter '*.zip' -File | Sort-Object LastWriteTime -Descending){
        $zip=$null
        try{$zip=[IO.Compression.ZipFile]::OpenRead($file.FullName);$m=Read-VaultManifest $zip
            if($m.ProfileId -ne $Profile.Id){throw 'Profile mismatch'}
            [pscustomobject]@{Path=$file.FullName;Date=([DateTime]$m.CreatedUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss');Files=@($m.Files).Count;SizeMB=[math]::Round($file.Length/1MB,2);Reason=$m.Reason;Status='Ready';Name=$file.Name}
        }catch{[pscustomobject]@{Path=$file.FullName;Date=$file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss');Files=0;SizeMB=[math]::Round($file.Length/1MB,2);Reason='Unknown';Status='Invalid';Name=$file.Name}}
        finally{if($zip){$zip.Dispose()}}
    }
}
function Test-VaultArchive([string]$ZipPath,[string]$ProfileId,[string]$ExtractTo) {
    $zip=[IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $m=Read-VaultManifest $zip
        if($m.ProfileId -ne $ProfileId){throw 'Bu yedek farklı profile ait / Backup belongs to a different profile.'}
        $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        if($zip.Entries.Count -ne (@($m.Files).Count+1)){throw 'Dosya listesi eşleşmiyor / File list mismatch.'}
        foreach($record in $m.Files){
            $relative=[string]$record.Path
            if([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^[/\\]|:|\\|[\x00-\x1f])' -or $relative -eq '__savevault_manifest.json'){throw 'Güvensiz arşiv yolu / Unsafe archive path.'}
            foreach($part in $relative.Split('/')){if($part -in @('','.','..') -or $part -match '[. ]$|[<>"|?*]' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'Geçersiz dosya adı / Invalid filename.'}}
            if(-not $seen.Add($relative)){throw 'Yinelenen dosya / Duplicate file.'}
            $entry=$zip.GetEntry($relative)
            if($null -eq $entry -or $entry.Length -ne [long]$record.Length -or ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000)){throw 'Geçersiz ZIP girdisi / Invalid ZIP entry.'}
            $stream=$entry.Open();$hasher=[Security.Cryptography.SHA256]::Create()
            try{$hash=[BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$hasher.Dispose()}
            if($hash -ne $record.SHA256){throw "Sağlama hatası / Checksum mismatch: $relative"}
            if($ExtractTo){
                $target=[IO.Path]::GetFullPath((Join-Path $ExtractTo $relative.Replace('/','\')))
                if(-not (Test-Within $target $ExtractTo)){throw 'Path escaped staging folder'}
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                $src=$entry.Open();$dst=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$src.CopyTo($dst)}finally{$src.Dispose();$dst.Dispose()}
                [IO.File]::SetLastWriteTimeUtc($target,([DateTime]$record.LastWriteUtc).ToUniversalTime())
            }
        }
        [pscustomobject]@{Count=@($m.Files).Count;Game=$m.Game;Verified=$true}
    } finally {$zip.Dispose()}
}
function Restore-VaultBackup($Profile,[string]$BackupRoot,[string]$ZipPath) {
    [void][guid]::Parse([string]$Profile.Id)
    $source=Assert-SaveFolder $Profile.Source -AllowMissing
    if((Test-Within $BackupRoot $source) -or (Test-Within $source $BackupRoot)){throw 'Kayıt ve yedek klasörleri örtüşemez / Folders must not overlap.'}
    if(Test-Within $ZipPath $source){throw 'Yedek hedef klasörün içinde olamaz / Backup must be outside the save folder.'}
    # Verify everything before creating the safety copy or touching the registered folder.
    Test-VaultArchive $ZipPath $Profile.Id | Out-Null
    $safety=$null
    $existed=[IO.Directory]::Exists($source)
    if($existed -and @(Get-SafeFiles $source).Count){$safety=New-VaultBackup $Profile $BackupRoot 'BeforeRestore'}
    $parent=[IO.Path]::GetDirectoryName($source);$token=[guid]::NewGuid().ToString('N')
    $stage=Join-Path $parent ('.SaveVault-stage-'+$token);$preserved=Join-Path $parent ('.SaveVault-before-'+$token)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    # Failed staging is retained for inspection. Never recursively delete a user folder.
    Test-VaultArchive $ZipPath $Profile.Id $stage | Out-Null
    if($existed){[IO.Directory]::Move($source,$preserved)}
    try{[IO.Directory]::Move($stage,$source)}catch{
        if($existed -and -not [IO.Directory]::Exists($source)){[IO.Directory]::Move($preserved,$source)}
        throw
    }
    [pscustomobject]@{Restored=$source;SafetyBackup=$(if($safety){$safety.Path}else{$null});PreservedFolder=$(if($existed){$preserved}else{'Önceki klasör yok / No previous folder'})}
}
