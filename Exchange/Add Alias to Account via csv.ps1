$CsvPath = "URLPATH\email-aliases.csv"

# Connect to Exchange Online GCC High
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -ExchangeEnvironmentName O365USGovGCCHigh -ShowBanner:$false

# Detect comma or tab delimiter
$firstLine = Get-Content -Path $CsvPath -TotalCount 1
if ($firstLine -match "`t") { $delim = "`t" } else { $delim = "," }

$rows = Import-Csv -Path $CsvPath -Delimiter $delim

# Make sure the headers were read correctly
$headers = $rows[0].PSObject.Properties.Name
Write-Host "Columns found: $($headers -join ' | ')" -ForegroundColor Cyan
if ($headers -notcontains "OldPrimary" -or $headers -notcontains "NewPrimary") {
    Write-Host "CSV must have OldPrimary and NewPrimary columns. Stopping." -ForegroundColor Red
    return
}

Write-Host "LIVE RUN: changes will be made." -ForegroundColor Magenta

foreach ($row in $rows) {
    $name = "$($row.DisplayName)".Trim()
    $old  = "$($row.OldPrimary)".Trim()
    $new  = "$($row.NewPrimary)".Trim()

    if ($old -eq "" -or $new -eq "") {
        Write-Host "SKIP  $name : blank OldPrimary or NewPrimary" -ForegroundColor Yellow
        continue
    }

    try {
        $recipient = Get-Recipient -Identity $new -ErrorAction Stop
        $changed = $true

        switch -Wildcard ($recipient.RecipientTypeDetails) {
            "GroupMailbox"   { Set-UnifiedGroup      -Identity $new -EmailAddresses @{Add = "smtp:$old"} -ErrorAction Stop; break }
            "*Mailbox"       { Set-Mailbox           -Identity $new -EmailAddresses @{Add = "smtp:$old"} -ErrorAction Stop; break }
            "MailUser"       { Set-MailUser          -Identity $new -EmailAddresses @{Add = "smtp:$old"} -ErrorAction Stop; break }
            "MailUniversal*" { Set-DistributionGroup -Identity $new -EmailAddresses @{Add = "smtp:$old"} -ErrorAction Stop; break }
            default          { Write-Host "SKIP  $name : unsupported type $($recipient.RecipientTypeDetails)" -ForegroundColor Yellow; $changed = $false }
        }

        if ($changed) { Write-Host "DONE  $name ($($recipient.RecipientTypeDetails)): added $old to $new" -ForegroundColor Green }
    }
    catch {
        Write-Host "ERROR $name : $($_.Exception.Message)" -ForegroundColor Red
    }
}
