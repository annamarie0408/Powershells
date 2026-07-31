<#
.SYNOPSIS
    Reads a CSV of FirstName, LastName, NewEmail and sets NewEmail as the
    Primary SMTP address for the matching Exchange Online mailbox, without
    touching the UPN (login) at all.

.DESCRIPTION
    CSV format (header required), one row per user:

        FirstName,LastName,NewEmail
        Jane,Doe,JaneDoe@NewDomain.com

    For each row:
      1. Finds the mailbox whose FirstName + LastName match the row
         (case-insensitive, whitespace-trimmed)
      2. Adds NewEmail as a proxy address (nothing existing is removed -
         every alias already on the mailbox stays in place and keeps
         receiving mail)
      3. Promotes NewEmail to Primary SMTP address
         (the previous primary SMTP is automatically retained as a
         secondary alias, so old mail flow keeps working)
      4. UPN is never referenced or changed - login stays exactly as-is
      5. Logs every success, skip, and problem row to an output CSV

    Rows are flagged instead of guessed at when:
      - No mailbox matches the FirstName/LastName (Status: NotFound)
      - More than one mailbox matches the same FirstName/LastName
        (Status: Ambiguous - needs a human to pick the right one)
      - NewEmail's domain isn't an accepted domain in the tenant
        (Status: Failed - domain not accepted)
      - NewEmail is already the mailbox's primary (Status: Skipped - already set)
#>

# ---------------------------------------------------------------------------
# EDIT THESE before running
# ---------------------------------------------------------------------------
$CsvPath = "C:\Users\public\Desktop\test.csv"
$LogPath = "C:\Users\public\Desktop\PrimaryEmailChange_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$DryRun  = $true   # set to $true to preview changes without applying them, set to $false to run and apply changes

# ---------------------------------------------------------------------------
# Validate input file exists before doing anything else
# ---------------------------------------------------------------------------
if (-not (Test-Path $CsvPath)) {
    Write-Warning "CSV file not found at: $CsvPath"
    return
}

$rows = Import-Csv -Path $CsvPath

$requiredColumns = @('FirstName', 'LastName', 'NewEmail')
$csvColumns = $rows[0].PSObject.Properties.Name
foreach ($col in $requiredColumns) {
    if ($col -notin $csvColumns) {
        Write-Warning "CSV is missing required column: $col. Expected columns: FirstName, LastName, NewEmail"
        return
    }
}

# ---------------------------------------------------------------------------
# Connect to Exchange Online (skip if already connected)
# ---------------------------------------------------------------------------
$existingSession = Get-ConnectionInformation -ErrorAction SilentlyContinue
if (-not $existingSession) {
    Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan
    Connect-ExchangeOnline -ShowBanner:$false
}

# ---------------------------------------------------------------------------
# Pull every accepted domain once, so we can validate each row's NewEmail
# domain up front instead of failing mid-run
# ---------------------------------------------------------------------------
$acceptedDomains = (Get-AcceptedDomain).DomainName

# ---------------------------------------------------------------------------
# Pull all mailboxes once, with FirstName/LastName, so we're not hitting
# Exchange Online per-row. Index them for fast case-insensitive lookup.
# ---------------------------------------------------------------------------
Write-Host "Retrieving users..." -ForegroundColor Cyan
$users = Get-User -ResultSize Unlimited -RecipientTypeDetails UserMailbox |
    Select-Object FirstName, LastName, UserPrincipalName

Write-Host "Retrieving mailboxes..." -ForegroundColor Cyan
$mailboxData = Get-EXOMailbox -ResultSize Unlimited -Properties UserPrincipalName, PrimarySmtpAddress, EmailAddresses |
    Select-Object UserPrincipalName, PrimarySmtpAddress, EmailAddresses

# Merge: FirstName/LastName come from Get-User, PrimarySmtpAddress from Get-EXOMailbox, joined on UPN
$mailboxByUpn = @{}
foreach ($m in $mailboxData) {
    $mailboxByUpn[$m.UserPrincipalName] = $m
}

$mailboxes = foreach ($u in $users) {
    $m = $mailboxByUpn[$u.UserPrincipalName]
    if ($m) {
        [PSCustomObject]@{
            FirstName          = $u.FirstName
            LastName           = $u.LastName
            UserPrincipalName  = $u.UserPrincipalName
            PrimarySmtpAddress = $m.PrimarySmtpAddress
            EmailAddresses     = $m.EmailAddresses
            Identity           = $u.UserPrincipalName
        }
    }
}

$mailboxLookup = @{}
foreach ($mbx in $mailboxes) {
    $key = "$($mbx.FirstName)|$($mbx.LastName)".Trim().ToLower()
    if (-not $mailboxLookup.ContainsKey($key)) {
        $mailboxLookup[$key] = @()
    }
    $mailboxLookup[$key] += $mbx
}

$results = @()

foreach ($row in $rows) {

    $firstName = $row.FirstName.Trim()
    $lastName  = $row.LastName.Trim()
    $newEmail  = $row.NewEmail.Trim()
    $key       = "$firstName|$lastName".ToLower()

    $status = ""
    $errorMessage = ""
    $upn = ""
    $oldPrimary = ""

    # --- Find the mailbox ---
    $matches = $mailboxLookup[$key]

    if (-not $matches -or $matches.Count -eq 0) {
        $status = "NotFound"
        Write-Warning "No mailbox found for $firstName $lastName"
    }
    elseif ($matches.Count -gt 1) {
        $status = "Ambiguous - $($matches.Count) mailboxes matched"
        Write-Warning "Multiple mailboxes matched $firstName $lastName - skipping, needs manual review."
    }
    else {
        $mbx = $matches[0]
        $upn = $mbx.UserPrincipalName
        $oldPrimary = $mbx.PrimarySmtpAddress

        # --- Validate the domain on NewEmail is accepted in this tenant ---
        $newEmailDomain = ($newEmail -split '@')[1]
        if ($newEmailDomain -notin $acceptedDomains) {
            $status = "Failed - domain not accepted"
            $errorMessage = "$newEmailDomain is not an accepted domain in this tenant"
            Write-Warning "$firstName $lastName - $errorMessage"
        }
        # --- Skip if already correct (idempotent re-runs) ---
        elseif ($oldPrimary -ieq $newEmail) {
            $status = "Skipped - already set"
        }
        else {
            Write-Host "`n$firstName $lastName" -ForegroundColor Yellow
            Write-Host "  UPN (unchanged) : $upn"
            Write-Host "  Current Primary : $oldPrimary"
            Write-Host "  New Primary     : $newEmail"

            if ($DryRun) {
                $status = "DryRun - no change made"
            }
            else {
                try {
                    # Build the corrected address list: demote whatever's
                    # currently SMTP: (primary) down to smtp:, drop any
                    # existing entry matching the new address (so we don't
                    # end up with a duplicate in a different case), then
                    # add the new address back in as the primary SMTP:.
                    # Replacing the whole collection in one call avoids
                    # ending up with two addresses both flagged primary.
                    $updatedAddresses = @()
                    foreach ($addr in $mbx.EmailAddresses) {
                        if ($addr -ieq "SMTP:$newEmail" -or $addr -ieq "smtp:$newEmail") {
                            continue  # drop it, will be re-added below as the new primary
                        }
                        elseif ($addr -clike "SMTP:*") {
                            $updatedAddresses += "smtp:" + $addr.Substring(5)  # demote old primary
                        }
                        else {
                            $updatedAddresses += $addr
                        }
                    }
                    $updatedAddresses += "SMTP:$newEmail"

                    Set-Mailbox -Identity $mbx.Identity -EmailAddresses $updatedAddresses -ErrorAction Stop

                    $status = "Success"
                }
                catch {
                    $status = "Failed"
                    $errorMessage = $_.Exception.Message
                    Write-Warning "Failed on $firstName $lastName ($upn): $errorMessage"
                }
            }
        }
    }

    $results += [PSCustomObject]@{
        FirstName         = $firstName
        LastName          = $lastName
        UserPrincipalName = $upn
        OldPrimarySmtp    = $oldPrimary
        NewEmail          = $newEmail
        Status            = $status
        Error             = $errorMessage
        Timestamp         = (Get-Date)
    }
}

# ---------------------------------------------------------------------------
# Write the audit log
# ---------------------------------------------------------------------------
$results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

$successCount = ($results | Where-Object { $_.Status -eq 'Success' }).Count
$issueCount   = ($results | Where-Object { $_.Status -notin @('Success', 'Skipped - already set', 'DryRun - no change made') }).Count

Write-Host "`nDone. $successCount updated, $issueCount need attention, out of $($results.Count) total rows." -ForegroundColor Green
Write-Host "Full log written to: $LogPath" -ForegroundColor Green
if ($issueCount -gt 0) {
    Write-Host "Review rows with Status NotFound, Ambiguous, or Failed in the log before considering this migration step complete." -ForegroundColor Yellow
}
