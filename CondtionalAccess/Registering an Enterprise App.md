# Registering an Enterprise App from Sign-In Logs

Sometimes an app shows up in your Entra sign-in logs with no corresponding service principal in your tenant. This usually happens with a multi-tenant app that a user consented to, or a first-party Microsoft app that hasn't been provisioned locally yet. Until it has a service principal, you can't target it with Conditional Access, assign it to users, or see it under Enterprise Applications. These commands fix that.

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All"

New-MgServicePrincipal -BodyParameter @{
    AppId = "<the-app-id-guid-from-your-sign-in-log>"
}
```

`Connect-MgGraph` opens an authenticated session with the `Application.ReadWrite.All` scope, which is what lets you create service principals. `New-MgServicePrincipal` then takes an existing app's `AppId` (the client ID, not the object ID) and instantiates it as a service principal in your tenant, making it visible and manageable in Enterprise Applications.

## Finding the App ID

You need the **Application (client) ID**, not the object ID. They're both GUIDs and easy to mix up, but Graph will reject the wrong one.

**From the sign-in log directly**
Go to Entra admin center, then **Identity** > **Monitoring & health** > **Sign-in logs**. Click the sign-in event in question, and on the **Basic info** tab you'll see **Application ID**. Copy that GUID.

**From an existing app registration**
If the app is one your org owns, go to **Identity** > **Applications** > **App registrations**, open the app, and the client ID is on the Overview page.

**From Enterprise Applications (if a service principal already exists elsewhere)**
Check **Identity** > **Applications** > **Enterprise applications** first, and search by name. If it's already there, you don't need `New-MgServicePrincipal` at all. You're only running that command when the app is *missing* from this list.

**Via Graph itself, if you only have a display name**
```powershell
Get-MgServicePrincipal -Filter "displayName eq 'App Name Here'"
```
Returns nothing if no service principal exists yet, which is your confirmation you need to create one.

## Running the Command

Once you have the correct App ID:

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All"

New-MgServicePrincipal -BodyParameter @{
    AppId = "11111111-2222-3333-4444-555555555555"
}
```

A successful run returns the new service principal object, including its own `Id` (object ID). Save that if you plan to script further configuration (app roles, permissions, owners) against it.

## Adding It to a Conditional Access Policy

Once the service principal exists, it becomes selectable as a cloud app target.

1. Entra admin center > **Protection** > **Conditional Access** > **Policies**.
2. Open an existing policy, or select **New policy**.
3. Under **Target resources**, set the resource type to **Cloud apps**, then **Include** > **Select apps**.
4. Search for the app by display name. It will now appear in the picker since it has a service principal.
5. Configure the rest of the policy (conditions, grant/session controls) as needed, and set **Enable policy** to **Report-only** first if you want to validate impact before enforcing.

If the app still doesn't show up in the picker, give it a few minutes for directory replication. Also confirm you created the service principal in the same tenant the policy lives in, since that's a common miss if you're managing multiple tenants with the same PowerShell session.

## Verifying the Result

```powershell
Get-MgServicePrincipal -Filter "appId eq '11111111-2222-3333-4444-555555555555'"
```

Confirms the service principal exists and lets you check `DisplayName`, `AppOwnerOrganizationId` (useful for spotting multi-tenant apps from other organizations), and `Id` for further scripting.
