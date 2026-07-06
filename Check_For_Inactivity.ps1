
Connect-MgGraph -Scopes "AuditLog.Read.All","User.Read.All"
 
$days = 95
$cutoffDate = (Get-Date).AddDays(-$days)
 
Get-MgUser -All -Property DisplayName,UserPrincipalName,AccountEnabled,SignInActivity |
Where-Object {
    $_.AccountEnabled -eq $true -and
    (
        $_.SignInActivity.LastSignInDateTime -lt $cutoffDate -or
        $null -eq $_.SignInActivity.LastSignInDateTime
    )
} |
Select-Object DisplayName,UserPrincipalName,
    @{Name="LastSignIn";Expression={$_.SignInActivity.LastSignInDateTime}} |
Sort-Object LastSignIn
