# Clear all members from Microsoft 365 Group

# Set group email
$groupEmail = "group name"

# Get Group ID
$group = Get-MgGroup -Filter "mail eq '$groupEmail'"
$groupId = $group.Id

# Get all current members with IDs
$currentMembers = Get-MgGroupMember -GroupId $groupId -All | ForEach-Object {
    [PSCustomObject]@{
        Email = $_.Mail
        Id = $_.Id
    }
}

# Remove all members
foreach ($member in $currentMembers) {
    try {
        Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $member.Id -Confirm:$false
        Write-Host "Removed: $($member.Email)"
    } catch {
        Write-Host "Failed to remove $($member.Email): $_"
    }
}
