# @pgodschalk/windows-maintenance

[Report a Bug](https://github.com/pgodschalk/windows-maintenance/issues/new?assignees=&labels=bug&template=bug_report.md&title=bug%3A+)
·
[Request a Feature](https://github.com/pgodschalk/windows-maintenance/issues/new?assignees=&labels=enhancement&template=feature_request.md&title=feat%3A+)

Runs routine Windows maintenance: installs Windows + application updates, runs
silent health checks, backs up configured paths, and lists the tasks you must do
by hand.

[![Project license](https://img.shields.io/github/license/pgodschalk/windows-maintenance.svg?style=flat-square)](LICENSE.txt)

[![Pull Requests welcome](https://img.shields.io/badge/PRs-welcome-ff69b4.svg?style=flat-square)](https://github.com/pgodschalk/windows-maintenance/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
[![code with love by pgodschalk](https://img.shields.io/badge/%3C%2F%3E%20with%20%E2%99%A5%20by-pgodschalk-ff1414.svg?style=flat-square)](https://github.com/pgodschalk)

- [About](#about)
  - [Built with](#built-with)
- [Getting started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
- [Usage](#usage)
- [Roadmap](#roadmap)
- [Support](#support)
- [Project assistance](#project-assistance)
- [Contributing](#contributing)
- [Authors & contributors](#authors--contributors)
- [Security](#security)
- [License](#license)

## About

windows-maintenance is a [PowerShell](https://learn.microsoft.com/powershell/) 7
module that performs routine upkeep on a Windows machine you administer, in a
single elevated run:

- **Updates** -- installs available Windows updates (drivers excluded by
  default) and upgrades every
  [winget](https://learn.microsoft.com/windows/package-manager/) package, then
  refreshes Microsoft Defender signatures.
- **Health checks** -- runs silent checks (such as low disk space) and speaks up
  only when something needs your attention.
- **Backup** -- takes an encrypted [restic](https://restic.net) backup of the
  paths you configure.
- **Manual tasks** -- lists what it cannot do for you (UEFI/BIOS firmware and
  anything else you add) with links to follow.

Every run records one structured event in the Windows Event Log and reports when
it last ran. Run it **manually from an elevated session** -- not as a scheduled
or SYSTEM task.

### Built with

- [Microsoft PowerShell](https://learn.microsoft.com/powershell/) 7.4+

## Getting started

### Prerequisites

- Windows 10 or 11.
- [PowerShell](https://learn.microsoft.com/powershell/) 7.4 or newer.
- Administrator privileges (run from an elevated session).
- [winget](https://learn.microsoft.com/windows/package-manager/) for application
  updates (included with current Windows).
- Only for the optional backup step: [restic](https://restic.net) and the
  [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) for secrets.

### Installation

Download the latest release from the
[Releases page](https://github.com/pgodschalk/windows-maintenance/releases) and
extract it. Each release ships with a SHA-256 checksum and a Sigstore build
provenance attestation you can verify with the
[GitHub CLI](https://cli.github.com):

```powershell
gh attestation verify WindowsMaintenance-1.0.0.zip `
  --repo pgodschalk/windows-maintenance
```

For development, clone the repository instead and see
[CONTRIBUTING](CONTRIBUTING.md).

## Usage

Run the entry script from an **elevated** PowerShell 7 session:

```powershell
# Dry run -- show what would happen, change nothing.
./Invoke-WindowsMaintenance.ps1 -WhatIf

# Real run.
./Invoke-WindowsMaintenance.ps1
```

Useful switches: `-Json` (emit the run's wide event as JSON), `-Quiet` (suppress
console narration), and `-Version` (print the module version and exit). The
manual-task list and the encrypted backup are driven by JSON config files -- see
`manual-tasks.example.json` and `backup-config.example.json`, validated by the
matching `*.schema.json`. For full help:

```powershell
Get-Help ./Invoke-WindowsMaintenance.ps1 -Full
```

## Roadmap

See the [open issues](https://github.com/pgodschalk/windows-maintenance/issues)
for a list of proposed features (and known issues).

- [Top Feature Requests](https://github.com/pgodschalk/windows-maintenance/issues?q=label%3Aenhancement+is%3Aopen+sort%3Areactions-%2B1-desc)
  (Add your votes using the 👍 reaction)
- [Top Bugs](https://github.com/pgodschalk/windows-maintenance/issues?q=is%3Aissue+is%3Aopen+label%3Abug+sort%3Areactions-%2B1-desc)
  (Add your votes using the 👍 reaction)
- [Newest Bugs](https://github.com/pgodschalk/windows-maintenance/issues?q=is%3Aopen+is%3Aissue+label%3Abug)

## Support

Reach out to the maintainer at one of the following places:

- [GitHub issues](https://github.com/pgodschalk/windows-maintenance/issues/new?assignees=&labels=question&template=04_SUPPORT_QUESTION.md&title=support%3A+)
- Contact options listed on [this GitHub profile](https://github.com/pgodschalk)

## Project assistance

If you want to say **thank you** or/and support active development of
windows-maintenance:

- Add a [GitHub Star](https://github.com/pgodschalk/windows-maintenance) to the
  project.
- Write interesting articles about the project on [Dev.to](https://dev.to/),
  [Medium](https://medium.com/) or your personal blog.

Together, we can make windows-maintenance **better**!

## Contributing

First off, thanks for taking the time to contribute! Contributions are what make
the open-source community such an amazing place to learn, inspire, and create.
Any contributions you make will benefit everybody else and are **greatly
appreciated**.

Please read [our contribution guidelines](CONTRIBUTING.md), and thank you for
being involved!

## Authors & contributors

The original setup of this repository is by
[Patrick Godschalk](https://github.com/pgodschalk).

For a full list of all authors and contributors, see
[the contributors page](https://github.com/pgodschalk/windows-maintenance/contributors).

## Security

windows-maintenance follows good practices of security, but 100% security cannot
be assured. windows-maintenance is provided **"as is"** without any
**warranty**. Use at your own risk.

_For more information and to report security issues, please refer to our
[security documentation](SECURITY.md)._

## License

This project is licensed under the EUPL-1.2 license.

See [LICENSE](LICENSE.txt) for more information.
