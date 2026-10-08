Connect-MgGraph -Scopes "User.ReadWrite.All"
$guest = Get-MgUser -Filter "mail eq 'her.address@externaldomain.com'"
Update-MgUser -UserId $guest.Id -ShowInAddressList:$true
