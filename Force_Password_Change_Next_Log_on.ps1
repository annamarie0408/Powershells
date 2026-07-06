Import-Module Microsoft.Graph.Users

#if using commerical or GCC, remove -Environment USGov
Connect-MgGraph -Environment USGov -Scopes `
    "User.ReadWrite.All", `
    "Directory.AccessAsUser.All"

$CsvPath = "csv filepath"

$Users = Import-Csv $CsvPath

foreach ($Row in $Users) {

    $UserId = $Row.UserPrincipalName
    if (-not $UserId) { $UserId = $Row.Email }
    if (-not $UserId) { $UserId = $Row.Username }

    try {

        Write-Host "Processing $UserId..."

        # Force password change
        Update-MgUser -UserId $UserId -PasswordProfile @{
            forceChangePasswordNextSignIn = $true
        }

        # Revoke sessions/tokens
        Revoke-MgUserSignInSession -UserId $UserId

        Write-Host "SUCCESS: Password reset forced and sessions revoked for $UserId" -ForegroundColor Green
    }
    catch {
        Write-Warning "FAILED: $UserId : $($_.Exception.Message)"
    }
}

Disconnect-MgGraph
