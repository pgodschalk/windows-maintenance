# Contributing

When contributing to this repository, please first discuss the change you wish
to make via issue, email, or any other method with the owners of this repository
before making a change.

Please note we have a [code of conduct](CODE_OF_CONDUCT.md), please follow it in
all your interactions with the project.

## Development environment setup

To set up a development environment, please follow these steps:

1. Clone the repo

   ```powershell
   git clone https://github.com/pgodschalk/windows-maintenance.git
   ```

2. Install PowerShell 7.4 or newer (`pwsh`); the module targets 7.4 and refuses
   to load on anything older. See the
   [installation guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell).

   ```powershell
   $PSVersionTable.PSVersion # expect 7.4.0 or newer
   ```

3. Install the development modules and run the quality gate. On first run, the
   test runner installs [Pester](https://pester.dev) 5+ and
   [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) 1.21+ for
   you:

   ```powershell
   pwsh ./tools/run-tests.ps1 -Install
   ```

   That single command is the full quality gate CI also runs: PSScriptAnalyzer
   (lint), an `Invoke-Formatter` check, and the Pester suite. Run it before
   every commit. While iterating, narrow it with `-SkipLint` (tests only) or
   `-SkipTests` (lint and format check only).

4. Optionally try the tool. It only changes the system on Windows, run from an
   **elevated** PowerShell 7 session; a dry run is safe to explore anywhere:

   ```powershell
   ./Invoke-WindowsMaintenance.ps1 -WhatIf
   ```

## Updating the help

Command help is authored as [PlatyPS](https://github.com/PowerShell/platyPS)
markdown in `docs/help/` (only the curated public commands -- the module exports
everything for runtime reasons, but most functions are internal).
`tools/build-help.ps1` turns it into module help:

```powershell
pwsh ./tools/build-help.ps1 -Install
```

It writes the MAML to `en-US/` on any OS (committed, so `Get-Help` works
offline). On Windows it also builds the updatable-help CAB and `HelpInfo.xml`.
The `publish-help` workflow runs that on each `v*` tag and deploys to GitHub
Pages, so `Update-Help -Module WindowsMaintenance` can fetch refreshed help from
the `HelpInfoUri`. After changing a command, regenerate its markdown with
PlatyPS (`Update-MarkdownHelp`), fill in the changes, and rebuild.

For the Pages deploy to work, a maintainer must enable GitHub Pages once with
the **GitHub Actions** source (repository Settings -> Pages).

## Signing releases

Each release (`release.yml`, on a `v*` tag) carries two independent signatures.

**Sigstore provenance (automatic, no setup).** Every release zip gets a keyless,
Sigstore-backed build-provenance attestation. Verify a download with:

```bash
gh attestation verify WindowsMaintenance-1.0.1.zip \
  --repo pgodschalk/windows-maintenance
```

**Authenticode (optional, self-signed).** When the `SIGNING_CERT_PFX_BASE64` and
`SIGNING_CERT_PASSWORD` repository secrets are set, the packaged
`.ps1`/`.psm1`/`.psd1` files are Authenticode-signed and the public certificate
is attached to the release; without the secrets the release still ships, just
unsigned. To set it up once, on Windows:

```powershell
# 1. Create a code-signing certificate (valid 5 years).
$cert = New-SelfSignedCertificate -Type CodeSigningCert `
  -Subject 'CN=Patrick Godschalk (WindowsMaintenance)' `
  -CertStoreLocation Cert:\CurrentUser\My `
  -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(5)

# 2. Export it to a password-protected PFX.
$pfxPassword = Read-Host 'PFX password' -AsSecureString
Export-PfxCertificate -Cert $cert -FilePath wm-signing.pfx -Password $pfxPassword

# 3. Base64-encode the PFX for the GitHub secret.
[Convert]::ToBase64String(
  [IO.File]::ReadAllBytes('wm-signing.pfx')) | Set-Clipboard
```

Add the base64 string as the `SIGNING_CERT_PFX_BASE64` secret and the PFX
password as `SIGNING_CERT_PASSWORD` (Settings -> Secrets and variables ->
Actions). To trust the signed scripts on a machine, import the released `.cer`
into its stores from an elevated session:

```powershell
Import-Certificate -FilePath WindowsMaintenance-1.0.1.cer `
  -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath WindowsMaintenance-1.0.1.cer `
  -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
```

## Issues and feature requests

You've found a bug in the source code, a mistake in the documentation or maybe
you'd like a new feature? You can help us by
[submitting an issue on GitHub](https://github.com/pgodschalk/windows-maintenance/issues).
Before you create an issue, make sure to search the issue archive -- your issue
may have already been addressed!

Please try to create bug reports that are:

- _Reproducible._ Include steps to reproduce the problem.
- _Specific._ Include as much detail as possible: which version, what
  environment, etc.
- _Unique._ Do not duplicate existing opened issues.
- _Scoped to a Single Bug._ One bug per report.

**Even better: Submit a pull request with a fix or new feature!**

### How to submit a Pull Request

1. Search our repository for open or closed
   [Pull Requests](https://github.com/pgodschalk/windows-maintenance/pulls) that
   relate to your submission. You don't want to duplicate effort.
2. Fork the project
3. Create your feature branch (`git checkout -b feat/amazing_feature`)
4. Commit your changes (`git commit -m 'feat: add amazing_feature'`).
   windows-maintenance uses
   [conventional commits](https://www.conventionalcommits.org), so please follow
   the specification in your commit messages.
5. Push to the branch (`git push origin feat/amazing_feature`)
6. [Open a Pull Request](https://github.com/pgodschalk/windows-maintenance/compare?expand=1)
