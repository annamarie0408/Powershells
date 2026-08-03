<#
.SYNOPSIS
    Checks every mailbox's primary email address against a target domain.
    If it doesn't match, makes an address on that domain the new primary
    and keeps the old primary address as a secondary alias.

.DESCRIPTION
    Connects to Exchange Online and pulls every mailbox. For each one:
      - If the primary SMTP address is already on the target domain, skip it.
      - If a secondary alias on the target domain already exists, that
        address is promoted to primary.
      - Otherwise, a new address is built from the mailbox's existing
        nickname (the part before the @) on the target domain and
        promoted to primary.
    In all cases the previous primary address is automatically kept on
    the mailbox as a secondary alias, so nothing stops working - old
    addresses will still deliver mail.

    Set $WhatIfMode = $true (the default) to preview changes with no
    writes made. Set it to $false to actually apply them.

.PARAMETER TargetDomain
    The domain you want every mailbox to have an address on, e.g. contoso.com

.PARAMETER LogPath
    Where to write the CSV summary of what was found/changed. Defaults to
    .\EmailAliasAudit_<timestamp>.csv in the current folder.

.PARAMETER WhatIf
    Standard PowerShell switch. Shows what would happen without making
    any changes. Strongly recommend running this first.

.EXAMPLE
    Just edit the config values below and run:
    .\Add-EmailAliasByDomain.ps1
#>

# ============================================================================
# CONFIG - edit these before running
# ============================================================================

$TargetDomain = "Domain.com"                                              # domain every mailbox should have an address on
$LogPath      = "C:\Users\public\Desktop\EmailAliasAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"  # where the summary CSV gets written
$WhatIfMode   = $true                                                       # $true = preview only, no changes made. Set to $false to actually apply changes.
$CloudEnvironment = "GCCHigh"                                           # "Commercial" or "GCCHigh"

# ============================================================================

# --- Connect ---------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Error "The ExchangeOnlineManagement module isn't installed. Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser"
    return
}

Import-Module ExchangeOnlineManagement -ErrorAction Stop

$existingSession = Get-ConnectionInformation -ErrorAction SilentlyContinue
if (-not $existingSession) {
    Write-Host "Connecting to Exchange Online ($CloudEnvironment)..." -ForegroundColor Cyan

    if ($CloudEnvironment -eq "GCCHigh") {
        # GCC High uses a separate cloud instance and requires this environment
        # name so auth and endpoints point at .us instead of .com.
        Connect-ExchangeOnline -ExchangeEnvironmentName O365USGovGCCHigh -ShowBanner:$false
    }
    else {
        Connect-ExchangeOnline -ShowBanner:$false
    }
}

# --- Pull mailboxes ----------------------------------------------------------

Write-Host "Retrieving all mailboxes..." -ForegroundColor Cyan
$mailboxes = Get-Mailbox -ResultSize Unlimited

Write-Host "Found $($mailboxes.Count) mailboxes. Checking against domain '$TargetDomain'..." -ForegroundColor Cyan

$results = New-Object System.Collections.Generic.List[Object]
$domainSuffix = "@$TargetDomain"
$counter = 0

try {
foreach ($mbx in $mailboxes) {

    $counter++
    Write-Host "[$counter/$($mailboxes.Count)] Checking $($mbx.PrimarySmtpAddress)..." -ForegroundColor Gray

    # Already on the target domain as PRIMARY? Nothing to do.
    if ($mbx.PrimarySmtpAddress -like "*$domainSuffix") {
        $results.Add([PSCustomObject]@{
            DisplayName    = $mbx.DisplayName
            OldPrimary     = $mbx.PrimarySmtpAddress
            NewPrimary     = $mbx.PrimarySmtpAddress
            Status         = "Already primary on target domain"
        })
        continue
    }

    $oldPrimary = $mbx.PrimarySmtpAddress

    # Hybrid/synced mailboxes are managed from on-prem AD - Exchange Online
    # will not let you change their primary address, and will throw a
    # confusing "parameter cannot be found" error if you try. Flag these
    # separately instead of attempting the change.
    if ($mbx.IsDirSynced) {
        $results.Add([PSCustomObject]@{
            DisplayName = $mbx.DisplayName
            OldPrimary  = $oldPrimary
            NewPrimary  = $null
            Status      = "SKIPPED - dir-synced mailbox, change primary on-prem (AD/Set-RemoteMailbox), then let AAD Connect sync it down"
        })
        continue
    }

    # If an address on the target domain already exists as a secondary alias,
    # promote that one instead of minting a new address.
    $existingOnDomain = $mbx.EmailAddresses | Where-Object { $_ -like "smtp:*$domainSuffix" } | Select-Object -First 1

    if ($existingOnDomain) {
        $newPrimary = $existingOnDomain -replace '^smtp:', ''
    }
    else {
        # Derive nickname from the current primary address (part before the @)
        $nickname  = ($oldPrimary -split '@')[0]
        $newPrimary = "$nickname$domainSuffix"

        # Safety check: make sure that address isn't already in use elsewhere
        $conflict = Get-Recipient -Identity $newPrimary -ErrorAction SilentlyContinue
        if ($conflict -and $conflict.Identity -ne $mbx.Identity) {
            $results.Add([PSCustomObject]@{
                DisplayName = $mbx.DisplayName
                OldPrimary  = $oldPrimary
                NewPrimary  = $null
                Status      = "SKIPPED - '$newPrimary' already used by $($conflict.DisplayName)"
            })
            continue
        }
    }

    if (-not $WhatIfMode) {
        try {
            # Build the full address list by hand instead of using
            # -PrimarySmtpAddress: lowercase every existing SMTP: (primary)
            # entry down to smtp: (secondary), drop any existing entry that
            # matches the new address so we don't end up with a duplicate,
            # then add the new address back as the primary (SMTP:, uppercase).
            # This avoids -PrimarySmtpAddress, which some RBAC roles don't
            # expose even when -EmailAddresses is available.
            $addressList = $mbx.EmailAddresses | ForEach-Object {
                if ($_ -replace '^smtp:', '' -replace '^SMTP:', '' -eq $newPrimary) {
                    $null  # drop it, will be re-added below as primary
                }
                elseif ($_ -like "SMTP:*") {
                    $_ -replace '^SMTP:', 'smtp:'  # demote old primary to secondary
                }
                else {
                    $_
                }
            } | Where-Object { $_ }

            $addressList += "SMTP:$newPrimary"

            Set-Mailbox -Identity $mbx.Identity -EmailAddresses $addressList
            $results.Add([PSCustomObject]@{
                DisplayName = $mbx.DisplayName
                OldPrimary  = $oldPrimary
                NewPrimary  = $newPrimary
                Status      = "Primary changed (old address kept as alias)"
            })
            Write-Host "  $($mbx.DisplayName): $oldPrimary -> $newPrimary (primary), old kept as alias" -ForegroundColor Green
        }
        catch {
            $results.Add([PSCustomObject]@{
                DisplayName = $mbx.DisplayName
                OldPrimary  = $oldPrimary
                NewPrimary  = $null
                Status      = "ERROR - $($_.Exception.Message)"
            })
            Write-Warning "  Failed on $($mbx.DisplayName): $($_.Exception.Message)"
        }
    }
    else {
        $results.Add([PSCustomObject]@{
            DisplayName = $mbx.DisplayName
            OldPrimary  = $oldPrimary
            NewPrimary  = $newPrimary
            Status      = "WhatIf - would change primary"
        })
    }
}
}
catch {
    Write-Warning "Loop stopped early due to an error: $($_.Exception.Message)"
}
finally {
    # This always runs, even if the loop above throws, hangs and gets
    # cancelled with Ctrl+C, or you close the window - whatever partial
    # results exist get written out so you're never left with nothing.
    if ($results.Count -gt 0) {
        $results | Export-Csv -Path $LogPath -NoTypeInformation
        Write-Host "`nWrote $($results.Count) of $($mailboxes.Count) results to $LogPath" -ForegroundColor Cyan
        $results | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
    }
    else {
        Write-Warning "No results were collected - nothing to write to CSV. Check the last mailbox printed above; that's likely where it stopped."
    }
}
