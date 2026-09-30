<#
    Send-Credentials-GCCHigh.ps1

    Emails each user in a CSV their new username and password through Microsoft 365 GCC High,
    using Microsoft Graph. Messages are tagged so an Exchange mail flow rule applies
    Microsoft Purview Message Encryption.

    No parameters needed: edit the SETTINGS section below, then run the script.

    CSV columns (header row required): email, username, password
    Optional column: name  (used in the greeting; falls back to the username)

    Requires the Microsoft Graph authentication module:
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
#>

# ---------------------------------------------------------------------------
# SETTINGS - edit these
# ---------------------------------------------------------------------------
$CsvPath       = "C:\Scripts\users.csv"  # full path to your CSV file

# Leave this as $true to preview without sending anything.
# Change it to $false when you're ready to send for real.
$DryRun        = $true

$SenderEmail   = "you@youragency.us"     # the mailbox the emails come from

# The encryption tag. Your Exchange admin creates a mail flow rule that encrypts
# messages from $SenderEmail whose subject contains this word (see instructions).
$EncryptTag    = "[Secure]"
$Subject       = "$EncryptTag Your new account login details"

$LoginUrl      = "https://example.com/login"
$SignatureName = "IT Support"
$DelaySeconds  = 2                        # pause between emails to avoid throttling

$BodyTemplate = @"
Hi {0},

Your account has been set up. Here are your login details:

    Username: {1}
    Temporary password: {2}

Log in here: {3}

For your security, please change your password the first time you log in.

Thanks,
{4}
"@
# ---------------------------------------------------------------------------

# GCC High uses the "USGov" Graph environment (graph.microsoft.us / login.microsoftonline.us).
# For DoD tenants, change this to "USGovDoD".
$GraphEnvironment = "USGov"

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

$rows = Import-Csv -Path $CsvPath
if (-not $rows) {
    Write-Error "CSV file appears to be empty."
    exit 1
}

$columns = $rows[0].PSObject.Properties.Name | ForEach-Object { $_.Trim().ToLower() }
$missing = @("email", "username", "password") | Where-Object { $_ -notin $columns }
if ($missing) {
    Write-Error "CSV is missing column(s): $($missing -join ', ')"
    exit 1
}

$users = @()
$lineNo = 1
foreach ($row in $rows) {
    $lineNo++
    $email = "$($row.email)".Trim()
    if (-not $email -or $email -notmatch "@") {
        Write-Host "  Skipping line ${lineNo}: missing or invalid email" -ForegroundColor Yellow
        continue
    }
    $users += $row
}

Write-Host "Found $($users.Count) user(s) in $CsvPath"
if ($users.Count -eq 0) { exit 0 }

function Get-Body($user) {
    $name = if ("$($user.name)".Trim()) { "$($user.name)".Trim() } else { "$($user.username)".Trim() }
    return $BodyTemplate -f $name, "$($user.username)".Trim(), "$($user.password)".Trim(), $LoginUrl, $SignatureName
}

# ---- Dry run ----
if ($DryRun) {
    Write-Host "`nDRY RUN - nothing will be sent. Preview of the first email:`n" -ForegroundColor Cyan
    Write-Host "From: $SenderEmail"
    Write-Host "To: $($users[0].email)"
    Write-Host "Subject: $Subject`n"
    Write-Host (Get-Body $users[0])
    Write-Host "Recipients:"
    foreach ($u in $users) { Write-Host "  $($u.email)  (username: $($u.username))" }
    Write-Host "`nSet `$DryRun = `$false in the settings to send for real." -ForegroundColor Cyan
    exit 0
}

# ---- Connect to Microsoft Graph (GCC High) ----
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Error "Microsoft Graph module not found. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    exit 1
}
Import-Module Microsoft.Graph.Authentication

try {
    Write-Host "Connecting to Graph ($GraphEnvironment) - sign in as $SenderEmail..."
    Connect-MgGraph -Environment $GraphEnvironment -Scopes "Mail.Send" -NoWelcome -ErrorAction Stop
}
catch {
    Write-Error "Could not connect to Microsoft Graph: $($_.Exception.Message)"
    exit 1
}

# ---- Send ----
$sent   = 0
$failed = @()
$i      = 0
$uri    = "v1.0/users/$SenderEmail/sendMail"

foreach ($user in $users) {
    $i++
    $to = "$($user.email)".Trim()

    $payload = @{
        message = @{
            subject      = $Subject
            body         = @{ contentType = "Text"; content = (Get-Body $user) }
            toRecipients = @(@{ emailAddress = @{ address = $to } })
            importance   = "High"
        }
        saveToSentItems = $false   # keep plaintext passwords out of your Sent Items
    } | ConvertTo-Json -Depth 6

    try {
        Invoke-MgGraphRequest -Method POST -Uri $uri -Body $payload -ContentType "application/json" -ErrorAction Stop
        $sent++
        Write-Host "[$i/$($users.Count)] Sent to $to" -ForegroundColor Green
    }
    catch {
        $failed += [PSCustomObject]@{ email = $to; error = $_.Exception.Message }
        Write-Host "[$i/$($users.Count)] FAILED ${to}: $($_.Exception.Message)" -ForegroundColor Red
    }
    Start-Sleep -Seconds $DelaySeconds
}

Disconnect-MgGraph | Out-Null

Write-Host "`nDone. Sent: $sent  Failed: $($failed.Count)"
if ($failed.Count -gt 0) {
    $failed | Export-Csv -Path "failed_emails.csv" -NoTypeInformation
    Write-Host "Failed addresses written to failed_emails.csv"
}
