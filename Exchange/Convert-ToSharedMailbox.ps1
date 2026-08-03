<#
.SYNOPSIS
    Converts a list of Exchange Online mailboxes (from a CSV) to shared mailboxes.
    Supports both commercial/GCC and GCC High tenants.
#>

# --- Edit these values ---

$CsvPath = "C:\Users\AnnaBoyer\OneDrive - Atlantic Digital\Desktop\Clients\HHS\Emails2Change.csv"       # CSV needs a single column header: EmailAddress
$LogPath = "C:\Users\AnnaBoyer\OneDrive - Atlantic Digital\Desktop\Clients\HHS\ConvertToShared_Results.csv"

# Set to "GCC" for commercial/GCC tenants, or "GCCHigh" for GCC High
$Environment = "GCC"

# Set to $true to preview what would happen without making any changes
$WhatIfMode = $false

# --- Map environment choice to the Exchange Online endpoint ---
switch ($Environment) {
    "GCC"     { $ExchangeEnvironmentName = "O365Default" }
    "GCCHigh" { $ExchangeEnvironmentName = "O365USGovGCCHigh" }
    default {
        Write-Error "Invalid `$Environment value: '$Environment'. Use 'GCC' or 'GCCHigh'."
        exit 1
    }
}

# --- Connect to Exchange Online if not already connected ---
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "ExchangeOnlineManagement module not found. Installing..." -ForegroundColor Yellow
    Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
}

$existingSession = Get-ConnectionInformation -ErrorAction SilentlyContinue
if (-not $existingSession) {
    Write-Host "Connecting to Exchange Online ($Environment)..." -ForegroundColor Cyan
    Connect-ExchangeOnline -ExchangeEnvironmentName $ExchangeEnvironmentName -ShowBanner:$false
}

# --- Load mailbox list from CSV ---
if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found at path: $CsvPath"
    exit 1
}

if ($WhatIfMode) {
    Write-Host "WhatIf mode is ON - no changes will actually be made." -ForegroundColor Yellow
}

$Mailboxes = (Import-Csv $CsvPath).EmailAddress

if (-not $Mailboxes -or $Mailboxes.Count -eq 0) {
    Write-Error "No mailboxes found in CSV. Make sure it has an 'EmailAddress' column with values."
    exit 1
}

$results = foreach ($mbx in $Mailboxes) {

    $mbx = $mbx.Trim()
    if ([string]::IsNullOrWhiteSpace($mbx)) { continue }

    Write-Host "Processing $mbx..." -ForegroundColor Cyan

    try {
        $current = Get-Mailbox -Identity $mbx -ErrorAction Stop

        if ($current.RecipientTypeDetails -eq "SharedMailbox") {
            Write-Host "  Already a shared mailbox. Skipping." -ForegroundColor Yellow
            [PSCustomObject]@{
                Mailbox = $mbx
                Status  = "Skipped - Already Shared"
                Error   = ""
            }
            continue
        }

        Set-Mailbox -Identity $mbx -Type Shared -WhatIf:$WhatIfMode -ErrorAction Stop

        if ($WhatIfMode) {
            Write-Host "  [WhatIf] Would convert to shared." -ForegroundColor Yellow
            [PSCustomObject]@{
                Mailbox = $mbx
                Status  = "WhatIf - Would Convert"
                Error   = ""
            }
        }
        else {
            Write-Host "  Converted successfully." -ForegroundColor Green
            [PSCustomObject]@{
                Mailbox = $mbx
                Status  = "Converted"
                Error   = ""
            }
        }
    }
    catch {
        Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
        [PSCustomObject]@{
            Mailbox = $mbx
            Status  = "Failed"
            Error   = $_.Exception.Message
        }
    }
}

$results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Done. Results logged to $LogPath" -ForegroundColor Cyan
$results | Format-Table -AutoSize
