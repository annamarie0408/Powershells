<#
.SYNOPSIS
    Reads a CSV and assigns a specified user as Owner on the matching Teams channel,
    using the Microsoft Graph SDK instead of the MicrosoftTeams module.

.DESCRIPTION
    The MicrosoftTeams module's Add-TeamChannelUser cmdlet has a known history of
    unreliable BadGateway errors on channel membership writes. This version does the
    same job through Microsoft.Graph.Teams, which tends to be more stable for this
    specific operation.

    For each row in the CSV, the script:
      1. Finds the Team (Microsoft 365 Group) by display name.
      2. Finds the Channel within that team by name.
      3. Adds the specified user as an Owner of that channel.

    Requires the Microsoft Graph PowerShell SDK:
        Install-Module Microsoft.Graph -Scope CurrentUser

    Note: Owner role at the channel level only applies to private/shared channels.
    Standard channels don't have channel-level owners — ownership there is at the
    team level. Let me know if you're working with standard channels and I'll adjust
    this to add the user as a Team owner instead.

.CSV FORMAT
    TeamName,ChannelName,UserPrincipalName
    Contoso Sales,Q3 Planning,jane.doe@contoso.com
    Contoso Sales,Budget,john.smith@contoso.com

.NOTES
    Update the $CsvPath variable below to point to your file.
    Set $WhatIf to $true to preview changes, $false to apply them.
    Rows that fail after retries are logged to .\failed_rows.csv.
#>

$CsvPath = ".\channels_table.csv"

# Set to $true to preview what would happen without making changes, $false to actually apply them
$WhatIf = $true

# Connect to Microsoft Graph with the scopes needed to read teams/channels and write membership
$requiredScopes = @("TeamMember.ReadWrite.All", "ChannelMember.ReadWrite.All", "Team.ReadBasic.All", "Channel.ReadBasic.All", "Group.Read.All")

$context = Get-MgContext
if (-not $context -or ($requiredScopes | Where-Object { $_ -notin $context.Scopes })) {
    Connect-MgGraph -Scopes $requiredScopes
}

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found at path: $CsvPath"
    exit 1
}

$rows = Import-Csv -Path $CsvPath

# Cache team and channel lookups so we don't re-query for repeated teams
$teamCache    = @{}
$channelCache = @{}

foreach ($row in $rows) {

    $teamName    = $row.TeamName
    $channelName = $row.ChannelName
    $userUpn     = $row.UserPrincipalName

    if (-not $teamName -or -not $channelName -or -not $userUpn) {
        Write-Warning "Skipping row with missing data: $($row | Out-String)"
        continue
    }

    Write-Host "Processing: Team='$teamName' Channel='$channelName' User='$userUpn'" -ForegroundColor Cyan

    # Look up the team (cached) — Teams are Microsoft 365 Groups under the hood
    if (-not $teamCache.ContainsKey($teamName)) {
        $group = Get-MgGroup -Filter "displayName eq '$($teamName -replace "'", "''")'" -ErrorAction SilentlyContinue
        if (-not $group) {
            Write-Warning "  Team not found: $teamName"
            continue
        }
        if ($group.Count -gt 1) {
            Write-Warning "  Multiple teams matched '$teamName'. Using the first match (Id: $($group[0].Id)). Consider using exact names to avoid ambiguity."
            $group = $group[0]
        }
        $teamCache[$teamName] = $group
    }
    $team = $teamCache[$teamName]

    # Look up the channel within that team (cached per team)
    $cacheKey = "$($team.Id)|$channelName"
    if (-not $channelCache.ContainsKey($cacheKey)) {
        $channel = Get-MgTeamChannel -TeamId $team.Id -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $channelName }
        $channelCache[$cacheKey] = $channel
    }
    $channel = $channelCache[$cacheKey]

    if (-not $channel) {
        Write-Warning "  Channel not found: '$channelName' in team '$teamName'"
        continue
    }

    # Add the user as owner of the channel
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would add $userUpn as Owner of '$channelName' (Team: '$teamName')" -ForegroundColor Yellow
        continue
    }

    $maxRetries = 3
    $attempt    = 0
    $success    = $false

    while (-not $success -and $attempt -lt $maxRetries) {
        $attempt++
        try {
            $user = Get-MgUser -UserId $userUpn -ErrorAction Stop

            $body = @{
                "@odata.type"     = "#microsoft.graph.aadUserConversationMember"
                roles             = @("owner")
                "user@odata.bind" = "https://graph.microsoft.com/v1.0/users('$($user.Id)')"
            } | ConvertTo-Json

            $uri = "https://graph.microsoft.com/v1.0/teams/$($team.Id)/channels/$($channel.Id)/members"

            Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
            Write-Host "  Added $userUpn as Owner of '$channelName'" -ForegroundColor Green
            $success = $true
        }
        catch {
            if ($_.Exception.Message -match "already exists|Conflict") {
                Write-Host "  $userUpn is already a member/owner of '$channelName' — skipping" -ForegroundColor Yellow
                $success = $true
            }
            elseif ($attempt -lt $maxRetries) {
                $waitSeconds = [math]::Pow(2, $attempt) * 5
                Write-Warning "  Attempt $attempt failed for '$channelName' ($_). Retrying in $waitSeconds seconds..."
                Start-Sleep -Seconds $waitSeconds
            }
            else {
                Write-Warning "  Gave up on '$channelName' after $maxRetries attempts: $_"
                [pscustomobject]@{
                    TeamName    = $teamName
                    ChannelName = $channelName
                    UserUpn     = $userUpn
                    Error       = $_.Exception.Message
                } | Export-Csv -Path ".\failed_rows.csv" -Append -NoTypeInformation
            }
        }
    }

    Start-Sleep -Seconds 1
}

Write-Host "`nDone." -ForegroundColor Cyan
