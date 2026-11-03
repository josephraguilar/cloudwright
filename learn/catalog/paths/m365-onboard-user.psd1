@{
    Id      = 'path.m365.onboard-user'
    Title   = 'Onboard a user: create, licence, group, manager'
    Summary = 'New user with usage location, a licence, membership of one group, and a manager. Run the lines in order; the licence needs the user to exist.'
    Tasks   = @('m365.users.new-user', 'm365.licenses.assign-license', 'm365.groups.add-member', 'm365.users.set-manager')
    Share   = @{ UserId = 'UserPrincipalName' }
}
