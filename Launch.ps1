#requires -Version 5.1
try { & "$PSScriptRoot\SaveVault.ps1" }
catch { Add-Type -AssemblyName PresentationFramework;[void][Windows.MessageBox]::Show($_.Exception.Message,'XVV SaveVault','OK','Error');exit 1 }
