#!/usr/bin/env php
<?php
/**
 * Podcatcher - A command-line podcast manager
 * Ported from Python to PHP
 */

declare(strict_types=1);

// ─── Config & Storage ──────────────────────────────────────────────────────────

define('USER_AGENT', 'Podcatcher/1.0 +https://github.com/podcatcher');
define('DATA_DIR', getenv('HOME') . '/.podcatcher');
define('FEEDS_FILE', DATA_DIR . '/feeds.json');
define('EPISODES_DIR', DATA_DIR . '/episodes');

function ensure_dirs(): void {
    if (!is_dir(DATA_DIR)) mkdir(DATA_DIR, 0755, true);
    if (!is_dir(EPISODES_DIR)) mkdir(EPISODES_DIR, 0755, true);
}

function episode_dir(string $slug): string {
    $path = EPISODES_DIR . '/' . $slug;
    if (!is_dir($path)) mkdir($path, 0755, true);
    return $path;
}

function safe_filename(string $title, string $url): string {
    $parsed = parse_url($url);
    $ext = pathinfo($parsed['path'] ?? '', PATHINFO_EXTENSION);
    $ext = $ext ? '.' . $ext : '.mp3';
    $name = strtolower($title);
    $name = preg_replace('/[^\w\s-]/', '', $name);
    $name = preg_replace('/[\s_-]+/', '-', $name);
    $name = substr(trim($name, '-'), 0, 80);
    return $name . $ext;
}

function load_feeds(): array {
    if (!file_exists(FEEDS_FILE)) return [];
    $contents = file_get_contents(FEEDS_FILE);
    return json_decode($contents, true) ?? [];
}

function save_feeds(array $feeds): void {
    file_put_contents(FEEDS_FILE, json_encode($feeds, JSON_PRETTY_PRINT));
}

// ─── HTTP helpers ──────────────────────────────────────────────────────────────

function open_url(string $url, int $timeout = 30): array|false {
    $ctx = stream_context_create([
        'http' => [
            'header'  => 'User-Agent: ' . USER_AGENT,
            'timeout' => $timeout,
            'follow_location' => true,
        ],
        'https' => [
            'header'  => 'User-Agent: ' . USER_AGENT,
            'timeout' => $timeout,
            'follow_location' => true,
        ],
    ]);

    $body = @file_get_contents($url, false, $ctx);
    if ($body === false) return false;

    // Parse response headers
    $headers = [];
    $raw_headers = function_exists('http_get_last_response_headers')
        ? (http_get_last_response_headers() ?? [])
        : ($http_response_header ?? []);
    if (!empty($raw_headers)) {
        foreach ($raw_headers as $line) {
            if (preg_match('/^([^:]+):\s*(.+)$/i', $line, $m)) {
                $headers[strtolower($m[1])] = trim($m[2]);
            }
        }
    }

    return ['body' => $body, 'headers' => $headers];
}

function download_episode(array &$ep, string $slug): string|null {
    $url = $ep['audio_url'];
    $filename = safe_filename($ep['title'], $url);
    $dest_dir = episode_dir($slug);
    $dest = $dest_dir . '/' . $filename;

    if (file_exists($dest)) return $dest;

    $short_title = substr($ep['title'], 0, 55);
    echo "  ↓ {$short_title}\n";
    echo "    {$url}\n";

    $ctx = stream_context_create([
        'http'  => ['header' => 'User-Agent: ' . USER_AGENT, 'timeout' => 30, 'follow_location' => true],
        'https' => ['header' => 'User-Agent: ' . USER_AGENT, 'timeout' => 30, 'follow_location' => true],
    ]);

    $in = @fopen($url, 'rb', false, $ctx);
    if (!$in) {
        echo "\n    [ERROR] Could not open URL\n";
        return null;
    }

    // Try to get Content-Length from response headers
    $total = 0;
    $raw_headers = function_exists('http_get_last_response_headers')
        ? (http_get_last_response_headers() ?? [])
        : ($http_response_header ?? []);
    if (!empty($raw_headers)) {
        foreach ($raw_headers as $h) {
            if (stripos($h, 'content-length:') === 0) {
                $total = (int) trim(substr($h, 15));
            }
        }
    }

    $out = fopen($dest, 'wb');
    if (!$out) {
        fclose($in);
        echo "\n    [ERROR] Could not write to {$dest}\n";
        return null;
    }

    $downloaded = 0;
    $chunk = 64 * 1024;

    try {
        while (!feof($in)) {
            $buf = fread($in, $chunk);
            if ($buf === false) break;
            fwrite($out, $buf);
            $downloaded += strlen($buf);

            if ($total > 0) {
                $pct = (int) ($downloaded * 100 / $total);
                $filled = (int) ($pct / 5);
                $bar = str_repeat('█', $filled) . str_repeat('░', 20 - $filled);
                $mb_done = number_format($downloaded / 1_048_576, 1);
                $mb_total = number_format($total / 1_048_576, 1);
                echo "\r    [{$bar}] {$pct}%  {$mb_done}/{$mb_total} MB";
            } else {
                $mb_done = number_format($downloaded / 1_048_576, 1);
                echo "\r    {$mb_done} MB downloaded…";
            }
        }
        echo "\n";
    } catch (Throwable $e) {
        echo "\n    [ERROR] " . $e->getMessage() . "\n";
        fclose($in);
        fclose($out);
        if (file_exists($dest)) unlink($dest);
        return null;
    }

    fclose($in);
    fclose($out);
    return $dest;
}

// ─── RSS Parsing ───────────────────────────────────────────────────────────────

function fetch_feed_xml(string $url): string|null {
    $result = open_url($url, 15);
    if ($result === false) {
        echo "  [ERROR] Could not fetch feed.\n";
        return null;
    }
    return $result['body'];
}

function parse_feed(string $xml_string): array|null {
    libxml_use_internal_errors(true);
    $root = simplexml_load_string($xml_string);
    if ($root === false) {
        $errors = libxml_get_errors();
        $msg = $errors ? $errors[0]->message : 'unknown error';
        echo "  [ERROR] Failed to parse XML: {$msg}\n";
        return null;
    }

    $channel = $root->channel ?? null;
    if ($channel === null) {
        echo "  [ERROR] No <channel> found in feed.\n";
        return null;
    }

    // Register iTunes namespace
    $ns_itunes = 'http://www.itunes.com/dtds/podcast-1.0.dtd';

    $title       = trim((string)($channel->title ?? '')) ?: 'Untitled Podcast';
    $description = trim((string)($channel->description ?? ''));
    $link        = trim((string)($channel->link ?? ''));
    $last_build  = trim((string)($channel->lastBuildDate ?? ''));

    $image_url = '';
    if (isset($channel->image->url)) {
        $image_url = trim((string)$channel->image->url);
    }
    if (!$image_url) {
        $itunes = $channel->children($ns_itunes);
        if (isset($itunes->image)) {
            $image_url = (string)($itunes->image->attributes()['href'] ?? '');
        }
    }

    $episodes = [];
    foreach ($channel->item as $item) {
        $ep = parse_episode($item);
        if ($ep) $episodes[] = $ep;
    }

    return [
        'title'       => $title,
        'description' => substr($description, 0, 200),
        'link'        => $link,
        'last_build'  => $last_build,
        'image_url'   => $image_url,
        'episodes'    => $episodes,
    ];
}

function parse_episode(SimpleXMLElement $item): array|null {
    $ns_itunes = 'http://www.itunes.com/dtds/podcast-1.0.dtd';
    $itunes = $item->children($ns_itunes);

    $title       = trim((string)($item->title ?? '')) ?: 'Untitled Episode';
    $pub_date    = trim((string)($item->pubDate ?? ''));
    $guid        = trim((string)($item->guid ?? ''));
    $description = trim((string)($item->description ?? ''));
    $duration    = trim((string)($itunes->duration ?? ''));

    $audio_url = '';
    $file_size = 0;
    $mime_type = '';

    if (isset($item->enclosure)) {
        $enc = $item->enclosure->attributes();
        $audio_url = (string)($enc['url'] ?? '');
        $file_size = (int)($enc['length'] ?? 0);
        $mime_type = (string)($enc['type'] ?? '');
    }

    if (!$audio_url) return null;

    return [
        'title'       => $title,
        'pub_date'    => $pub_date,
        'guid'        => $guid ?: $audio_url,
        'audio_url'   => $audio_url,
        'file_size'   => $file_size,
        'mime_type'   => $mime_type,
        'duration'    => $duration,
        'description' => substr(trim($description), 0, 300),
    ];
}

// ─── Feed slug helpers ─────────────────────────────────────────────────────────

function slugify(string $title): string {
    $s = strtolower($title);
    $s = preg_replace('/[^\w\s-]/', '', $s);
    $s = preg_replace('/[\s_-]+/', '-', $s);
    $s = trim($s, '-');
    $s = substr($s, 0, 40);
    return $s ?: 'podcast';
}

function unique_slug(string $slug, array $feeds): string {
    if (!isset($feeds[$slug])) return $slug;
    $i = 2;
    while (isset($feeds["{$slug}-{$i}"])) $i++;
    return "{$slug}-{$i}";
}

// ─── Commands ──────────────────────────────────────────────────────────────────

function cmd_add(array $args): void {
    $url = trim($args['url']);
    $parsed = parse_url($url);
    if (!in_array($parsed['scheme'] ?? '', ['http', 'https'])) {
        echo "[ERROR] URL must start with http:// or https://\n";
        exit(1);
    }

    $feeds = load_feeds();

    foreach ($feeds as $slug => $feed) {
        if ($feed['url'] === $url) {
            $t = $feed['meta']['title'];
            echo "[INFO] Feed already exists as '{$slug}': {$t}\n";
            return;
        }
    }

    echo "Fetching feed from {$url} ...\n";
    $xml_string = fetch_feed_xml($url);
    if ($xml_string === null) exit(1);

    $meta = parse_feed($xml_string);
    if ($meta === null) exit(1);

    $episodes = $meta['episodes'];
    unset($meta['episodes']);

    $slug = $args['name'] ? $args['name'] : slugify($meta['title']);
    $slug = unique_slug($slug, $feeds);

    $known_guids = array_column($episodes, 'guid');

    $feeds[$slug] = [
        'url'          => $url,
        'added'        => date('Y-m-d\TH:i:s'),
        'last_updated' => date('Y-m-d\TH:i:s'),
        'meta'         => $meta,
        'episodes'     => $episodes,
        'known_guids'  => $known_guids,
    ];

    save_feeds($feeds);
    $ep_count = count($episodes);
    $title = $meta['title'];
    echo "\n  ✔ Added '{$title}' as [{$slug}]\n";
    echo "    {$ep_count} episode(s) found.\n";
}

function cmd_list(array $args): void {
    $feeds = load_feeds();
    if (!$feeds) {
        echo "No feeds. Add one with:  podcatcher add <url>\n";
        return;
    }

    $col_w = max(array_map('strlen', array_keys($feeds))) + 2;
    printf("\n%-{$col_w}s %9s  %-22s  %s\n", 'SLUG', 'EPISODES', 'LAST UPDATED', 'TITLE');
    echo str_repeat('─', 90) . "\n";
    foreach ($feeds as $slug => $feed) {
        $ep_count = count($feed['episodes'] ?? []);
        $updated  = substr($feed['last_updated'] ?? '', 0, 19);
        $title    = substr($feed['meta']['title'], 0, 45);
        printf("%-{$col_w}s %9d  %-22s  %s\n", $slug, $ep_count, $updated, $title);
    }
    echo "\n";
}

function cmd_status(array $args): void {
    $feeds = load_feeds();
    $slug  = $args['slug'];

    if (!isset($feeds[$slug])) {
        echo "[ERROR] No feed with slug '{$slug}'. Run 'list' to see all feeds.\n";
        exit(1);
    }

    $feed     = $feeds[$slug];
    $meta     = $feed['meta'];
    $episodes = $feed['episodes'] ?? [];

    echo "\n" . str_repeat('═', 60) . "\n";
    echo "  {$meta['title']}\n";
    echo str_repeat('═', 60) . "\n";
    echo "  Slug       : {$slug}\n";
    echo "  URL        : {$feed['url']}\n";
    echo "  Added      : " . ($feed['added'] ?? '') . "\n";
    echo "  Updated    : " . ($feed['last_updated'] ?? '') . "\n";
    echo "  Episodes   : " . count($episodes) . "\n";
    if (!empty($meta['description'])) {
        $desc = substr($meta['description'], 0, 120);
        echo "  Description: {$desc}\n";
    }
    echo "\n";

    if (!$episodes) {
        echo "  No episodes found.\n";
        return;
    }

    $played_count = count(array_filter($episodes, fn($ep) => !empty($ep['played'])));
    $total        = count($episodes);
    echo "  Played     : {$played_count} / {$total}\n\n";

    $count = min($args['count'] ?? 10, $total);
    echo "  Latest {$count} episode(s):\n";
    echo "  " . str_repeat('─', 56) . "\n";

    for ($i = 0; $i < $count; $i++) {
        $ep     = $episodes[$i];
        $num    = $i + 1;
        $pub    = substr($ep['pub_date'] ?? '', 0, 22);
        $dur    = !empty($ep['duration']) ? " [{$ep['duration']}]" : '';
        $size   = !empty($ep['file_size']) ? ' ' . (int)($ep['file_size'] / 1_000_000) . 'MB' : '';
        $played = !empty($ep['played']) ? ' ✔' : '  ';
        $dl     = (!empty($ep['local_path']) && file_exists($ep['local_path'])) ? ' ⬇' : '  ';
        $title  = substr($ep['title'], 0, 48);
        printf("  %3d.%s%s %s\n", $num, $played, $dl, $title);
        echo "        {$pub}{$dur}{$size}\n";
    }
    echo "\n";
}

function cmd_update(array $args): void {
    $feeds = load_feeds();
    if (!$feeds) {
        echo "No feeds to update.\n";
        return;
    }

    if (!empty($args['slug'])) {
        if (!isset($feeds[$args['slug']])) {
            echo "[ERROR] No feed with slug '{$args['slug']}'.\n";
            exit(1);
        }
        $targets = [$args['slug'] => $feeds[$args['slug']]];
    } else {
        $targets = $feeds;
    }

    $total_new = 0;

    foreach ($targets as $slug => $feed) {
        echo "\nUpdating [{$slug}] — {$feed['meta']['title']}\n";
        echo "  URL: {$feed['url']}\n";

        $xml_string = fetch_feed_xml($feed['url']);
        if ($xml_string === null) { echo "  [SKIP] Could not fetch feed.\n"; continue; }

        $parsed = parse_feed($xml_string);
        if ($parsed === null) { echo "  [SKIP] Could not parse feed.\n"; continue; }

        $new_episodes = $parsed['episodes'];
        unset($parsed['episodes']);

        $known_guids = array_flip($feeds[$slug]['known_guids'] ?? []);
        $fresh = array_filter($new_episodes, fn($ep) => !isset($known_guids[$ep['guid']]));
        $fresh = array_values($fresh);

        // Preserve played and local_path state
        $played_guids = [];
        $local_paths  = [];
        foreach ($feeds[$slug]['episodes'] ?? [] as $ep) {
            if (!empty($ep['played']))     $played_guids[$ep['guid']] = true;
            if (!empty($ep['local_path'])) $local_paths[$ep['guid']]  = $ep['local_path'];
        }

        foreach ($new_episodes as &$ep) {
            $ep['played']     = isset($played_guids[$ep['guid']]);
            $ep['local_path'] = $local_paths[$ep['guid']] ?? '';
        }
        unset($ep);

        $feeds[$slug]['meta']         = array_merge($feeds[$slug]['meta'], $parsed);
        $feeds[$slug]['episodes']     = $new_episodes;
        $feeds[$slug]['known_guids']  = array_column($new_episodes, 'guid');
        $feeds[$slug]['last_updated'] = date('Y-m-d\TH:i:s');

        if ($fresh) {
            $cnt = count($fresh);
            echo "  ✔ {$cnt} new episode(s):\n";
            foreach (array_slice($fresh, 0, 5) as $ep) {
                echo "    + " . substr($ep['title'], 0, 60) . "\n";
            }
            if ($cnt > 5) echo "    … and " . ($cnt - 5) . " more\n";

            if (!empty($args['download'])) {
                echo "\n  Downloading {$cnt} new episode(s)…\n";
                foreach ($fresh as &$ep) {
                    $local = download_episode($ep, $slug);
                    if ($local) {
                        $ep['local_path'] = $local;
                        echo "    ✔ Saved to {$local}\n";
                    }
                }
                unset($ep);
                // Update local_paths in main feed episodes array
                $local_by_guid = [];
                foreach ($fresh as $ep) {
                    if (!empty($ep['local_path'])) $local_by_guid[$ep['guid']] = $ep['local_path'];
                }
                foreach ($feeds[$slug]['episodes'] as &$ep) {
                    if (isset($local_by_guid[$ep['guid']])) $ep['local_path'] = $local_by_guid[$ep['guid']];
                }
                unset($ep);
            }
        } else {
            echo "  ✔ No new episodes.\n";
        }

        $total_new += count($fresh);
    }

    save_feeds($feeds);
    $n_targets = count($targets);
    echo "\nDone. {$total_new} new episode(s) across {$n_targets} feed(s).\n\n";
}

function cmd_remove(array $args): void {
    $feeds = load_feeds();
    $slug  = $args['slug'];
    if (!isset($feeds[$slug])) {
        echo "[ERROR] No feed with slug '{$slug}'.\n";
        exit(1);
    }

    $title = $feeds[$slug]['meta']['title'];
    if (empty($args['yes'])) {
        echo "Remove '{$title}' [{$slug}]? [y/N] ";
        $confirm = strtolower(trim(fgets(STDIN)));
        if ($confirm !== 'y') { echo "Aborted.\n"; return; }
    }

    unset($feeds[$slug]);
    save_feeds($feeds);
    echo "  ✔ Removed '{$title}'.\n";
}

function cmd_search(array $args): void {
    $feeds = load_feeds();
    $query = strtolower($args['query']);
    $limit = $args['limit'] ?? 10;
    $found = false;

    foreach ($feeds as $slug => $feed) {
        $matches = array_filter(
            $feed['episodes'] ?? [],
            fn($ep) => str_contains(strtolower($ep['title']), $query)
                    || str_contains(strtolower($ep['description'] ?? ''), $query)
        );
        $matches = array_values($matches);

        if ($matches) {
            $found = true;
            echo "\n[{$slug}] {$feed['meta']['title']}\n";
            foreach (array_slice($matches, 0, $limit) as $ep) {
                echo '  • ' . substr($ep['title'], 0, 70) . "\n";
                echo '    ' . substr($ep['pub_date'] ?? '', 0, 22) . "\n";
            }
        }
    }

    if (!$found) {
        echo "No episodes matched '{$args['query']}'.\n";
    }
}

function cmd_mark_played(array $args): void {
    $feeds = load_feeds();
    $slug  = $args['slug'];

    if (!isset($feeds[$slug])) {
        echo "[ERROR] No feed with slug '{$slug}'. Run 'list' to see all feeds.\n";
        exit(1);
    }

    $episodes = &$feeds[$slug]['episodes'];
    if (!$episodes) { echo "  No episodes found.\n"; return; }

    $title    = $feeds[$slug]['meta']['title'];
    $unplayed = !empty($args['unplayed']);
    $action   = $unplayed ? 'unplayed' : 'played';

    if (!empty($args['episode'])) {
        $idx = (int)$args['episode'] - 1;
        if ($idx < 0 || $idx >= count($episodes)) {
            echo "[ERROR] Episode number must be between 1 and " . count($episodes) . ".\n";
            exit(1);
        }
        $ep = &$episodes[$idx];
        if (!empty($ep['played']) && !$unplayed) {
            echo "  Already marked played: " . substr($ep['title'], 0, 60) . "\n";
            unset($ep);
            return;
        }
        $ep['played'] = !$unplayed;
        echo "  ✔ Marked {$action}: " . substr($ep['title'], 0, 60) . "\n";
        unset($ep);
    } else {
        $cnt = count($episodes);
        if (empty($args['yes'])) {
            echo "Mark all {$cnt} episodes of '{$title}' as {$action}? [y/N] ";
            $confirm = strtolower(trim(fgets(STDIN)));
            if ($confirm !== 'y') { echo "Aborted.\n"; return; }
        }
        foreach ($episodes as &$ep) {
            $ep['played'] = !$unplayed;
        }
        unset($ep);
        echo "  ✔ Marked all {$cnt} episode(s) as {$action}.\n";
    }

    save_feeds($feeds);
}

function cmd_download(array $args): void {
    $feeds = load_feeds();

    if (!empty($args['slug'])) {
        if (!isset($feeds[$args['slug']])) {
            echo "[ERROR] No feed with slug '{$args['slug']}'.\n";
            exit(1);
        }
        $targets = [$args['slug'] => $feeds[$args['slug']]];
    } else {
        $targets = $feeds;
    }

    if (!$targets) {
        echo "No feeds. Add one with:  podcatcher add <url>\n";
        return;
    }

    $total_ok = $total_fail = 0;

    foreach ($targets as $slug => &$feed) {
        $episodes = &$feed['episodes'];
        if (!$episodes) continue;

        if (!empty($args['episode'])) {
            if (empty($args['slug'])) {
                echo "[ERROR] --episode requires a slug argument.\n";
                exit(1);
            }
            $idx = (int)$args['episode'] - 1;
            if ($idx < 0 || $idx >= count($episodes)) {
                echo "[ERROR] Episode number must be between 1 and " . count($episodes) . ".\n";
                exit(1);
            }
            $queue = [&$episodes[$idx]];
        } elseif (!empty($args['all'])) {
            $queue = array_filter($episodes, fn($ep) => empty($ep['local_path']) || !file_exists($ep['local_path']));
        } else {
            $queue = array_filter($episodes, fn($ep) => empty($ep['local_path']));
        }

        $queue = array_values($queue);

        if (!$queue) {
            echo "[{$slug}] Nothing to download.\n";
            continue;
        }

        $cnt = count($queue);
        echo "\n[{$slug}] {$feed['meta']['title']}  —  {$cnt} episode(s) to download\n";

        foreach ($queue as &$ep) {
            $local = download_episode($ep, $slug);
            if ($local) {
                $ep['local_path'] = $local;
                // Update in main episodes array by guid
                foreach ($episodes as &$main_ep) {
                    if ($main_ep['guid'] === $ep['guid']) {
                        $main_ep['local_path'] = $local;
                        break;
                    }
                }
                unset($main_ep);
                echo "    ✔ Saved: {$local}\n";
                $total_ok++;
            } else {
                $total_fail++;
            }
        }
        unset($ep);
    }
    unset($feed);

    // Merge changes back into $feeds
    foreach ($targets as $slug => $feed) {
        $feeds[$slug] = $feed;
    }

    save_feeds($feeds);
    echo "\nDownload complete: {$total_ok} succeeded, {$total_fail} failed.\n\n";
}

function cmd_help(array $args): void {
    $topic = $args['topic'] ?? null;
    $W = 60;

    $HELP = [
        'add' => <<<'HELP'
  add <url> [--name SLUG]

  Subscribe to a new podcast by its RSS feed URL. Podcatcher fetches the feed
  immediately to verify it and store the current episode list.

  Arguments:
    url           RSS/Atom feed URL (must begin with http:// or https://)

  Options:
    --name SLUG   Give the feed a custom short name instead of the one derived
                  from the podcast title. The name is used as the slug in all
                  other commands.

  Examples:
    podcatcher add https://feeds.megaphone.fm/darknetdiaries
    podcatcher add https://feed.syntax.fm/rss
    podcatcher add https://feed.syntax.fm/rss --name syntax

HELP,
        'list' => <<<'HELP'
  list

  Print a summary table of every subscribed feed showing its slug, total
  episode count, date last refreshed, and title.

  Examples:
    podcatcher list

HELP,
        'status' => <<<'HELP'
  status <slug> [--count N]

  Show detailed information about a single feed and a numbered list of its
  most recent episodes. Each episode line displays:
    ✔  — episode has been marked played
    ⬇  — episode file has been downloaded to disk

  Arguments:
    slug          Feed slug (shown in the leftmost column of 'list')

  Options:
    --count N     How many recent episodes to show (default: 10)

  Examples:
    podcatcher status darknetdiaries
    podcatcher status darknetdiaries --count 25
    podcatcher status syntax --count 3

HELP,
        'update' => <<<'HELP'
  update [--slug SLUG] [--download]

  Re-fetch one or all feeds to discover new episodes. Without --slug every
  subscribed feed is refreshed. Played flags and local file paths recorded
  from previous runs are preserved across the update.

  Options:
    --slug SLUG   Refresh only this feed
    --download    After updating, immediately download any newly found episodes

  Examples:
    podcatcher update
    podcatcher update --slug syntax
    podcatcher update --download
    podcatcher update --slug darknetdiaries --download

HELP,
        'download' => <<<'HELP'
  download [SLUG] [--episode N] [--all]

  Download episode audio files to ~/.podcatcher/episodes/<slug>/.
  Files are named after the episode title and keep their original extension
  (.mp3, .m4a, etc.). A progress bar is shown for each file.

  By default only episodes that have never been downloaded are queued.
  Already-downloaded files are skipped even if --all is passed.

  Arguments:
    SLUG          Feed slug. Omit to download from every subscribed feed.

  Options:
    --episode N   Download only episode number N (as shown in 'status').
                  Requires a slug to be given.
    --all         Download every episode not already on disk, not just new ones.

  Examples:
    podcatcher download syntax
    podcatcher download syntax --episode 7
    podcatcher download syntax --all
    podcatcher download
    podcatcher download --all

HELP,
        'mark-played' => <<<'HELP'
  mark-played <slug> [--episode N] [--unplayed] [-y]

  Mark episodes of a feed as played or unplayed. The played state is shown
  as a ✔ marker in 'status' output and is preserved across feed updates.

  Arguments:
    slug          Feed slug

  Options:
    --episode N   Mark only episode number N (as shown in 'status').
                  Omit to mark every episode in the feed.
    --unplayed    Reverse the operation — mark as unplayed instead of played.
    -y, --yes     Skip the confirmation prompt when marking all episodes.

  Examples:
    podcatcher mark-played darknetdiaries
    podcatcher mark-played darknetdiaries -y
    podcatcher mark-played darknetdiaries --episode 12
    podcatcher mark-played darknetdiaries --unplayed
    podcatcher mark-played darknetdiaries --episode 3 --unplayed

HELP,
        'remove' => <<<'HELP'
  remove <slug> [-y]

  Unsubscribe from a feed. The feed's metadata and episode list are deleted
  from ~/.podcatcher/feeds.json. Downloaded audio files on disk are NOT
  removed — delete ~/.podcatcher/episodes/<slug>/ manually if needed.

  Arguments:
    slug          Feed slug

  Options:
    -y, --yes     Skip the confirmation prompt.

  Examples:
    podcatcher remove syntax
    podcatcher remove syntax -y

HELP,
        'search' => <<<'HELP'
  search <query> [--limit N]

  Search episode titles and descriptions across every subscribed feed.
  Results are grouped by feed.

  Arguments:
    query         Search term (case-insensitive)

  Options:
    --limit N     Maximum results to show per feed (default: 10)

  Examples:
    podcatcher search "javascript"
    podcatcher search "security" --limit 5
    podcatcher search linux

HELP,
    ];

    if ($topic) {
        $key = strtolower(str_replace('_', '-', $topic));
        if (!isset($HELP[$key])) {
            $available = implode(', ', array_keys($HELP));
            echo "[ERROR] Unknown command '{$topic}'. Available: {$available}\n";
            exit(1);
        }
        echo "\n" . str_repeat('═', $W) . "\n";
        echo "  podcatcher {$key}\n";
        echo str_repeat('═', $W) . "\n";
        echo $HELP[$key];
        return;
    }

    echo <<<EOT

════════════════════════════════════════════════════════════
  Podcatcher  —  command-line podcast manager
════════════════════════════════════════════════════════════

  Data is stored in ~/.podcatcher/
    feeds.json          subscription database
    episodes/<slug>/    downloaded audio files

  Episode markers shown in 'status':
    ✔  played      ⬇  downloaded to disk

  Usage:  podcatcher <command> [options]

────────────────────────────────────────────────────────────
  COMMAND        SUMMARY
────────────────────────────────────────────────────────────
  add            Subscribe to a feed by RSS URL
  list           List all subscribed feeds
  status         Show feed details and recent episodes
  update         Refresh feeds, optionally download new episodes
  download       Download episode audio files
  mark-played    Mark episodes as played or unplayed
  remove         Unsubscribe from a feed
  search         Search episode titles across all feeds
  help           Show this reference (or detail on one command)
────────────────────────────────────────────────────────────

  Run  podcatcher help <command>  for full syntax and examples.

  Quick examples:
    podcatcher add https://feeds.megaphone.fm/darknetdiaries
    podcatcher add https://feed.syntax.fm/rss --name syntax
    podcatcher list
    podcatcher status syntax
    podcatcher update --download
    podcatcher download syntax --episode 3
    podcatcher mark-played syntax -y
    podcatcher search "linux"
    podcatcher remove syntax

EOT;
}

// ─── Argument Parsing ──────────────────────────────────────────────────────────

function parse_args(array $argv): array {
    array_shift($argv); // remove script name

    if (empty($argv)) {
        show_usage();
        exit(1);
    }

    $command = array_shift($argv);
    $args    = ['command' => $command];

    switch ($command) {
        case 'add':
            $args['url']  = null;
            $args['name'] = null;
            $i = 0;
            while ($i < count($argv)) {
                if ($argv[$i] === '--name' && isset($argv[$i + 1])) {
                    $args['name'] = $argv[++$i];
                } elseif ($args['url'] === null) {
                    $args['url'] = $argv[$i];
                }
                $i++;
            }
            if (!$args['url']) { echo "[ERROR] 'add' requires a URL.\n"; exit(1); }
            break;

        case 'list':
            break;

        case 'status':
            $args['slug']  = null;
            $args['count'] = 10;
            $i = 0;
            while ($i < count($argv)) {
                if ($argv[$i] === '--count' && isset($argv[$i + 1])) {
                    $args['count'] = (int)$argv[++$i];
                } elseif ($args['slug'] === null) {
                    $args['slug'] = $argv[$i];
                }
                $i++;
            }
            if (!$args['slug']) { echo "[ERROR] 'status' requires a slug.\n"; exit(1); }
            break;

        case 'update':
            $args['slug']     = null;
            $args['download'] = false;
            $i = 0;
            while ($i < count($argv)) {
                if ($argv[$i] === '--slug' && isset($argv[$i + 1])) {
                    $args['slug'] = $argv[++$i];
                } elseif ($argv[$i] === '--download') {
                    $args['download'] = true;
                }
                $i++;
            }
            break;

        case 'remove':
            $args['slug'] = null;
            $args['yes']  = false;
            $i = 0;
            while ($i < count($argv)) {
                if (in_array($argv[$i], ['-y', '--yes'])) {
                    $args['yes'] = true;
                } elseif ($args['slug'] === null) {
                    $args['slug'] = $argv[$i];
                }
                $i++;
            }
            if (!$args['slug']) { echo "[ERROR] 'remove' requires a slug.\n"; exit(1); }
            break;

        case 'search':
            $args['query'] = null;
            $args['limit'] = 10;
            $i = 0;
            while ($i < count($argv)) {
                if ($argv[$i] === '--limit' && isset($argv[$i + 1])) {
                    $args['limit'] = (int)$argv[++$i];
                } elseif ($args['query'] === null) {
                    $args['query'] = $argv[$i];
                }
                $i++;
            }
            if (!$args['query']) { echo "[ERROR] 'search' requires a query.\n"; exit(1); }
            break;

        case 'mark-played':
            $args['slug']     = null;
            $args['episode']  = null;
            $args['unplayed'] = false;
            $args['yes']      = false;
            $i = 0;
            while ($i < count($argv)) {
                if ($argv[$i] === '--episode' && isset($argv[$i + 1])) {
                    $args['episode'] = (int)$argv[++$i];
                } elseif ($argv[$i] === '--unplayed') {
                    $args['unplayed'] = true;
                } elseif (in_array($argv[$i], ['-y', '--yes'])) {
                    $args['yes'] = true;
                } elseif ($args['slug'] === null) {
                    $args['slug'] = $argv[$i];
                }
                $i++;
            }
            if (!$args['slug']) { echo "[ERROR] 'mark-played' requires a slug.\n"; exit(1); }
            break;

        case 'download':
            $args['slug']    = null;
            $args['episode'] = null;
            $args['all']     = false;
            $i = 0;
            while ($i < count($argv)) {
                if ($argv[$i] === '--episode' && isset($argv[$i + 1])) {
                    $args['episode'] = (int)$argv[++$i];
                } elseif ($argv[$i] === '--all') {
                    $args['all'] = true;
                } elseif ($argv[$i][0] !== '-' && $args['slug'] === null) {
                    $args['slug'] = $argv[$i];
                }
                $i++;
            }
            break;

        case 'help':
            $args['topic'] = $argv[0] ?? null;
            break;

        default:
            echo "[ERROR] Unknown command '{$command}'.\n";
            show_usage();
            exit(1);
    }

    return $args;
}

function show_usage(): void {
    echo <<<EOT
Podcatcher — command-line podcast manager

Usage: podcatcher <command> [options]

Commands:
  add           Subscribe to a feed by RSS URL
  list          List all subscribed feeds
  status        Show feed details and recent episodes
  update        Refresh feeds, optionally download new episodes
  download      Download episode audio files
  mark-played   Mark episodes as played or unplayed
  remove        Unsubscribe from a feed
  search        Search episode titles across all feeds
  help          Show command reference

Run  podcatcher help  for full reference.
EOT;
}

// ─── Entry Point ───────────────────────────────────────────────────────────────

function main(array $argv): void {
    ensure_dirs();
    $args = parse_args($argv);

    $dispatch = [
        'add'         => 'cmd_add',
        'list'        => 'cmd_list',
        'status'      => 'cmd_status',
        'update'      => 'cmd_update',
        'remove'      => 'cmd_remove',
        'search'      => 'cmd_search',
        'mark-played' => 'cmd_mark_played',
        'download'    => 'cmd_download',
        'help'        => 'cmd_help',
    ];

    $fn = $dispatch[$args['command']] ?? null;
    if (!$fn) {
        echo "[ERROR] Unknown command '{$args['command']}'.\n";
        exit(1);
    }

    $fn($args);
}

main($argv);
