# Diagnosing "Phantom" Local Admin on Entra-Joined Windows Devices

## The symptom

A user runs `whoami /all` and `BUILTIN\Administrators` appears in their token with
`Enabled group`. But `net localgroup administrators` doesn't list them, nothing in
Entra ID grants them admin, the device fleet is configured as standard-user-only,
and `dsregcmd /refreshprt` changes nothing.

It looks like a bug. It usually isn't.

## Why the two commands disagree

`net localgroup administrators` **silently drops any SID it cannot resolve to a
friendly name.** On Entra-joined devices, cloud principals (SIDs starting
`S-1-12-1-`) frequently fail to resolve — so cloud users and groups that really
are members of local Administrators just don't appear in the output.

The result: `net localgroup` shows 7 members while the group actually has 13.

Two other quirks worth knowing:

- **The token is built once, at interactive logon.** Group changes don't take
  effect until a full sign-out or reboot. `dsregcmd /refreshprt` refreshes the
  Primary Refresh Token but does **not** rebuild an existing logon token, which is
  why it appears to do nothing.
- **Lock, sleep, and Fast Startup don't count.** Users can go months without a
  genuine interactive logon, so a stale token can persist long after the
  underlying rights were removed.

---

## Step 1 — Confirm the rights are real

Check the attributes on the `BUILTIN\Administrators` line in `whoami /all`:

| Attribute | Meaning |
| --- | --- |
| `Enabled group` | Real admin rights |
| `Group used for deny only` | Standard user — UAC-filtered token, not admin |

If it says deny-only, stop; there's nothing to fix. Also note whether the shell
was launched elevated, and whether UAC prompted for *consent* (admin) or for
*credentials* (not admin).

## Step 2 — Enumerate local Administrators properly

Don't trust `net localgroup`. `Get-LocalGroupMember` is also unreliable here — it
commonly throws `Failed to compare two elements in the array` on cloud SIDs. ADSI
works around both:

```powershell
$g = [ADSI]"WinNT://./Administrators,group"
$g.Invoke("Members") | ForEach-Object {
    $m = [ADSI]$_
    $sid = (New-Object System.Security.Principal.SecurityIdentifier(
        $m.InvokeGet("objectSID"),0)).Value
    "{0,-30} {1}" -f $m.InvokeGet("Name"), $sid
}
```

Cloud principals show the SID in both columns (no name available). Compare the
member count to what `net localgroup` reported — the difference is what was hidden.

Members fall into three buckets:

- `S-1-5-21-<machine SID>-500/1001/1002...` — **local SAM accounts** (built-in
  Administrator, LAPS account, vendor/service accounts)
- `S-1-12-1-...` that resolve to names — cloud users added by policy
- `S-1-12-1-...` that don't resolve — cloud users **or groups**; these need
  decoding

## Step 3 — Find which membership actually grants the user admin

Cross-reference the user's token against the group. Run **as the affected user**:

```powershell
$tokenSids = (whoami /groups /fo csv | ConvertFrom-Csv).SID
$g = [ADSI]"WinNT://./Administrators,group"
$g.Invoke("Members") | ForEach-Object {
    $m = [ADSI]$_
    $sid = (New-Object System.Security.Principal.SecurityIdentifier(
        $m.InvokeGet("objectSID"),0)).Value
    if ($tokenSids -contains $sid) { "MATCH: $sid  ($($m.InvokeGet('Name')))" }
}
```

Every `MATCH` is a live path to admin. If nothing matches but the token says
admin, the token is stale — reboot and re-check.

> **Watch for the common misread:** if the matching SID differs from the user's
> own SID (visible in the USER INFORMATION section of `whoami /all`), it's a
> **group** they belong to, not their account. This is why checking the user
> object and their direct role assignments in Entra comes back clean.

Also prefer CSV output over plain `whoami /all`, which wraps and truncates in
narrow console windows:

```powershell
whoami /groups /fo csv | ConvertFrom-Csv |
    Select-Object 'Group Name', SID, Attributes | Format-Table -AutoSize -Wrap
```

## Step 4 — Rule out (or confirm) Intune policy

The **LocalUsersAndGroups** CSP — surfaced in Intune as *Endpoint security →
Account protection → Local user group membership* — writes directly to the local
SAM. Check whether it's active:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LocalUsersAndGroups' `
    -ErrorAction SilentlyContinue | Format-List
```

- `Configure_ProviderSet : 1` — a policy is applied
- `Configure_WinningProvider : <GUID>` — the policy ID that won

This tells you a policy **exists**, not what it does. Get the payload from the
provider key:

```powershell
$id = '<winning-provider-guid>'
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\providers\$id\default\Device\LocalUsersAndGroups" `
    -ErrorAction SilentlyContinue | Format-List *
```

The `Configure` value is XML:

```xml
<GroupConfiguration>
  <accessgroup desc="S-1-5-32-544">
    <group action="U" />
    <add member="AzureAD\first.last@example.com" />
    <add member="S-1-12-1-xxxxxxxxxx-xxxxxxxxxx-xxxxxxxxxx-xxxxxxxxxx" />
  </accessgroup>
</GroupConfiguration>
```

Check whether the SID from Step 3 appears in this list, and note the action:

| Action | Behaviour |
| --- | --- |
| `U` (Update) | Adds listed members, **never removes anything else** |
| `R` (Restrict/Replace) | Enforces exact membership — removes everything not listed |

To enumerate all providers, not just the winner:

```powershell
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\providers' | ForEach-Object {
    $k = Join-Path $_.PSPath 'default\Device\LocalUsersAndGroups'
    if (Test-Path $k) { $_.PSChildName; (Get-ItemProperty $k).Configure }
}
```

### If the SID is NOT in the policy

This is the interesting case. Because `action="U"` never removes members, a SID
added by an **earlier revision of the policy**, a **since-unassigned policy**, or
a **one-off script** stays in the local SAM permanently. Nothing cleans it up.

That's a genuine orphan: no current policy and no Entra configuration explains
it, which is exactly why the admin rights look impossible.

Other things to rule out:

- Intune **platform scripts** and **remediations** calling `net localgroup` — these
  leave no registry trace (*Devices → Scripts and remediations*)
- Autopilot profile **User account type = Administrator** (join-time only)
- Entra → Devices → Device settings → **Additional local administrators**
- GPO on hybrid-joined devices
- Imaging / provisioning steps

> The "devices are standard-user-only" setting governs behaviour **at enrollment
> time**. It does not lock the group afterward, and it has no effect on the
> LocalUsersAndGroups CSP. A standard-user fleet can absolutely have machines with
> a dozen local admins.

## Step 5 — Attribute the change

Event **4732** (*a member was added to a security-enabled local group*) records
the addition with a timestamp and the account responsible:

```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4732} -MaxEvents 50 |
    ForEach-Object {
        $x = [xml]$_.ToXml()
        [pscustomobject]@{
            Time    = $_.TimeCreated
            Member  = ($x.Event.EventData.Data | Where-Object Name -eq 'MemberSid').'#text'
            Group   = ($x.Event.EventData.Data | Where-Object Name -eq 'TargetUserName').'#text'
            AddedBy = ($x.Event.EventData.Data | Where-Object Name -eq 'SubjectUserName').'#text'
        }
    } | Format-Table -AutoSize
```

- `AddedBy` = machine account or `SYSTEM` → policy or script
- `AddedBy` = a named user → done manually

Requires Security Group Management auditing to be enabled and the log not to have
rolled over, so empty results prove nothing either way.

## Step 6 — Identify the cloud SIDs

An `S-1-12-1-` SID encodes the Entra object ID. The four sub-authorities are
little-endian 32-bit chunks of the GUID:

```powershell
$sids = @(
  'S-1-12-1-xxxxxxxxxx-xxxxxxxxxx-xxxxxxxxxx-xxxxxxxxxx'
)
foreach ($s in $sids) {
    $b = $s.Split('-')[4..7] | ForEach-Object { [BitConverter]::GetBytes([uint32]$_) }
    "{0}  ->  {1}" -f $s, ([guid][byte[]]$b).Guid
}
```

Python equivalent:

```python
import uuid, struct

def sid_to_guid(sid):
    parts = [int(x) for x in sid.split('-')[4:8]]
    return str(uuid.UUID(bytes_le=b''.join(struct.pack('<I', p) for p in parts)))
```

> Note `bytes_le` — the GUID's first three fields are little-endian. Using
> `bytes=` produces a plausible-looking but wrong GUID. Validate your
> implementation against a SID whose object you can already identify.

### Looking the GUIDs up

Deep-link portal URLs are fragile and change between portal revisions. Most
reliable first: paste the GUID into the **search bar** at
[entra.microsoft.com](https://entra.microsoft.com).

For bulk lookup, use [Graph Explorer](https://developer.microsoft.com/graph/graph-explorer) —
**POST** to `https://graph.microsoft.com/v1.0/directoryObjects/getByIds`:

```json
{
  "ids": ["00000000-0000-0000-0000-000000000000"],
  "types": ["group", "user", "servicePrincipal", "device"]
}
```

Requires `Directory.Read.All`. Objects present in the response `value` array
exist, with `displayName` and `@odata.type`. **Objects missing from the array do
not exist in the tenant** — deleted, or from another tenant. A deleted group
leaves its SID in the local SAM indefinitely.

Or with the Graph PowerShell SDK (install only the submodules you need — far
faster than the full SDK, and run it from an admin workstation, not the endpoint):

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Groups -Scope CurrentUser -Force
Connect-MgGraph -Scopes 'Group.Read.All','Directory.Read.All'
Get-MgGroup -GroupId '<guid>' | Select-Object DisplayName, Id, Description, GroupTypes
```

Once you've identified a group, check:

- **Membership type** — if Dynamic, read the rule. An over-broad rule explains how
  a user joined an admin-granting group nobody added them to.
- **Member count** — how many other users have admin via the same nesting
- **Assigned roles** — should be empty
- **Owners / description** — often the only clue to origin

## Step 7 — Remediate

```powershell
Remove-LocalGroupMember -Group 'Administrators' `
    -Member 'S-1-12-1-xxxxxxxxxx-xxxxxxxxxx-xxxxxxxxxx-xxxxxxxxxx'
```

If that fails on a cloud SID (common), use ADSI:

```powershell
$g = [ADSI]"WinNT://./Administrators,group"
$g.Remove("WinNT://S-1-12-1-xxxxxxxxxx-xxxxxxxxxx-xxxxxxxxxx-xxxxxxxxxx")
```

Then re-run Step 2 to verify, have the user **sign out fully or reboot**, and
re-check `whoami /all`.

### Where to apply the fix

| Source | Fix |
| --- | --- |
| Current Intune policy lists the SID | Edit the policy, or narrow its assignment. Local removal will be re-added at next sync. |
| Orphan (no policy lists it) | Remove locally. With `action="U"` the CSP won't re-add it. |
| Legitimate group, wrong member | Fix the user's Entra group membership, not the local nesting. |

### Do not switch `action="U"` to `"R"` as a cleanup shortcut

Replace mode enforces exact membership and will strip **every** account not
explicitly listed — including the LAPS account, break-glass local admin, and RMM
or vendor service accounts. Losing those can leave you locked out of the device.
If you do want `R`, enumerate and list every account you intend to keep first,
and pilot on a small ring.

## Step 8 — Check the fleet

Orphaned SIDs are rarely confined to one machine. Package the Step 2 enumeration
as an Intune **remediation detection script** and run it read-only across the
estate to scope the problem before deploying anything that removes members.

Flag any `S-1-12-1-` member that isn't in your current policy's member list.

---

## Quick reference

| Question | Command |
| --- | --- |
| Am I actually admin? | `whoami /all` → check for `Enabled group` vs `Group used for deny only` |
| Real group membership | ADSI enumeration (Step 2) — **not** `net localgroup` |
| Which membership grants it | Token cross-reference (Step 3) |
| Is a policy responsible | `PolicyManager\current\device\LocalUsersAndGroups` (Step 4) |
| What does the policy say | `PolicyManager\providers\<guid>\default\Device\LocalUsersAndGroups` |
| Who added it, and when | Security event 4732 (Step 5) |
| What is this cloud SID | SID → GUID decode, then Graph `getByIds` (Step 6) |

## Key takeaways

1. `net localgroup` is not a reliable source of truth on Entra-joined devices.
2. Tokens are built at logon. Nothing short of a full sign-out or reboot updates them.
3. `action="U"` policies add but never remove — orphaned members accumulate forever.
4. A SID in the token that isn't the user's own SID is a group. Check the group,
   not the user.
5. "Standard user only" is an enrollment-time setting, not an ongoing guarantee.
