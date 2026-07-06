# Variables
$csvPath = "pathToCSV.csv"
$groupEmail = "Name of Group"

# Import users from CSV using the column 'email'
$csvUsers = Import-Csv -Path $csvPath | Select-Object -ExpandProperty Email

# Get Group ID
$group = Get-MgGroup -Filter "mail eq '$groupEmail'"
$groupId = $group.Id

# Get current members and their object IDs
$currentMembers = Get-MgGroupMember -GroupId $groupId -All | ForEach-Object {
    [PSCustomObject]@{
        Email = $_.Mail
        Id = $_.Id
    }
}

# Determine who to add
$usersToAdd = $csvUsers | Where-Object { $_ -and ($_ -notin $currentMembers.Email) }

# Determine who to remove (by comparing emails)
$usersToRemove = $currentMembers | Where-Object { $_.Email -and ($_.Email -notin $csvUsers) }

# Add users
foreach ($email in $usersToAdd) {
    try {
        $user = Get-MgUser -Filter "mail eq '$email'"
        if ($user) {
            New-MgGroupMemberByRef -GroupId $groupId -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
            Write-Host "Added: $email"
        } else {
            Write-Host "User not found in directory: $email"
        }
    } catch {
        Write-Host "Failed to add $email $_"
    }
}

# Remove users
foreach ($member in $usersToRemove) {
    try {
        Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $member.Id -Confirm:$false
        Write-Host "Removed: $($member.Email)"
    } catch {
        Write-Host "Failed to remove $($member.Email) $_"
    }
}
