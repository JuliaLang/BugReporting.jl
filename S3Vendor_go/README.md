# S3Vendor

This AWS lambda service receives redirects from GitHub and in turn sends
temporary AWS S3 credentials back to the CLI client such that it may upload
the given file. The AWS credentials are scoped precisely to only allow
modification of the one file. The server assings the filename based on
the GitHub username that provided the credentials and the current time.
The CLI has no say over the filename it gets assigned.

In addition to this AWS lambda service, there is an AWS API gateway WebSocket
API that responds to messages by returning its connectionId to the CLI. This
conncetionId is then passed as the `state` parameter to GitHub, which forwards
it to us. If the authentication goes through, we send aforementioned S3
credentials back to the websocket whose connectionId matches the `state`
parameter.

# Security

This server is intended as a first level abuse protection mechanism. At the
moment, it doesn't do any validation beyond the fact that somebody with a
GitHub account clicked a specially prepared GitHub link. Note that in particular
it would be quite possible for an attacker to trick another person into clicking
such a link and generating an upload token. We do not currently mitigate against
this scenario (after all, it would be easy for the attacker to simply create
a GitHub account and immediately receive the same credentials). However, as a
result the username in the upload should not be considered as trusted. If we
experience abuse, it is possible to strengthen the authentication at this point
by requiring the user to affirmatively enter a security token (c.f. RFC8628).
