Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Groups

Connect-MgGraph -Scopes "User.Read.All", "Group.ReadWrite.All"

$CsvPath = "csv filepath"
$GroupName = "group name"

$Group = Get-MgGroup -Filter "displayName eq '$GroupName'"

if (-not $Group) {
    throw "Security group not found: $GroupName"
}

$Rows = Import-Csv -Path $CsvPath

foreach ($Row in $Rows) {
    $FullName = $Row.User.Trim()

    try {
        $MatchedUsers = @(Get-MgUser `
            -Filter "displayName eq '$FullName'" `
            -Property Id,DisplayName,Mail,UserPrincipalName `
            -ErrorAction Stop)

        if ($MatchedUsers.Count -eq 0) {
            Write-Warning "No user found for: $FullName"
            continue
        }

        if ($MatchedUsers.Count -gt 1) {
            Write-Warning "Multiple users found for $FullName. Skipping."
            $MatchedUsers | Select-Object DisplayName, Mail, UserPrincipalName
            continue
        }

        $User = $MatchedUsers[0]

        $Body = @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($User.Id)"
        }

        New-MgGroupMemberByRef `
            -GroupId $Group.Id `
            -BodyParameter $Body `
            -ErrorAction Stop

        Write-Host "Added $($User.DisplayName) <$($User.UserPrincipalName)> to $GroupName" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to add $FullName : $($_.Exception.Message)"
    }
}

Disconnect-MgGraph
