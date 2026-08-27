# Excluding Windows 365 from a Block-All Conditional Access Policy

## The Problem

A common Conditional Access (CA) setup blocks access to all cloud apps by
default, with a small number of explicit exclusions for approved services.
If you need to add Windows 365 web access to that exclusion list, so users on
devices that can't run the desktop app can still reach their Cloud PC through
a browser, the obvious first attempt will fail.

The obvious first move, excluding the app named **"Windows 365 Portal"**
(`3b511579-5e00-46e1-a89e-a6f0870e2f5a`), which is what shows up in the Entra
sign-in logs when a user's request gets blocked, does not work. Both the
Entra admin center UI and the Microsoft Graph API reject it:

```
Update-MgIdentityConditionalAccessPolicy : 1034: Policy contains invalid applications:
{"3b511579-5e00-46e1-a89e-a6f0870e2f5a":"UnsupportedFirstPartyApplication"}
```

## Why This Happens

Not every first-party Microsoft service principal is a valid Conditional
Access target. Per Microsoft's own documentation:

> Applications that are available to Conditional Access go through an
> onboarding and validation process. These applications don't include all
> Microsoft apps. Many applications are backend services that aren't meant to
> have policy directly applied to them.

**Windows 365 Portal** is one of these unsupported backend/front-end shell
apps. It's what authenticates first when a user hits `windows365.microsoft.com`
(or `windows365.microsoft.us` in GCC High), and it's what the sign-in logs
capture, but it was never onboarded as a direct CA policy target, so trying
to exclude (or include) it by AppId always fails with
`UnsupportedFirstPartyApplication`, regardless of whether you use PowerShell
or the portal UI.

The application Microsoft actually documents for this purpose is a separate
app, usually labeled **"Windows 365"** or **"Cloud PC"** in the tenant:

> Windows 365 (app ID `0af06dc6-e4b5-4f28-818e-e78e62d137a5`). For some
> tenants this app may be called Cloud PC. This app is used when retrieving
> the list of resources for the user and when users initiate actions on their
> Cloud PC like Restart.

This is the app behind the scenes that the web portal calls once initial
sign-in succeeds, and it's what actually retrieves the user's Cloud PC list and
lets them launch a session. Excluding this AppId (rather than Windows 365
Portal) from the block-all policy is the supported, documented path.

Depending on the connection type, Microsoft also lists **Azure Virtual
Desktop** (`9cdead84-a844-4324-93f2-b2e6bb768d07`, sometimes shown as
"Windows Virtual Desktop") as a related app used to authenticate the actual
remote session. If users still hit a block after excluding the Windows 365
app alone, check the sign-in log for a new blocked app in the chain and add
it the same way.

## Checking Whether the Service Principal Exists

Before excluding the app, confirm its service principal is actually present
in your tenant:

```powershell
Get-MgServicePrincipal -Filter "AppId eq '0af06dc6-e4b5-4f28-818e-e78e62d137a5'"
```

Service principals for first-party Microsoft apps are sometimes only created
in a tenant after a user or admin has interacted with that app at least once.
If nothing has ever triggered it, the query above can come back empty even
though the app itself is valid.

If it comes back empty, provision it directly:

```powershell
New-MgServicePrincipal -AppId "0af06dc6-e4b5-4f28-818e-e78e62d137a5"
```

Once the service principal exists, excluding this AppId from the policy
should clear validation, since it's the Microsoft-documented target app for
this scenario rather than an unsupported backend app like Windows 365
Portal. The full scripts below already include this check automatically, so
you don't need to run it separately if you're using them as-is.

## Before You Run Anything

- The service principal for `0af06dc6-e4b5-4f28-818e-e78e62d137a5` may not
  exist yet in your tenant if no one has used Windows 365 in a way that
  triggered its creation. The script below creates it if missing.
- This only **appends** to the existing `ExcludeApplications` list on the
  policy. It does not touch `IncludeApplications` or replace any existing
  exclusions.
- Test in a non-production policy or with a pilot user/group before applying
  to your live block-all policy.
- GCC High runs on a separate Entra ID Government instance with its own
  Graph API endpoint. You must connect with `-Environment USGov` (or
  `-Environment USGovDoD` for DoD tenants). Connecting to commercial Graph
  by default will query the wrong tenant entirely.

## PowerShell for Commercial and GCC

```powershell
# Connect to commercial Graph with the required scopes
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Application.Read.All"

$w365AppId = "0af06dc6-e4b5-4f28-818e-e78e62d137a5"

# Ensure the service principal exists in this tenant; creates it if missing
if (-not (Get-MgServicePrincipal -Filter "AppId eq '$w365AppId'")) {
    New-MgServicePrincipal -AppId $w365AppId
}

# Get your block-all CA policy
$policy = Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.DisplayName -eq "Block All Cloud Apps" }
$policy | Select-Object Id, DisplayName

# Pull the current exclude list so we only append, never overwrite
$currentExcludes = $policy.Conditions.Applications.ExcludeApplications
if ($null -eq $currentExcludes) { $currentExcludes = @() }

$updatedExcludes = $currentExcludes + $w365AppId

# Confirm before writing
Write-Host "Current excludes: $currentExcludes"
Write-Host "New excludes after append: $updatedExcludes"

# Apply. Only ExcludeApplications is modified
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id `
    -Conditions @{
        Applications = @{
            ExcludeApplications = $updatedExcludes
        }
    }

# Verify
Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id |
    Select-Object -ExpandProperty Conditions |
    Select-Object -ExpandProperty Applications
```

## PowerShell for GCC High

Identical logic, connected to the Government Graph environment instead:

```powershell
# Connect to Graph in the Government cloud with the required scopes
Connect-MgGraph -Environment USGov -Scopes "Policy.ReadWrite.ConditionalAccess","Application.Read.All"

# Confirm you're actually in the Gov environment before doing anything else
Get-MgContext | Select-Object Environment, Scopes

$w365AppId = "0af06dc6-e4b5-4f28-818e-e78e62d137a5"

# Ensure the service principal exists in this tenant; creates it if missing
if (-not (Get-MgServicePrincipal -Filter "AppId eq '$w365AppId'")) {
    New-MgServicePrincipal -AppId $w365AppId
}

# Get your block-all CA policy
$policy = Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.DisplayName -eq "Block All Cloud Apps" }
$policy | Select-Object Id, DisplayName

# Pull the current exclude list so we only append, never overwrite
$currentExcludes = $policy.Conditions.Applications.ExcludeApplications
if ($null -eq $currentExcludes) { $currentExcludes = @() }

$updatedExcludes = $currentExcludes + $w365AppId

# Confirm before writing
Write-Host "Current excludes: $currentExcludes"
Write-Host "New excludes after append: $updatedExcludes"

# Apply. Only ExcludeApplications is modified
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id `
    -Conditions @{
        Applications = @{
            ExcludeApplications = $updatedExcludes
        }
    }

# Verify
Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id |
    Select-Object -ExpandProperty Conditions |
    Select-Object -ExpandProperty Applications
```

## Testing

1. Have a test user (ideally the one who originally reported the block)
   attempt to sign in to the Windows 365 web portal:  
   - Commercial/GCC: `https://windows365.microsoft.com`
   - GCC High: `https://windows365.microsoft.us` or `https://rdweb.wvd.azure.us/arm/webclient`
2. If they're still blocked, pull their sign-in log and check which app the
   failure is now attributed to. If it's a different app than before (for
   example, Azure Virtual Desktop), repeat the exclusion process for that
   AppId as well.
3. Confirm existing restrictions (clipboard, file transfer, drive
   redirection) still apply correctly once the session loads. This
   exclusion only affects CA sign-in enforcement, not the session-level
   redirection policies configured separately via Intune/GPO.

## Reference App IDs

| App | AppId | Notes |
|---|---|---|
| Windows 365 Portal | `3b511579-5e00-46e1-a89e-a6f0870e2f5a` | Shows in sign-in logs; **not** a valid CA target |
| Windows 365 / Cloud PC | `0af06dc6-e4b5-4f28-818e-e78e62d137a5` | Correct app to exclude; retrieves Cloud PC list and session actions |
| Azure Virtual Desktop / Windows Virtual Desktop | `9cdead84-a844-4324-93f2-b2e6bb768d07` | Add if still blocked after excluding Windows 365 |
