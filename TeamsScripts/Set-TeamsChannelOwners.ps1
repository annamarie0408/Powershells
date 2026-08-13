<#
.SYNOPSIS
    Reads a CSV and assigns a specified user as Owner on the matching Teams channel.

.DESCRIPTION
    For each row in the CSV, the script:
      1. Finds the Team by display name.
      2. Finds the Channel within that team by name.
      3. Adds the specified user as an Owner of that channel.

    Requires the MicrosoftTeams module:
        Install-Module -Name MicrosoftTeams -Scope CurrentUser

    Note: Owner role at the channel level only applies to private/shared channels.
    Standard channels don't have channel-level owners — ownership there is
    at the team level. If you're working with standard channels, let me know
    and I'll adjust this to add the user as a Team owner instead.

.CSV FORMAT
    TeamName,ChannelName,UserPrincipalName
    Contoso Sales,Q3 Planning,jane.doe@contoso.com
    Contoso Sales,Budget,john.smith@contoso.com

.NOTES
    Update the $CsvPath variable below to point to your file.
    Set $WhatIf to $true to preview changes, $false to apply them.
#>

$CsvPath = ".\channels_table.csv"

# Set to $true to preview what would happen without making changes, $false to actually apply them
$WhatIf = $false

# Connect to Microsoft Teams (will prompt for auth if not already connected)
try {
    Get-Team -NumberOfThreads 1 -ErrorAction Stop | Select-Object -First 1 | Out-Null
}
catch {
    Connect-MicrosoftTeams | Out-Null
}

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found at path: $CsvPath"
    exit 1
}

$rows = Import-Csv -Path $CsvPath

# Cache team lookups so we don't call Get-Team repeatedly for the same team
$teamCache = @{}

foreach ($row in $rows) {

    $teamName    = $row.TeamName
    $channelName = $row.ChannelName
    $userUpn     = $row.UserPrincipalName

    if (-not $teamName -or -not $channelName -or -not $userUpn) {
        Write-Warning "Skipping row with missing data: $($row | Out-String)"
        continue
    }

    Write-Host "Processing: Team='$teamName' Channel='$channelName' User='$userUpn'" -ForegroundColor Cyan

    # Look up the team (cached)
    if (-not $teamCache.ContainsKey($teamName)) {
        $team = Get-Team -DisplayName $teamName -ErrorAction SilentlyContinue
        if (-not $team) {
            Write-Warning "  Team not found: $teamName"
            continue
        }
        if ($team.Count -gt 1) {
            Write-Warning "  Multiple teams matched '$teamName'. Using the first match (GroupId: $($team[0].GroupId)). Consider using exact names to avoid ambiguity."
            $team = $team[0]
        }
        $teamCache[$teamName] = $team
    }
    $team = $teamCache[$teamName]

    # Look up the channel within that team
    $channel = Get-TeamChannel -GroupId $team.GroupId -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $channelName }

    if (-not $channel) {
        Write-Warning "  Channel not found: '$channelName' in team '$teamName'"
        continue
    }

    # Add the user as owner of the channel
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would add $userUpn as Owner of '$channelName' (Team: '$teamName')" -ForegroundColor Yellow
    }
    else {
        try {
            Add-TeamChannelUser -GroupId $team.GroupId -DisplayName $channel.DisplayName -User $userUpn -Role Owner -ErrorAction Stop
            Write-Host "  Added $userUpn as Owner of '$channelName'" -ForegroundColor Green
        }
        catch {
            Write-Warning "  Failed to add $userUpn as owner of '$channelName': $_"
        }
    }
}

Write-Host "`nDone." -ForegroundColor Cyan
