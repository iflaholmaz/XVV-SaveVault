#requires -Version 5.1
[CmdletBinding()]
param([switch]$SmokeTest,[string]$TestRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
. "$PSScriptRoot\Vault.ps1"
if($SmokeTest -and -not $TestRoot){throw 'SmokeTest requires an isolated TestRoot.'}
$script:configPath=Join-Path $env:LOCALAPPDATA 'XVV SaveVault\profiles.json'
if($SmokeTest){$script:configPath=Join-Path $TestRoot 'profiles.json'}
$defaultBackup=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'XVV SaveVault Backups'
if($SmokeTest){$defaultBackup=Join-Path $TestRoot 'backups'}
$script:config=[pscustomobject]@{Version=1;Language='tr';BackupRoot=$defaultBackup;Profiles=@()}
if(Test-Path -LiteralPath $script:configPath){
    try{$loaded=Get-Content -LiteralPath $script:configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if($loaded.Version -ne 1 -or -not $loaded.BackupRoot){throw 'Invalid config'}
        foreach($p in $loaded.Profiles){[void][guid]::Parse($p.Id);if(-not $p.Name -or -not $p.Source){throw 'Invalid profile'}}
        $script:config=$loaded
    }catch{throw "Profil dosyası okunamadı; dosya değiştirilmedi. / Profile config could not be read; it was not changed. $($_.Exception.Message)"}
}
[xml]$xaml=Get-Content -LiteralPath "$PSScriptRoot\MainWindow.xaml" -Raw -Encoding UTF8
$script:window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$script:ui=@{};$xaml.SelectNodes('//*[@Name]') | ForEach-Object {$ui[$_.Name]=$window.FindName($_.Name)}
$script:busy=$false;$script:worker=$null;$script:pending=$null;$script:operation=''
function L($TR,$EN){if($script:config.Language -eq 'en'){$EN}else{$TR}}
function Save-Config {Write-VaultConfig $script:config $script:configPath}
function Show-Error($Message){$ui.Status.Text=$Message;if(-not $SmokeTest){[void][Windows.MessageBox]::Show($window,$Message,'XVV SaveVault','OK','Warning')}}
function Update-Buttons {
    $selected=$null -ne $ui.Profiles.SelectedItem
    foreach($name in @('AddGame','RemoveGame','ChooseStorage','Language','Refresh','Profiles')){$ui[$name].IsEnabled=-not $script:busy}
    $ui.RemoveGame.IsEnabled=$selected -and -not $script:busy
    $ui.Backup.IsEnabled=$selected -and -not $script:busy;$ui.OpenSource.IsEnabled=$selected -and -not $script:busy
    $valid=$null -ne $ui.History.SelectedItem -and $ui.History.SelectedItem.Status -eq 'Ready'
    $ui.Restore.IsEnabled=$valid -and -not $script:busy;$ui.Verify.IsEnabled=$valid -and -not $script:busy
    $ui.Progress.IsIndeterminate=$script:busy
}
function Refresh-History {
    $p=$ui.Profiles.SelectedItem
    if($p){$ui.GameTitle.Text=$p.Name;$ui.GamePath.Text=$p.Source;$items=@(Get-VaultHistory $p $config.BackupRoot);$ui.History.ItemsSource=$items;$ui.EmptyHistory.Visibility=if($items.Count){'Collapsed'}else{'Visible'}}
    else{$ui.GameTitle.Text=L 'İlk oyununu ekle' 'Add your first game';$ui.GamePath.Text=L 'Yedeklemek istediğin kayıt klasörünü seçerek başla.' 'Start by choosing the save folder you want to protect.';$ui.History.ItemsSource=@();$ui.EmptyHistory.Visibility='Visible'}
    $ui.BackupPath.Text=$config.BackupRoot;Update-Buttons
}
function Update-Language {
    $texts=@{Subtitle=@('Oyunun kalsın. İlerlemen kaybolmasın.','Keep your progress close.');GamesLabel=@('Oyunlarım','My games');CloseGameHint=@('Yedekleme ve geri yükleme öncesinde oyunu kapat. Bulut eşitlemesinin tamamlanmasını bekle.','Close the game before backup or restore. Wait for cloud sync to finish.');HistoryTitle=@('Yedek geçmişi','Backup history');EmptyHistory=@('Henüz yedek yok.','No backups yet.');SafetyHint=@('Geri yükleme önce güncel kayıtları yedekler. Önceki klasör de korunur. ZIP yedekleri şifrelenmez.','Restore first backs up current saves and preserves the previous folder. ZIP backups are not encrypted.')}
    $en=[int]($config.Language -eq 'en');foreach($k in $texts.Keys){$ui[$k].Text=$texts[$k][$en]}
    $buttons=@{AddGame=@('+ Oyun ekle','+ Add game');RemoveGame=@('Listeden kaldır','Remove from list');Backup=@('Şimdi yedekle','Back up now');OpenSource=@('Kayıt klasörü','Save folder');Refresh=@('Yenile','Refresh');Restore=@('Geri yükle','Restore');Verify=@('Yedeği doğrula','Verify backup');ChooseStorage=@('Konumu değiştir','Change location');OpenStorage=@('Yedekleri aç','Open backups')}
    foreach($k in $buttons.Keys){$ui[$k].Content=$buttons[$k][$en]}
    $ui.Language.Content=L 'English' 'Türkçe';$ui.StorageExpander.Header=L 'Yedek konumu ve ayrıntılar' 'Backup location and details'
    Refresh-History
}
function Select-Folder($Title,$Initial) {
    $dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description=$Title;$dialog.ShowNewFolderButton=$true
    if($Initial -and (Test-Path -LiteralPath $Initial)){$dialog.SelectedPath=$Initial}
    try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){$dialog.SelectedPath}}finally{$dialog.Dispose()}
}
function Ask-GameName($Default) {
    [xml]$layout='<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="430" Height="200" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#202B38" Title="XVV SaveVault"><StackPanel Margin="20"><TextBlock Name="Label" Foreground="White"/><TextBox Name="NameBox" Margin="0,12" Padding="8" MaxLength="80"/><Button Name="Accept" Content="OK" Padding="10" IsDefault="True"/></StackPanel></Window>'
    $dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $layout));$dialog.Owner=$window
    $dialog.FindName('Label').Text=L 'Oyun adı' 'Game name';$box=$dialog.FindName('NameBox');$box.Text=$Default
    $dialog.FindName('Accept').Add_Click({if(-not [string]::IsNullOrWhiteSpace($box.Text)){$dialog.DialogResult=$true}})
    if($dialog.ShowDialog()){$box.Text.Trim()}
}
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(200)
function Start-VaultOperation($Kind) {
    if($script:busy -or -not $ui.Profiles.SelectedItem){return}
    $profile=$ui.Profiles.SelectedItem;$zip=$null;if($ui.History.SelectedItem){$zip=$ui.History.SelectedItem.Path}
    if($Kind -in @('Restore','Verify') -and -not $zip){return}
    if($Kind -eq 'Restore' -and -not $SmokeTest){
        $message=L "'$($profile.Name)' kayıtları seçilen yedekle değiştirilecek.`r`n`r`nHedef: $($profile.Source)`r`nYedek: $zip`r`n`r`nÖnce mevcut kayıtların ZIP yedeği alınır; eski klasör de korunur. Oyun kapalı ve bulut eşitlemesi duraklatılmış olmalı. Devam edilsin mi?" "Replace '$($profile.Name)' saves with this backup?`r`n`r`nTarget: $($profile.Source)`r`nBackup: $zip`r`n`r`nCurrent saves are backed up first; the old folder is preserved. Close the game and pause cloud sync. Continue?"
        if([Windows.MessageBox]::Show($window,$message,'XVV SaveVault','YesNo','Warning') -ne 'Yes'){return}
    }
    $script:operation=$Kind;$script:busy=$true;Update-Buttons;$ui.Status.Text=L 'İşlem devam ediyor… Pencereyi kapatmayın.' 'Working… Keep this window open.'
    $script:worker=[PowerShell]::Create()
    [void]$worker.AddScript('param($engine,$kind,$profile,$root,$zip) . $engine; switch($kind){"Backup"{New-VaultBackup $profile $root}"Verify"{Test-VaultArchive $zip $profile.Id}"Restore"{Restore-VaultBackup $profile $root $zip}}').AddArgument("$PSScriptRoot\Vault.ps1").AddArgument($Kind).AddArgument($profile).AddArgument($config.BackupRoot).AddArgument($zip)
    try{$script:pending=$worker.BeginInvoke();$timer.Start()}catch{$worker.Dispose();$script:worker=$null;$script:busy=$false;Update-Buttons;throw}
}
$timer.Add_Tick({if($script:pending -and $script:pending.IsCompleted){
    $timer.Stop()
    try{$result=$worker.EndInvoke($script:pending);if($worker.HadErrors){throw ($worker.Streams.Error | Out-String)};$script:lastResult=$result[0]
        $ui.Status.Text=switch($script:operation){'Backup'{L "Yedek hazır: $($lastResult.Count) dosya • $($lastResult.Path)" "Backup ready: $($lastResult.Count) files • $($lastResult.Path)"}'Verify'{L "Doğrulandı: $($lastResult.Count) dosya." "Verified: $($lastResult.Count) files."}'Restore'{L "Geri yüklendi. Eski klasör: $($lastResult.PreservedFolder)" "Restored. Previous folder: $($lastResult.PreservedFolder)"}}
    }catch{Show-Error $_.Exception.Message}
    finally{$worker.Dispose();$script:worker=$null;$script:pending=$null;$script:busy=$false;Refresh-History}
}})
$ui.AddGame.Add_Click({try{
    $source=Select-Folder (L 'Oyunun kayıt klasörünü seçin' 'Select the game save folder') $env:USERPROFILE;if(-not $source){return};$source=Assert-SaveFolder $source
    if((Test-Within $source $config.BackupRoot) -or (Test-Within $config.BackupRoot $source)){throw 'Kayıt ve yedek klasörleri örtüşemez / Save and backup folders must not overlap.'}
    foreach($p in $config.Profiles){if((Test-Within $source $p.Source) -or (Test-Within $p.Source $source)){throw 'Bu klasör başka bir profille örtüşüyor / Folder overlaps another profile.'}}
    $name=Ask-GameName ([IO.Path]::GetFileName($source));if(-not $name){return}
    $profile=[pscustomobject]@{Id=[guid]::NewGuid().ToString();Name=$name;Source=$source};$config.Profiles=@($config.Profiles)+@($profile);Save-Config;$ui.Profiles.ItemsSource=@($config.Profiles);$ui.Profiles.SelectedItem=$profile
}catch{Show-Error $_.Exception.Message}})
$ui.RemoveGame.Add_Click({$p=$ui.Profiles.SelectedItem;if(-not $p){return};try{
    $message=L 'Yalnızca profil listeden kaldırılacak. Kayıtlar ve yedek ZIP dosyaları silinmez. Yeniden eklemek yeni profil oluşturur; eski yedekleri saklayın. Devam?' 'Remove only this profile? Saves and ZIP backups are kept. Re-adding creates a new profile; keep the old backups.'
    if([Windows.MessageBox]::Show($window,$message,'XVV SaveVault','YesNo','Question') -eq 'Yes'){$config.Profiles=@($config.Profiles | Where-Object Id -ne $p.Id);Save-Config;$ui.Profiles.ItemsSource=@($config.Profiles);Refresh-History}
}catch{Show-Error $_.Exception.Message}})
$ui.ChooseStorage.Add_Click({try{$folder=Select-Folder (L 'Yeni yedek konumu (eski dosyalar taşınmaz)' 'New backup location (old files are not moved)') $config.BackupRoot;if(-not $folder){return};foreach($p in $config.Profiles){if((Test-Within $folder $p.Source) -or (Test-Within $p.Source $folder)){throw 'Klasörler örtüşemez / Folders must not overlap.'}};$config.BackupRoot=Get-FullFolder $folder;Save-Config;Refresh-History}catch{Show-Error $_.Exception.Message}})
$ui.Language.Add_Click({$config.Language=if($config.Language -eq 'tr'){'en'}else{'tr'};try{Save-Config;Update-Language}catch{Show-Error $_.Exception.Message}})
$ui.Profiles.Add_SelectionChanged({try{Refresh-History}catch{Show-Error $_.Exception.Message}})
$ui.History.Add_SelectionChanged({Update-Buttons})
$ui.Backup.Add_Click({try{Start-VaultOperation 'Backup'}catch{Show-Error $_.Exception.Message}})
$ui.Verify.Add_Click({try{Start-VaultOperation 'Verify'}catch{Show-Error $_.Exception.Message}})
$ui.Restore.Add_Click({try{Start-VaultOperation 'Restore'}catch{Show-Error $_.Exception.Message}})
$ui.Refresh.Add_Click({try{Refresh-History}catch{Show-Error $_.Exception.Message}})
$ui.OpenSource.Add_Click({try{Start-Process -FilePath explorer.exe -ArgumentList ('"'+$ui.Profiles.SelectedItem.Source+'"')}catch{Show-Error $_.Exception.Message}})
$ui.OpenStorage.Add_Click({try{[IO.Directory]::CreateDirectory($config.BackupRoot) | Out-Null;Start-Process -FilePath explorer.exe -ArgumentList ('"'+$config.BackupRoot+'"')}catch{Show-Error $_.Exception.Message}})
$window.Add_Closing({param($sender,$e) if($script:busy){$e.Cancel=$true;$ui.Status.Text=L 'İşlem bitince kapatabilirsiniz.' 'You can close the window when the operation finishes.'}})
$window.Add_Closed({$timer.Stop()})
$ui.Profiles.ItemsSource=@($config.Profiles);Update-Language
if($config.Profiles.Count){$ui.Profiles.SelectedIndex=0}
if($SmokeTest){
    $window.Show();$window.UpdateLayout()
    if(-not $config.Profiles.Count){throw 'Smoke fixture profile missing'}
    $config.Language='en';Update-Language;if($ui.Backup.Content -ne 'Back up now'){throw 'English failed'};$config.Language='tr';Update-Language
    Start-VaultOperation 'Backup';$deadline=(Get-Date).AddSeconds(30)
    while($script:busy -and (Get-Date) -lt $deadline){$frame=New-Object Windows.Threading.DispatcherFrame;$pump=New-Object Windows.Threading.DispatcherTimer;$pump.Interval=[TimeSpan]::FromMilliseconds(100);$pump.Tag=$frame;$pump.Add_Tick({param($sender,$args)$sender.Tag.Continue=$false;$sender.Stop()});$pump.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)}
    if($script:busy){throw 'Background backup timeout'}
    if($ui.History.Items.Count -lt 1){throw "Backup/history failed: $($ui.Status.Text)"}
    $ui.History.SelectedIndex=0;if(-not $ui.Restore.IsEnabled -or -not $ui.Verify.IsEnabled){throw 'Selection actions failed'}
    $window.Close();'PASS: WPF load, bilingual labels, background backup and history binding.';return
}
[void]$window.ShowDialog()
