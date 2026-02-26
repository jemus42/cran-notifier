# CRAN Incoming Notifier

Get push notifications when your R package moves through [CRAN's incoming queue](https://cran.r-project.org/incoming/). Tracks status changes (new submission, folder moves, acceptance/rejection) and sends notifications via [ntfy](https://ntfy.sh).

## How it works

**`cran-notifier.R`** does everything in a single script:

1. Reads config from `config.env`
2. Queries CRAN incoming via [`foghorn::cran_incoming()`](https://fmichonneau.github.io/foghorn/)
3. Compares against the previous state (stored in `rappdirs::user_data_dir("cran-notifier")`)
4. Sends push notifications for any changes via [ntfy](https://ntfy.sh) using [`httr2`](https://httr2.r-lib.org/)
5. Saves the new state (only after all notifications succeed, so failures are retried)

A **systemd user timer** runs the check every 15 minutes.

### Notification types

| Event | Example | Priority |
|---|---|---|
| Package appears in queue | Submission detected in `newbies` | default |
| Package moves between folders | `inspect` -> `pretest` | default |
| Package moves to `publish` | Pending final publication | high |
| Package moves to `archive` | Rejected or withdrawn | high |
| Package disappears from `publish` | Likely on CRAN now | high |
| Package disappears from other folder | No longer in incoming | default |

## Requirements

- R (4.1+)
- `systemd` (for automated scheduling; optional if running manually)

R package dependencies (`foghorn`, `jsonlite`, `httr2`, `rappdirs`) are **auto-installed** on first run via [`pak`](https://pak.r-lib.org/) if missing.

## Setup

### 1. Clone the repository

```bash
git clone https://github.com/jmbuhr/cran-notifier.git
cd cran-notifier
```

### 2. Create your config

```bash
cp config.env.example config.env
```

Edit `config.env`:

```bash
NTFY_TOPIC="https://ntfy.sh/your-unique-topic-name"
NTFY_TOKEN=""  # optional — only needed for token-protected topics
PACKAGES="mypkg otherpkg"  # space-separated list of packages to monitor
```

**ntfy topic**: You can use the free public [ntfy.sh](https://ntfy.sh/app) service — just pick a unique, hard-to-guess topic name. Install the [ntfy app](https://ntfy.sh/#subscribe-phone) on your phone and subscribe to the same topic to receive notifications. Alternatively, you can [self-host ntfy](https://docs.ntfy.sh/install/).

**Token authentication** is optional. You only need `NTFY_TOKEN` if your topic requires access control (e.g., on a self-hosted instance with ACLs). Leave it empty for open topics. See the [ntfy auth docs](https://docs.ntfy.sh/publish/#access-tokens) for details.

The `config.env` file is gitignored so your configuration stays local.

### 3. Test it

```bash
Rscript cran-notifier.R
```

The first run establishes the baseline state (no notifications sent). Run it again — if nothing changed, it prints "No changes detected."

### 4. Set up the systemd timer

Edit `cran-notifier.service` to point to your paths:

- `ExecStart` — the absolute path to `Rscript` and `cran-notifier.R`

Then install and enable the timer:

```bash
mkdir -p ~/.config/systemd/user
cp cran-notifier.service cran-notifier.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now cran-notifier.timer
```

Verify it's running:

```bash
systemctl --user status cran-notifier.timer
systemctl --user list-timers
```

Check logs:

```bash
journalctl --user -u cran-notifier -f
```

## CRAN incoming folders

Packages move through these folders during the CRAN review process:

| Folder | Meaning |
|---|---|
| `newbies` | First-time submission (new package or new maintainer) |
| `inspect` | Queued for manual inspection |
| `waiting` | Waiting for automated checks |
| `pretest` | Undergoing automated checks |
| `recheck` | Reverse-dependency checks running |
| `pending` | Awaiting final decision |
| `publish` | Accepted, pending publication |
| `archive` | Rejected or withdrawn |
