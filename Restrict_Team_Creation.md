# Restricting Microsoft Teams Creation to a Specific Security Group

By default, any user in a Microsoft 365 tenant can create a new Team (which creates a Microsoft 365 Group under the hood). Many orgs want to lock this down so only certain people — without making them full admins — can create (and, as owners, delete) Teams.

There's no GUI-only way to scope Team/group creation to a specific security group. The Microsoft 365 admin center only exposes a global on/off toggle. Restricting it to a chosen group requires a short, one-time PowerShell script using the Microsoft Graph PowerShell SDK (Beta module).

This guide walks through the full setup: prerequisites, the script, verification, and rollback.

## What this does — and doesn't — do

- ✅ Lets members of a chosen security group create new Teams / Microsoft 365 Groups.
- ✅ Team creators automatically become **owners** of the teams they create, so they can delete those teams themselves — no extra permission needed for that.
- ❌ Does **not** grant the ability to delete or manage teams they *don't* own. That requires an actual admin role (e.g., Teams Administrator).
- ❌ Also affects Outlook Groups, SharePoint team sites, Planner, and Viva Engage communities — this setting is tenant-wide for Microsoft 365 Group creation, not Teams-specific.
- ❌ Does not affect standalone SharePoint site creation (a separate setting in the SharePoint admin center).

## Prerequisites

- A Global Administrator or Groups Administrator account to run the script.
- An existing security group in Entra ID containing the users you want to allow (e.g. `Team_Site_Creators`).
- PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+.

## Step 1 — Install the required modules

These are Beta-profile modules — the directory settings template used here (`Group.Unified`) is only exposed through the Beta cmdlets, not the GA `Microsoft.Graph` module.

```powershell
Install-Module Microsoft.Graph.Beta.Identity.DirectoryManagement -Scope CurrentUser -Force
Install-Module Microsoft.Graph.Beta.Groups -Scope CurrentUser -Force
```

Only needs to be run once per machine.

## Step 2 — Connect to Microsoft Graph

```powershell
Connect-MgGraph -Scopes "Directory.ReadWrite.All", "Group.Read.All"
```

This opens an interactive sign-in prompt. Sign in with an account that has Global Administrator or Groups Administrator rights.

## Step 3 — Apply the restriction

```powershell

#Install the Beta modules needed for directory settings (only needed once, ever, on this machine)
Install-Module Microsoft.Graph.Beta.Identity.DirectoryManagement -Scope CurrentUser -Force
Install-Module Microsoft.Graph.Beta.Groups -Scope CurrentUser -Force

# Set your variables
$GroupName = "Team_Site_Creators"   # <-- replace with your actual security group name
$AllowGroupCreation = "False"       # turns off open creation for everyone else

# Get (or create) the Group.Unified settings object
$settingsObjectID = (Get-MgBetaDirectorySetting | Where-Object -Property DisplayName -Value "Group.Unified" -EQ).Id

if (-not $settingsObjectID) {
    $params = @{
        templateId = "62375ab9-6b52-47ed-826b-58e47e0e304b"   # Group.Unified template ID
        values     = @(
            @{ name = "EnableMSStandardBlockedWords"; value = "false" }
        )
    }
    New-MgBetaDirectorySetting -BodyParameter $params
    $settingsObjectID = (Get-MgBetaDirectorySetting | Where-Object -Property DisplayName -Value "Group.Unified" -EQ).Id
}

# Find your security group's Object ID
$groupId = (Get-MgBetaGroup -All | Where-Object { $_.DisplayName -eq $GroupName }).Id
$groupId   # confirm this printed a real GUID, not blank

# Apply the restriction
$params = @{
    templateId = "62375ab9-6b52-47ed-826b-58e47e0e304b"
    values     = @(
        @{ name = "EnableGroupCreation"; value = $AllowGroupCreation }
        @{ name = "GroupCreationAllowedGroupId"; value = $groupId }
    )
}
Update-MgBetaDirectorySetting -DirectorySettingId $settingsObjectID -BodyParameter $params
```

> **Note:** If `$groupId` prints blank in Step 3, the group name didn't match exactly — check for typos or extra spaces before continuing.

Changes can take up to ~15 minutes to propagate.

## Step 4 — Verify the setting

Run this any time (in a new session too) to confirm current state:

```powershell
Connect-MgGraph -Scopes "Directory.ReadWrite.All", "Group.Read.All"

$settings = Get-MgBetaDirectorySetting | Where-Object -Property DisplayName -Value "Group.Unified" -EQ
$settings.Values
```

To check just the two relevant values:

```powershell
$settings.Values | Where-Object { $_.Name -in @("EnableGroupCreation", "GroupCreationAllowedGroupId") }
```

To confirm the allowed-group ID actually points to the group you expect:

```powershell
$allowedGroupId = ($settings.Values | Where-Object { $_.Name -eq "GroupCreationAllowedGroupId" }).Value
Get-MgBetaGroup -GroupId $allowedGroupId | Select-Object DisplayName, Id
```

This should return your security group's display name. If it returns something else or errors, the restriction is pointed at the wrong group.

**The real-world test:** reading the setting back only confirms the config, not actual behavior. To be sure it's working, sign in as a test user who is *not* in the security group and confirm they can't create a new Team. This also catches propagation delays or other admin roles bypassing the restriction.

## Who can still create groups regardless of this setting

Certain admin roles retain group/Team creation rights through their own admin centers even after this restriction is applied: Teams Service Administrator, SharePoint Administrator, Groups Administrator, and a few similar roles. This setting affects regular end users, not other admins.

## Rolling back

To remove the restriction and let all users create Teams again:

```powershell
$settings = Get-MgBetaDirectorySetting | Where-Object -Property DisplayName -Value "Group.Unified" -EQ
$params = @{
    values = @(
        @{ name = "EnableGroupCreation"; value = "True" }
    )
}
Update-MgBetaDirectorySetting -DirectorySettingId $settings.Id -BodyParameter $params
```

## Related settings (not covered by this script)

| What you want to control | Where |
|---|---|
| Who can create Teams/M365 Groups | This guide (Entra ID directory settings) |
| Who can delete *any* team (not just their own) | Requires assigning the **Teams Administrator** role — no granular in-between permission exists |
| Who can create standalone SharePoint sites | SharePoint admin center → Settings → Site creation (separate toggle, also all-or-nothing) |

## Disclaimer

This guide reflects Microsoft Graph PowerShell SDK behavior as of mid-2026. Microsoft periodically updates module names, cmdlet names, and template IDs — if a cmdlet in this guide errors out, check the [official Microsoft Learn docs](https://learn.microsoft.com/en-us/entra/identity/users/groups-settings-cmdlets) for the current syntax before assuming your environment is misconfigured.
