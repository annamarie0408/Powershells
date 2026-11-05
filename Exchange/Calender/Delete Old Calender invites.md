# Removing Orphaned Calendar Items After a Commercial to GCC High Tenant Migration

After a cross tenant migration from Microsoft 365 Commercial to GCC High, users often find their calendars full of meetings from the old tenant. These items still point to organizers in a tenant the new mailboxes can no longer reach, so users can't update them, cancel them, or remove them cleanly.

This guide walks through a safe, scoped, and auditable way to remove them with Microsoft Graph and Exchange Online RBAC for Applications, plus a Microsoft Purview purge for meetings the users organized themselves.

Throughout this guide, the following placeholders are used. Replace them with your own values.

* `olddomain.com` is the domain used in the old Commercial tenant
* `newdomain.us` is the domain used in the new GCC High tenant
* `user@newdomain.us` is any migrated user
* `<AppId>`, `<EnterpriseAppObjectId>`, `<Thumbprint>`, and `<GroupObjectId>` are values you collect during setup


## Contents

1. [Why the usual tools fall short](#why-the-usual-tools-fall-short)
2. [How this approach works](#how-this-approach-works)
3. [Prerequisites](#prerequisites)
4. [Step 1: Install the modules](#step-1-install-the-modules)
5. [Step 2: Create a certificate](#step-2-create-a-certificate)
6. [Step 3: Create the app registration](#step-3-create-the-app-registration)
7. [Step 4: Create the scope group](#step-4-create-the-scope-group)
8. [Step 5: Add old X500 addresses to the new mailboxes](#step-5-add-old-x500-addresses-to-the-new-mailboxes)
9. [Step 6: Register the app in Exchange Online](#step-6-register-the-app-in-exchange-online)
10. [Step 7: Create the management scope and role assignment](#step-7-create-the-management-scope-and-role-assignment)
11. [Step 8: Test the scope](#step-8-test-the-scope)
12. [Step 9: Notify users](#step-9-notify-users)
13. [Step 10: Run the cleanup script in preview mode](#step-10-run-the-cleanup-script-in-preview-mode)
14. [Step 11: Pilot, then run for real](#step-11-pilot-then-run-for-real)
15. [Step 12: Remove meetings the users organized](#step-12-remove-meetings-the-users-organized)
16. [Step 13: Tear everything down](#step-13-tear-everything-down)
17. [Troubleshooting](#troubleshooting)
18. [Running this in a Commercial tenant](#running-this-in-a-commercial-tenant)


## Why the usual tools fall short

**Remove-CalendarEvents** only cancels meetings the mailbox organized, and it sends cancellations to whatever attendee addresses are stored on the item. After a cross tenant move, most of those addresses point at the old tenant, so you get bounces or cancellations landing in mailboxes nobody uses anymore. It does nothing for attendee copies, which are most of what users complain about.

**Purview search and purge** can target calendar items, but it removes at most 10 items per mailbox per run. For a calendar with hundreds of old meetings, that means dozens of rounds per user. It works well for a small, targeted set of items, which is how this guide uses it in Step 12.

**Delegated Graph access with a Global Admin account** doesn't work on its own. Global Admin is a directory role, not mailbox access. You would have to grant yourself FullAccess to every mailbox and remember to remove it afterward.


## How this approach works

1. An app registration authenticates to Microsoft Graph with a certificate.
2. Exchange Online RBAC for Applications grants that app calendar access, limited to members of one security group. The app cannot touch any mailbox outside that group.
3. A PowerShell script finds every calendar item organized by an old tenant address and deletes it. It skips anything the user organized themselves, because deleting those would send cancellations.
4. Meetings the users organized are removed with a Purview purge, which deletes them at the storage level without sending any notifications.
5. Everything is removed when the work is done.


## Prerequisites

* PowerShell 7 is recommended. Windows PowerShell 5.1 works but is more prone to module conflicts.
* A Global Administrator, or an account with Application Administrator and Exchange Administrator.
* For Step 12, an account with the **Compliance Search** and **Search And Purge** roles in Microsoft Purview. The Organization Management role group includes both.
* A list of the migrated users.

> **Tip:** Keep Microsoft Graph work and Exchange Online or Purview work in separate PowerShell windows. Both module sets load their own copy of the Microsoft sign in library, and whichever loads second can fail. See [Troubleshooting](#troubleshooting).


## Step 1: Install the modules

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Calendar -Scope CurrentUser
```


## Step 2: Create a certificate

The app authenticates with a certificate instead of a client secret. This creates a self signed certificate valid for three months and exports the public key.

```powershell
$cert = New-SelfSignedCertificate -Subject "CN=CalendarCleanup" -CertStoreLocation "Cert:\CurrentUser\My" -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -NotAfter (Get-Date).AddMonths(3)

Export-Certificate -Cert $cert -FilePath "C:\Temp\CalendarCleanup.cer"

$cert.Thumbprint
```

Save the thumbprint for Step 10.


## Step 3: Create the app registration

In the GCC High Azure portal (**portal.azure.us**), go to **Microsoft Entra ID** > **App registrations** > **New registration**.

1. Name it **Calendar Cleanup**. Choose single tenant and leave the redirect URI blank.
2. Under **Certificates & secrets** > **Certificates**, upload `CalendarCleanup.cer`.
3. Under **API permissions**, add these Microsoft Graph **Application** permissions:
   * `User.Read.All`
   * `GroupMember.Read.All`
4. Click **Grant admin consent**.
5. From the **Overview** page, copy the **Application (client) ID**. This is `<AppId>`.
6. Go to **Enterprise applications**, open **Calendar Cleanup**, and copy its **Object ID**. This is `<EnterpriseAppObjectId>`.

> **Important:** Do **not** add any Calendars permission in Entra. Entra permissions and Exchange RBAC are additive. If `Calendars.ReadWrite` is consented in Entra, the app gets access to every mailbox in the tenant and the scoping in Step 7 has no effect. Calendar access is granted only through Exchange in Step 7.

> **Important:** The Object ID on the App registrations page is **not** the one you need. Exchange needs the Object ID from **Enterprise applications**.


## Step 4: Create the scope group

Create a mail enabled security group that contains only the migrated users.

```powershell
Connect-ExchangeOnline -ExchangeEnvironmentName O365USGovGCCHigh

New-DistributionGroup -Name "Calendar Cleanup Users" -Type Security -PrimarySmtpAddress calcleanup@newdomain.us
```

Add members one at a time:

```powershell
Add-DistributionGroupMember -Identity "Calendar Cleanup Users" -Member user@newdomain.us
```

Or in bulk from a CSV with a `UserPrincipalName` column:

```powershell
Import-Csv .\MigratedUsers.csv | ForEach-Object {
    Add-DistributionGroupMember -Identity "Calendar Cleanup Users" -Member $_.UserPrincipalName
}
```

Collect the group's distinguished name for Step 7:

```powershell
$GroupDN = (Get-Group "Calendar Cleanup Users").DistinguishedName
$GroupDN
```

Collect the group's Entra Object ID for Step 10:

```powershell
Get-DistributionGroup "Calendar Cleanup Users" | Select-Object Name, ExternalDirectoryObjectId
```

If `ExternalDirectoryObjectId` comes back blank, get it from Graph instead (in a separate window):

```powershell
Connect-MgGraph -Environment USGov -Scopes "Group.Read.All"
Get-MgGroup -Filter "displayName eq 'Calendar Cleanup Users'" | Select-Object DisplayName, Id
```

Start with one or two pilot users in the group. Add everyone else after the pilot succeeds.


## Step 5: Add old X500 addresses to the new mailboxes

Every mailbox in the old tenant had a `LegacyExchangeDN`. Calendar items and old emails reference users by that value. If the new mailbox doesn't carry it as an X500 proxy address, Exchange can't connect the user to their own old items, and replies to old messages fail with IMCEAEX bounces.

This step matters for the cleanup because the script uses each user's X500 to recognize and skip meetings that user organized.

If the old tenant is still available, export the values there:

```powershell
Connect-ExchangeOnline

Get-Mailbox -ResultSize Unlimited |
    Select-Object PrimarySmtpAddress, LegacyExchangeDN |
    Export-Csv .\OldLegacyDN.csv -NoTypeInformation
```

Then add them in the new tenant. This example maps users by the part of the address before the `@`. Adjust it if your naming changed during the migration.

```powershell
Connect-ExchangeOnline -ExchangeEnvironmentName O365USGovGCCHigh

Import-Csv .\OldLegacyDN.csv | ForEach-Object {
    $newAddress = ($_.PrimarySmtpAddress -split "@")[0] + "@newdomain.us"
    Set-Mailbox -Identity $newAddress -EmailAddresses @{Add = "X500:$($_.LegacyExchangeDN)"}
}
```

Verify on a user:

```powershell
Get-Mailbox user@newdomain.us | Select-Object -ExpandProperty EmailAddresses | Where-Object { $_ -like "x500:*" }
```

If the old tenant is already gone, you can recover a user's old LegacyExchangeDN from the organizer field on their own old meetings, or from the IMCEAEX address in a bounce message.


## Step 6: Register the app in Exchange Online

Exchange needs its own pointer to the app's service principal. Use the real GUIDs from Step 3, without angle brackets.

```powershell
New-ServicePrincipal -AppId "<AppId>" -ObjectId "<EnterpriseAppObjectId>" -DisplayName "Calendar Cleanup"
```


## Step 7: Create the management scope and role assignment

Create a scope that matches only members of the group:

```powershell
New-ManagementScope -Name "Calendar Cleanup Scope" -RecipientRestrictionFilter "MemberOfGroup -eq '$GroupDN'"
```

Make sure `$GroupDN` from Step 4 is populated in the same session before running this. If it's empty, the filter matches nobody.

Assign calendar access to the app, limited to that scope:

```powershell
New-ManagementRoleAssignment -App "<AppId>" -Role "Application Calendars.ReadWrite" -CustomResourceScope "Calendar Cleanup Scope"
```

Confirm the filter was saved correctly. The property is named `RecipientFilter`, even though the parameter is `RecipientRestrictionFilter`.

```powershell
Get-ManagementScope "Calendar Cleanup Scope" | Format-List Name, RecipientFilter, ScopeRestrictionType
```

You should see `MemberOfGroup -eq 'CN=Calendar Cleanup Users,...'` and `RecipientScope`.


## Step 8: Test the scope

Test one user inside the group and one outside it:

```powershell
Test-ServicePrincipalAuthorization -Identity "<AppId>" -Resource "pilot.user@newdomain.us"
Test-ServicePrincipalAuthorization -Identity "<AppId>" -Resource "someone.else@newdomain.us"
```

The first should show `InScope : True` for **Application Calendars.ReadWrite**. The second should show `False`.

Permissions are cached. If a group member shows `False` right after setup, wait 30 to 120 minutes and test again before troubleshooting.


## Step 9: Notify users

Before deleting anything, tell users what to expect:

* Meetings sent to them from the old tenant will disappear from their calendars.
* Recurring meetings that are still needed (team meetings, one on ones, standing calls) must be rebuilt from the new accounts by their organizers.
* Their own old meetings will be removed in a separate step and no cancellations will be sent.


## Step 10: Run the cleanup script in preview mode

Save the following as `CalendarCleanup.ps1`. Run it from a PowerShell window that has **not** loaded the Exchange Online module.

```powershell
$AppId      = "<AppId>"
$Thumbprint = "<Thumbprint>"
$GroupId    = "<GroupObjectId>"
$TenantId   = "newdomain.us"
$OldDomain  = "olddomain.com"
$WhatIf     = $true

Connect-MgGraph -Environment USGov -ClientId $AppId -TenantId $TenantId -CertificateThumbprint $Thumbprint -NoWelcome

$users = Get-MgGroupMember -GroupId $GroupId -All |
    ForEach-Object { Get-MgUser -UserId $_.Id -Property Id,UserPrincipalName,Mail,ProxyAddresses }

$report = foreach ($u in $users) {
    $selfOld  = ($u.Mail -split "@")[0] + "@$OldDomain"
    $selfX500 = @($u.ProxyAddresses | Where-Object { $_ -like "x500:*" } | ForEach-Object { $_.Substring(5) })

    try {
        $events = Get-MgUserEvent -UserId $u.Id -All -Property "id,subject,organizer,type,start,isOrganizer"
    } catch {
        Write-Warning "Skipped $($u.UserPrincipalName): $($_.Exception.Message)"
        continue
    }

    foreach ($e in $events) {
        if ($e.IsOrganizer) { continue }

        $org = $e.Organizer.EmailAddress.Address
        if (-not $org) { continue }
        if ($org -eq $selfOld -or $selfX500 -contains $org) { continue }
        if (-not ($org -like "*@$OldDomain" -or $org -like "/o=*")) { continue }

        $deleted = $false
        if (-not $WhatIf) {
            try {
                Remove-MgUserEvent -UserId $u.Id -EventId $e.Id -ErrorAction Stop
                $deleted = $true
            } catch {
                Write-Warning "Failed: $($e.Subject) for $($u.UserPrincipalName): $($_.Exception.Message)"
            }
        }

        [pscustomobject]@{
            User      = $u.UserPrincipalName
            Subject   = $e.Subject
            Organizer = $org
            Type      = $e.Type
            Start     = $e.Start.DateTime
            EventId   = $e.Id
            Deleted   = $deleted
        }
    }
}

$stamp = Get-Date -Format "yyyyMMdd_HHmm"
$report | Export-Csv ".\CalendarCleanup_$stamp.csv" -NoTypeInformation
"Matched $(@($report).Count) items across $(@($users).Count) users"
```

### What the script does

* Reads every member of the scope group.
* Pulls each user's calendar events. Graph returns single meetings and series masters, so deleting a master removes the entire recurring series.
* Skips anything Exchange marks as organized by the user, and anything organized by the user's own old address or X500.
* Matches events organized by an `olddomain.com` address or by an old tenant X500 (`/o=...`).
* In preview mode, writes everything it would delete to a timestamped CSV.
* In delete mode, removes each item and records whether the delete succeeded.

### Review the report

Open the newest report:

```powershell
Get-ChildItem .\CalendarCleanup_*.csv | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Invoke-Item
```

Check three things:

1. **Organizer values.** Every row should be an `olddomain.com` address or an old tenant X500. There should be no `newdomain.us` organizers.
2. **The user's own items.** Personal appointments and reminders the user created should not appear. If they do, the user's X500 is missing. Go back to Step 5.
3. **Unknown X500 values.** New tenant mailboxes also have X500 style LegacyExchangeDNs. If you see one you don't recognize, look it up:

```powershell
Get-Recipient -Filter "LegacyExchangeDN -eq '<X500 value>'"
```

If that returns a user in the new tenant, the meeting is current and should not be deleted. If it returns nothing, it belongs to the old tenant.

### Optional: only remove recurring series and future items

If the goal is to clear clutter rather than history, add this line inside the `foreach ($e in $events)` loop, right after the `IsOrganizer` check. Past single meetings will be left in place as a record.

```powershell
if ($e.Type -ne "seriesMaster" -and [datetime]$e.Start.DateTime -lt (Get-Date)) { continue }
```


## Step 11: Pilot, then run for real

1. With only the pilot users in the group, set `$WhatIf = $false` and run the script.
2. Open the new CSV. Every row should show `Deleted` as `True`.
3. Have the pilot users confirm in Outlook on the web that the old meetings are gone and current meetings are intact.
4. Add the rest of the migrated users to the group, wait for the permission cache, run in preview mode, review, then run with `$WhatIf = $false`.

Keep every CSV. They are your record of what was removed.

Deleted items go to the user's **Deleted Items** folder first and then to **Recoverable Items**, so anything removed by mistake can be restored within your retention window.


## Step 12: Remove meetings the users organized

The script intentionally skips meetings the user organized. Deleting those through Graph, Outlook, or `Remove-CalendarEvents` makes Exchange send a cancellation to every attendee, and those attendee addresses mostly point at the old tenant.

A Purview purge removes them at the storage level with no cancellations sent. Run this **after** the script has finished for that user, so the only old tenant meetings left are the user's own.

> **Do not** work around this by granting the app the Mail.Send role. The deletes would succeed, but every one would send a cancellation for a meeting that may have happened months ago.

### Connect to Purview

Open a **new** PowerShell window that has not loaded any Graph modules.

```powershell
Connect-IPPSSession -ConnectionUri "https://ps.compliance.protection.office365.us/powershell-liveid/" -AzureADAuthorizationEndpointUri "https://login.microsoftonline.us/common" -DisableWAM
```

### Create and run the search

Scope the search to one mailbox. Limit it to items involving the user's old address, received on or before the migration cutover date. Replace the address and date with your own.

```powershell
New-ComplianceSearch -Name "Old Meetings Cleanup" -ExchangeLocation "user@newdomain.us" -ContentMatchQuery 'kind:meetings AND participants:"user@olddomain.com" AND received<=2026-01-31'

Start-ComplianceSearch -Identity "Old Meetings Cleanup"
```

Wait for it to finish:

```powershell
do {
    Start-Sleep -Seconds 30
    $s = Get-ComplianceSearch -Identity "Old Meetings Cleanup"
    "$($s.Status)  Items: $($s.Items)"
} until ($s.Status -eq "Completed")
```

A status of `Starting` with zero items means the search hasn't run yet, not that nothing matched.

### Review before purging

The `-Preview` option was removed from `New-ComplianceSearchAction`, so review results in the portal:

1. Go to **compliance.microsoft.us**.
2. Open **eDiscovery** > **Content search**.
3. Open the search and review the sample results.

Confirm every item is an old meeting. If anything current appears, tighten the date or the participant address and run the search again.

Note that `kind:meetings` also matches meeting request and response **emails**, so old invite messages in the user's mailbox are removed along with the calendar entries.

### Purge

A purge removes at most 10 items per mailbox per run. This loop searches and purges until nothing is left, and stops if the count stops dropping:

```powershell
$Name = "Old Meetings Cleanup"
$last = -1

do {
    Start-ComplianceSearch -Identity $Name
    do { Start-Sleep 30; $s = Get-ComplianceSearch -Identity $Name } until ($s.Status -eq "Completed")
    "Items remaining: $($s.Items)"

    if ($s.Items -eq 0) { break }
    if ($s.Items -eq $last) { "Count did not drop, stopping."; break }
    $last = $s.Items

    Get-ComplianceSearchAction -Identity "$($Name)_Purge" -ErrorAction SilentlyContinue | Remove-ComplianceSearchAction -Confirm:$false
    New-ComplianceSearchAction -SearchName $Name -Purge -PurgeType SoftDelete -Confirm:$false | Out-Null
    do { Start-Sleep 30; $a = Get-ComplianceSearchAction -Identity "$($Name)_Purge" } until ($a.Status -eq "Completed")
} while ($true)
```

To check a single purge manually:

```powershell
Get-ComplianceSearchAction -Identity "Old Meetings Cleanup_Purge" | Format-List Status, Results, Errors
```

If the loop stops because the count didn't drop, the mailbox is likely on a hold or retention policy. Purged items are kept in Recoverable Items and the search keeps finding them there. They are already gone from the user's calendar. Confirm in Outlook on the web.

`SoftDelete` keeps everything recoverable within the retention window.


## Step 13: Tear everything down

When cleanup is complete, remove everything you created.

In Exchange Online:

```powershell
Get-ManagementRoleAssignment -Role "Application Calendars.ReadWrite" |
    Where-Object CustomResourceScope -eq "Calendar Cleanup Scope" |
    Remove-ManagementRoleAssignment -Confirm:$false

Remove-ManagementScope -Identity "Calendar Cleanup Scope" -Confirm:$false
Remove-ServicePrincipal -Identity "<AppId>" -Confirm:$false
Remove-DistributionGroup -Identity "Calendar Cleanup Users" -Confirm:$false
```

In Purview:

```powershell
Get-ComplianceSearchAction | Where-Object Name -like "Old Meetings Cleanup*" | Remove-ComplianceSearchAction -Confirm:$false
Remove-ComplianceSearch -Identity "Old Meetings Cleanup" -Confirm:$false
```

In Entra, delete the **Calendar Cleanup** app registration.

On your workstation, remove the certificate:

```powershell
Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -eq "CN=CalendarCleanup" | Remove-Item
```

Leave the X500 proxy addresses from Step 5 in place. They are needed permanently.

Outlook clients in cached mode drop removed items on their next sync. If a user still sees old items after a day, rebuild their Outlook profile or OST.


## Troubleshooting

**`New-ServicePrincipal`: The parameter "ObjectId" is required**

The command was run with placeholder text instead of real GUIDs, or with the Object ID from App registrations. Use the Object ID from **Enterprise applications**.

**`Test-ServicePrincipalAuthorization` shows `InScope : False` for a group member**

Check that the scope filter contains the full group DN:

```powershell
Get-ManagementScope "Calendar Cleanup Scope" | Format-List RecipientFilter
```

If the DN is missing, `$GroupDN` was empty when the scope was created. Fix it in place:

```powershell
$GroupDN = (Get-Group "Calendar Cleanup Users").DistinguishedName
Set-ManagementScope "Calendar Cleanup Scope" -RecipientRestrictionFilter "MemberOfGroup -eq '$GroupDN'"
```

Also confirm the user is a **direct** member of the group. `MemberOfGroup` does not follow nested groups. If everything looks correct, wait for the permission cache and test again.

**`Remove-MgUserEvent`: ErrorSendAsDenied (403)**

The item is a meeting the user organized. Deleting it requires sending a cancellation, and the app doesn't have permission to send mail. The current script skips these. Use Step 12 to remove them.

**`Connect-IPPSSession` or `Connect-ExchangeOnline`: Method not found ... WithBroker**

The Microsoft Graph modules and the Exchange Online module are loading conflicting versions of the Microsoft sign in library. Open a fresh PowerShell window, don't load any Graph modules in it, and connect with `-DisableWAM`. Running from PowerShell 7 also helps.

**`ExternalDirectoryObjectId` is blank on the group**

Use `Get-MgGroup` as shown in Step 4, or copy the Object ID from **Microsoft Entra ID** > **Groups** in the portal.

**The script returns `Matched 0 items`**

Either the migration tool rewrote organizers to the new domain, or the permission cache hasn't caught up. Open a few old meetings in Outlook on the web and check what the organizer address looks like, then adjust `$OldDomain` or the X500 match accordingly.

**`New-ComplianceSearchAction`: A parameter cannot be found that matches parameter name 'Preview'**

The preview action has been retired. Review search results in the Purview portal instead.


## Running this in a Commercial tenant

The same process works in a Commercial tenant with different connection settings:

* Graph: use `-Environment Global` (or omit `-Environment`) on `Connect-MgGraph`.
* Exchange Online: run `Connect-ExchangeOnline` without `-ExchangeEnvironmentName`.
* Purview: run `Connect-IPPSSession` without `-ConnectionUri` and `-AzureADAuthorizationEndpointUri`.
* Portals: use **portal.azure.com**, **entra.microsoft.com**, and **purview.microsoft.com**.


## Disclaimer

Test every step against pilot users before running it across the tenant. Always run the script in preview mode and review the report before deleting anything. Verify your retention settings so removed items can be recovered if needed.
