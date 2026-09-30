<#
.SYNOPSIS
    Emails each user in a CSV their new username and password, sent from your own account.

.DESCRIPTION
    Expected CSV columns (header row required): email, username, password
    Optional column: name  (used in the greeting; falls back to the username)

    Without -Send the script does a dry run: it previews the first email and lists recipients.

.EXAMPLE
    .\Send-Credentials.ps1 -CsvPath .\users.csv            # dry run, nothing sent
    .\Send-Credentials.ps1 -CsvPath .\users.csv -Send      # actually sends
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [switch]$Send
)

# ---------------------------------------------------------------------------
# SETTINGS - edit these
# ---------------------------------------------------------------------------
$SenderEmail  = "you@example.com"      # your email address
$SenderName   = "IT Support"           # name recipients will see

# Common SMTP servers (all use port 587):
#   Gmail:          smtp.gmail.com
#   Outlook.com:    smtp-mail.outlook.com
#   Microsoft 365:  smtp.office365.com
#   Yahoo:          smtp.mail.yahoo.com
$SmtpServer   = "smtp.gmail.com"
$SmtpPort     = 587

$Subject      = "Your new account login details"
$LoginUrl     = "https://example.com/login"
$DelaySeconds = 2                      # pause between emails to avoid rate limits

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

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

$rows = Import-Csv -Path $CsvPath
if (-not $rows) {
    Write-Error "CSV file appears to be empty."
    exit 1
}

# Check required columns (Import-Csv property names are case-insensitive)
$columns = $rows[0].PSObject.Properties.Name | ForEach-Object { $_.Trim().ToLower() }
$missing = @("email", "username", "password") | Where-Object { $_ -notin $columns }
if ($missing) {
    Write-Error "CSV is missing column(s): $($missing -join ', ')"
    exit 1
}

# Keep only rows with a plausible email address
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
    return $BodyTemplate -f $name, "$($user.username)".Trim(), "$($user.password)".Trim(), $LoginUrl, $SenderName
}

# ---- Dry run ----
if (-not $Send) {
    Write-Host "`nDRY RUN - nothing will be sent. Preview of the first email:`n" -ForegroundColor Cyan
    Write-Host "To: $($users[0].email)"
    Write-Host "Subject: $Subject`n"
    Write-Host (Get-Body $users[0])
    Write-Host "Recipients:"
    foreach ($u in $users) { Write-Host "  $($u.email)  (username: $($u.username))" }
    Write-Host "`nRun again with -Send to send for real." -ForegroundColor Cyan
    exit 0
}

# ---- Send for real ----
$securePass = Read-Host "Password for $SenderEmail" -AsSecureString
$credential = New-Object System.Net.NetworkCredential($SenderEmail, $securePass)

$smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
$smtp.EnableSsl   = $true       # STARTTLS
$smtp.Credentials = $credential
$smtp.Timeout     = 30000

$from   = New-Object System.Net.Mail.MailAddress($SenderEmail, $SenderName)
$sent   = 0
$failed = @()
$i      = 0

foreach ($user in $users) {
    $i++
    $to = "$($user.email)".Trim()
    try {
        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From    = $from
        $msg.To.Add($to)
        $msg.Subject = $Subject
        $msg.Body    = Get-Body $user
        $smtp.Send($msg)
        $msg.Dispose()
        $sent++
        Write-Host "[$i/$($users.Count)] Sent to $to" -ForegroundColor Green
    }
    catch {
        $err = $_.Exception.InnerException.Message
        if (-not $err) { $err = $_.Exception.Message }
        $failed += [PSCustomObject]@{ email = $to; error = $err }
        Write-Host "[$i/$($users.Count)] FAILED ${to}: $err" -ForegroundColor Red
    }
    Start-Sleep -Seconds $DelaySeconds
}

$smtp.Dispose()

Write-Host "`nDone. Sent: $sent  Failed: $($failed.Count)"
if ($failed.Count -gt 0) {
    $failed | Export-Csv -Path "failed_emails.csv" -NoTypeInformation
    Write-Host "Failed addresses written to failed_emails.csv"
}
