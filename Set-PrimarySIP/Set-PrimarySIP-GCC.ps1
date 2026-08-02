# For every mailbox: checks the current primary SMTP address, and if the
# primary SIP address doesn't match it, updates SIP to match. Nothing else
# on the mailbox is touched - no SMTP addresses are added or changed.

$LogPath = "C:\Users\public\Desktop\SipSync_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$DryRun  = $false   # set to $false once you've reviewed a dry run

$existingSession = Get-ConnectionInformation -ErrorAction SilentlyContinue
if (-not $existingSession) {
    Write-Host "Connecting to Exchange Online (GCC/Commerical)..." -ForegroundColor Cyan
    Connect-ExchangeOnline -ShowBanner:$false
}

Write-Host "Retrieving mailboxes..." -ForegroundColor Cyan
$mailboxes = Get-EXOMailbox -ResultSize Unlimited -Properties UserPrincipalName, PrimarySmtpAddress, EmailAddresses

$results = @()

foreach ($mbx in $mailboxes) {

    $primary = $mbx.PrimarySmtpAddress
    $currentPrimarySip = $mbx.EmailAddresses | Where-Object { $_ -clike "SIP:*" } | Select-Object -First 1
    $currentPrimarySipAddress = if ($currentPrimarySip) { $currentPrimarySip.Substring(4) } else { "" }

    $status = ""
    $errorMessage = ""

    if ($currentPrimarySipAddress -ieq $primary) {
        $status = "Skipped - already matches"
    }
    else {
        Write-Host "`n$($mbx.UserPrincipalName)" -ForegroundColor Yellow
        Write-Host "  Primary SMTP : $primary"
        Write-Host "  Current SIP  : $currentPrimarySipAddress"
        Write-Host "  New SIP      : $primary"

        if ($DryRun) {
            $status = "DryRun - no change made"
        }
        else {
            try {
                # Demote any existing SIP: entries to lowercase, drop any
                # entry that already matches the new SIP address (avoids a
                # duplicate in a different case), then add the new one back
                # in as the primary SIP.
                $updatedAddresses = @()
                foreach ($addr in $mbx.EmailAddresses) {
                    if ($addr -imatch "^sip:$([regex]::Escape($primary))$") {
                        continue
                    }
                    elseif ($addr -clike "SIP:*") {
                        $updatedAddresses += "sip:" + $addr.Substring(4)
                    }
                    else {
                        $updatedAddresses += $addr
                    }
                }
                $updatedAddresses += "SIP:$primary"

                Set-Mailbox -Identity $mbx.UserPrincipalName -EmailAddresses $updatedAddresses -ErrorAction Stop
                $status = "Success"
            }
            catch {
                $status = "Failed"
                $errorMessage = $_.Exception.Message
                Write-Warning "Failed on $($mbx.UserPrincipalName): $errorMessage"
            }
        }
    }

    $results += [PSCustomObject]@{
        UserPrincipalName = $mbx.UserPrincipalName
        PrimarySmtpAddress = $primary
        OldSip            = $currentPrimarySipAddress
        NewSip            = $primary
        Status            = $status
        Error             = $errorMessage
        Timestamp         = (Get-Date)
    }
}

$results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

$successCount = ($results | Where-Object { $_.Status -eq 'Success' }).Count
$issueCount   = ($results | Where-Object { $_.Status -notin @('Success', 'Skipped - already matches', 'DryRun - no change made') }).Count

Write-Host "`nDone. $successCount updated, $issueCount need attention, out of $($results.Count) total mailboxes." -ForegroundColor Green
Write-Host "Full log written to: $LogPath" -ForegroundColor Green
if ($issueCount -gt 0) {
    Write-Host "Review rows with Status Failed in the log before considering this step complete." -ForegroundColor Yellow
}
