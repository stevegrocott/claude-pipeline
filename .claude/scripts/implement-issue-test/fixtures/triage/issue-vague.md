# Fix the timeout issue

The reports page sometimes times out. Make it not time out.

## Notes

It happens occasionally on the staging environment. Maybe related to
network conditions? The team has noticed it in several places but no one
has nailed down where exactly. A few of the playwright tests fail because
of it but a few of the unit tests too. Production code might also have the
problem.

This needs to be fixed before the release.
