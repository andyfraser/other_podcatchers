# Podcatcher (PHP)

A single-file, command-line podcast manager written in PHP. Subscribe to RSS feeds, browse episodes, download audio files, and track what you've listened to — all from the terminal, with no database or external services required.

> Ported from the original Python implementation.

## Features

- Subscribe to any podcast RSS feed by URL
- List and inspect all subscribed feeds
- Refresh feeds to discover new episodes
- Download episode audio files with a live progress bar
- Mark episodes as played or unplayed
- Search episode titles and descriptions across all feeds
- All data stored locally in `~/.podcatcher/`

## Requirements

- PHP 8.1 or later (CLI)
- The `php-xml` extension

On Debian, Ubuntu, or Linux Mint:

```bash
sudo apt install php-cli php-xml
```

## Installation

Download the script and make it executable:

```bash
curl -O https://raw.githubusercontent.com/youruser/podcatcher/main/podcatcher.php
chmod +x podcatcher.php
mv podcatcher.php ~/bin/podcatcher
```

Make sure `~/bin` is in your `$PATH`, then verify it works:

```bash
podcatcher help
```

## Usage

```
podcatcher <command> [options]
```

### Commands

| Command | Description |
|---|---|
| `add <url>` | Subscribe to a feed by RSS URL |
| `list` | List all subscribed feeds |
| `status <slug>` | Show feed details and recent episodes |
| `update` | Refresh feeds and detect new episodes |
| `download [slug]` | Download episode audio files |
| `mark-played <slug>` | Mark episodes as played or unplayed |
| `remove <slug>` | Unsubscribe from a feed |
| `search <query>` | Search episode titles across all feeds |
| `help [command]` | Show help overview or detail for one command |

### Quick examples

```bash
# Subscribe to a feed
podcatcher add https://feeds.megaphone.fm/darknetdiaries

# Subscribe with a custom short name
podcatcher add https://feed.syntax.fm/rss --name syntax

# List all subscriptions
podcatcher list

# Show the 10 most recent episodes
podcatcher status syntax

# Show the 25 most recent episodes
podcatcher status syntax --count 25

# Refresh all feeds
podcatcher update

# Refresh one feed and immediately download any new episodes
podcatcher update --slug syntax --download

# Download a specific episode (number as shown in 'status')
podcatcher download syntax --episode 3

# Download everything not yet on disk
podcatcher download syntax --all

# Mark all episodes of a feed as played
podcatcher mark-played syntax -y

# Mark a single episode as unplayed
podcatcher mark-played syntax --episode 3 --unplayed

# Search across all feeds
podcatcher search "linux"

# Unsubscribe
podcatcher remove syntax
```

### Episode markers in `status` output

```
  ✔  episode has been marked as played
  ⬇  episode audio file has been downloaded to disk
```

## Data storage

All data is kept in `~/.podcatcher/`:

```
~/.podcatcher/
├── feeds.json            # subscription database (feeds, episodes, played state)
└── episodes/
    ├── syntax/           # downloaded audio files, one directory per feed slug
    └── darknetdiaries/
```

Downloaded audio files are **not** removed when you unsubscribe from a feed. To clean them up manually:

```bash
rm -rf ~/.podcatcher/episodes/<slug>
```

## Full command reference

```bash
podcatcher help           # overview of all commands
podcatcher help add       # detailed help for a specific command
podcatcher help download
```

## License

MIT
