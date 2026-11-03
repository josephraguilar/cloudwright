Find-MgGraphCommand -Command 'New-MgUser' | Select-Object -First 1 -ExpandProperty Permissions | Format-Table Name, IsAdmin, Description -AutoSize
Find-MgGraphPermission -SearchString 'Group' -PermissionType 'Delegated' | Format-Table Name, Consent, Description -AutoSize
