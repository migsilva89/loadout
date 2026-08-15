# Security policy

## Reporting a vulnerability

Please don't open a public issue for a security problem.

Report it privately through GitHub's ["Report a vulnerability"](../../security/advisories/new) button, or by email to miguel.silva@thegoodcode.io.

Expect an acknowledgement within a few days. Once the problem is confirmed and fixed, the release notes credit whoever found it, unless they'd rather stay anonymous.

## What matters here

Loadout reads and writes configuration files on your own machine, and runs the CLI of whichever assistant you choose. The main areas of interest: writes outside the expected directories, command execution driven by file contents, and any path where a backup fails without stopping the write.

There's no server, account or telemetry, and the app itself makes no network calls — there is no networking code in it at all. The assistant CLI it runs on your behalf does talk to its own provider, using the subscription already on your machine; Loadout never sees or stores a credential for that.

## Supported versions

Only the latest version gets fixes.
