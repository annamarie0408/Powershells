# Create users in new tenant from CSV using Microsoft Graph PowerShell

# CSV path
$CsvPath = "CSV File here"

# New domain for all users
# Do not include the @ symbol
$NewEmailDomain = "New Domain here"

# Set to $true to test only. Set to $false to actually create accounts.
$WhatIfMode = $false

# Default password for new accounts
$DefaultTempPassword = "ChangeMeNow!2026"

# Install Microsoft Graph if needed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

Import-Module Microsoft.Graph.Users

# Connect to the destination/new tenant
Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All"

# Import users
$Users = Import-Csv -Path $CsvPath

foreach ($User in $Users) {

    Write-Host ""
    Write-Host "Processing CSV user: $($User.userPrincipalName)" -ForegroundColor Cyan

    try {
        # Validate required fields
        if ([string]::IsNullOrWhiteSpace($User.displayName)) {
            throw "displayName is missing."
        }

        if ([string]::IsNullOrWhiteSpace($User.userPrincipalName)) {
            throw "userPrincipalName is missing."
        }

        if ([string]::IsNullOrWhiteSpace($User.givenName)) {
            throw "givenName is missing."
        }

        if ([string]::IsNullOrWhiteSpace($User.surname)) {
            throw "surname is missing."
        }

        # Take everything before @ from the CSV UPN
        $UserNamePart = $User.userPrincipalName.Split("@")[0]

        # Build new UPN with the new domain
        $NewUserPrincipalName = "$UserNamePart@$NewEmailDomain"

        # Default userType to Member if blank
        if ([string]::IsNullOrWhiteSpace($User.userType)) {
            $UserType = "Member"
        }
        else {
            $UserType = $User.userType
        }

        # Convert accountEnabled from CSV text to boolean
        if ([string]::IsNullOrWhiteSpace($User.accountEnabled)) {
            $AccountEnabled = $true
        }
        else {
            $AccountEnabled = [System.Convert]::ToBoolean($User.accountEnabled)
        }

        # mailNickname is required
        $MailNickname = $UserNamePart -replace '[^a-zA-Z0-9._-]', ''

        # Password profile
        $PasswordProfile = @{
            Password = $DefaultTempPassword
            ForceChangePasswordNextSignIn = $true
        }

        # Check if user already exists using the new UPN
        $ExistingUser = $null

        try {
            $ExistingUser = Get-MgUser -UserId $NewUserPrincipalName -ErrorAction Stop
        }
        catch {
            $ExistingUser = $null
        }

        if ($ExistingUser) {
            Write-Host "Skipped: User already exists with new UPN $NewUserPrincipalName" -ForegroundColor Yellow
            continue
        }

        if ($WhatIfMode -eq $true) {
            Write-Host "WhatIf: Would create user." -ForegroundColor Yellow
            Write-Host "Original CSV UPN: $($User.userPrincipalName)"
            Write-Host "New UPN: $NewUserPrincipalName"
            Write-Host "Display Name: $($User.displayName)"
            Write-Host "User Type: $UserType"
            Write-Host "Given Name: $($User.givenName)"
            Write-Host "Surname: $($User.surname)"
            Write-Host "Account Enabled: $AccountEnabled"
            Write-Host "Department: $($User.department)"
            Write-Host "Mail Nickname: $MailNickname"
            continue
        }

        # Create user with new UPN domain
        New-MgUser `
            -DisplayName $User.displayName `
            -UserPrincipalName $NewUserPrincipalName `
            -UserType $UserType `
            -GivenName $User.givenName `
            -Surname $User.surname `
            -AccountEnabled:$AccountEnabled `
            -Department $User.department `
            -MailNickname $MailNickname `
            -PasswordProfile $PasswordProfile

        Write-Host "Created: User created successfully." -ForegroundColor Green
        Write-Host "Original CSV UPN: $($User.userPrincipalName)"
        Write-Host "New UPN: $NewUserPrincipalName"
        Write-Host "Temporary Password: $DefaultTempPassword" -ForegroundColor Magenta
    }
    catch {
        Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Finished processing CSV." -ForegroundColor Cyan
