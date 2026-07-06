Connect-MgGraph -Scopes "User.ReadWrite.All"

$Users = Import-Csv "UsersToDisable.csv - filepath to csv"

foreach ($User in $Users) {
    try {
        Update-MgUser `
            -UserId $User.UserPrincipalName `
            -AccountEnabled:$false `
            -ErrorAction Stop

        Write-Host "Disabled: $($User.UserPrincipalName)" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed: $($User.UserPrincipalName)" -ForegroundColor Red
    }
}

