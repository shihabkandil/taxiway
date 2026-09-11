# Design: Phase 6, Slack notifications

`shipway release` and `shipway run` tell a Slack channel how a release went.
The fields are in [`config-schema.md`](config-schema.md#notify--telling-a-channel-how-a-release-went);
this note records why they look the way they do.

## Two transports, because a webhook cannot edit

An incoming webhook is the easy setup: one URL, one channel. It can only ever
post a new message, because it has no way to address a message it already
sent. That is fine for "tell me when it breaks", and it is the default.

A live status message, one line per release that changes as steps finish,
needs `chat.update`, and that needs a bot token. So there are two refs, and the
bot token wins **when it resolves on this machine**. It is not a config switch.
A team keeps the webhook on every laptop and the bot token on the runner, and
one `shipway.yaml` does the right thing in both places.

## Edits notify nobody

Slack sends no notification for an edited message, not even for a mention the
edit adds. A live message that turns red is invisible to anyone not looking at
the channel. So a failure is also posted as a thread reply with
`reply_broadcast`, which shows in the channel and notifies like any message. A
success is only the edit: nobody needs pinging because something worked.

`chat.update` refuses a `#channel-name`, so the channel id that Slack returns
from the first post is kept and used for every edit after it.

## A notification never fails a release

Every Slack problem becomes a warning, said once. The release goes on and
keeps its own exit code. After the first failed progress edit, the other
progress edits stop (they would fail the same way). The final message is still
tried, and if the live message cannot be edited, it is posted as a new one.

A rate limit is waited out once, for at most ten seconds. A 15 second timeout
covers the whole request, so a hung Slack cannot hold the end of a release.

## The URL is the credential

A webhook URL's path is its secret. It goes through the redactor like every
other secret, and errors name the ref (`SLACK_WEBHOOK`), never the URL.
`HttpPostException` messages carry only the host.

## Templates, not a template language

`{placeholder}` substitution and nothing else: no conditionals, no loops. A
message is one line somebody reads, and once it needs logic it should be a
`run:` step instead. Values are escaped for Slack (`&`, `<`, `>`), templates are
not. The template is the author's own markup, where `<!here>` has to work. A
branch name is somebody else's text, where `<!channel>` must not.

An unknown placeholder fails when the config loads. Otherwise `{falied_step}`
would reach the channel word for word, after the release it was meant to
report.

## One report per pipeline

A pipeline runs its `release` steps in process with `--no-notify`, so a
`beta` run is one message listing every step, not one per upload on top of it.
`shipway release` run by hand reports as a one-step run.

## What is not covered

The Slack API behaviour above comes from Slack's documentation. It has not
been run against a real workspace from this repository. The tests pin the
exact requests shipway sends, against a local HTTP server and a recording
double. `shipway notify test` is the first thing to run against a real channel.
