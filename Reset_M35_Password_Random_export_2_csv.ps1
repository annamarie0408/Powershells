# Ensure Microsoft Graph module is installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Connect to Microsoft Graph with required permissions
# Ensure you have Global Admin or user Administrator access
Connect-MgGraph -Scopes "Directory.AccessAsUser.All" -Environment USGov

# Path to input CSV (must contain a column named 'UserPrincipalName')
$InputCsv = "" # Enter your path here

# Path to output CSV
$OutputCsv = "" # Enter your path here; will be created if it doesn't exist

# Import users from CSV
try {
    $users = Import-Csv -Path $InputCsv
} catch {
    Write-Error "Failed to read CSV file: $_"
    exit
}

# Prepare results array
$results = @()

foreach ($user in $users) {
    $upn = $user.UserPrincipalName

    if ([string]::IsNullOrWhiteSpace($upn)) {
        Write-Warning "Skipping entry with missing UPN."
        continue
    }

    # Generate password: Words + 6 random digits + !
    $randomDigits = Get-Random -Minimum 100000 -Maximum 1000000
    $newPassword = "Words$randomDigits!" # Example output: Words482913!

    try {
        # Update password in Microsoft 365
        Update-MgUser -UserId $upn -PasswordProfile @{
            ForceChangePasswordNextSignIn = $true
            Password = $newPassword
        }

        Write-Host "Password updated for $upn" -ForegroundColor Green

        # Add to results
        $results += [PSCustomObject]@{
            UserPrincipalName = $upn
            NewPassword       = $newPassword
        }
    }
    catch {
    $errorDetail = $_.Exception.Message
    if ($_.Exception.InnerException) {
        $errorDetail += " | Inner: $($_.Exception.InnerException.Message)"
    }
    Write-Error "Failed to update password for $upn : $errorDetail"
}
}

# Export results to CSV
try {
    $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Password reset complete. Results saved to $OutputCsv" -ForegroundColor Cyan
} catch {
    Write-Error "Failed to export results: $_"
}

# Disconnect from Graph
Disconnect-MgGraph


