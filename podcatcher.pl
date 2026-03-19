#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use open ':std', ':encoding(UTF-8)';

# ─── Dependencies (core modules only) ─────────────────────────────────────────
use File::Basename qw(basename dirname);
use File::Path     qw(make_path);
use File::Spec;
use Cwd            qw(abs_path);
use JSON::PP;
use XML::Parser;
use LWP::UserAgent;
use URI;
use POSIX          qw(floor);
use Scalar::Util   qw(looks_like_number);

# ─── Config & Storage ──────────────────────────────────────────────────────────

use constant USER_AGENT  => 'Podcatcher/1.0 +https://github.com/podcatcher';
use constant DATA_DIR    => File::Spec->catdir($ENV{HOME}, '.podcatcher');
use constant FEEDS_FILE  => File::Spec->catfile(DATA_DIR, 'feeds.json');
use constant EPISODES_DIR => File::Spec->catdir(DATA_DIR, 'episodes');

my $ua = LWP::UserAgent->new(
    agent           => USER_AGENT,
    timeout         => 30,
    max_redirect    => 10,
);

sub ensure_dirs {
    make_path(DATA_DIR, EPISODES_DIR, { mode => 0755 });
}

sub episode_dir {
    my ($slug) = @_;
    my $path = File::Spec->catdir(EPISODES_DIR, $slug);
    make_path($path, { mode => 0755 });
    return $path;
}

sub safe_filename {
    my ($title, $url) = @_;
    my $uri = URI->new($url);
    my $path_str = $uri->path // '';
    my ($ext) = $path_str =~ /(\.[^.\/]+)$/;
    $ext //= '.mp3';
    my $name = lc $title;
    $name =~ s/[^\w\s-]//g;
    $name =~ s/[\s_-]+/-/g;
    $name =~ s/^-+|-+$//g;
    $name = substr($name, 0, 80);
    return $name . $ext;
}

sub load_feeds {
    return {} unless -f FEEDS_FILE;
    open my $fh, '<:encoding(UTF-8)', FEEDS_FILE or die "Cannot read feeds: $!";
    local $/;
    my $json = <$fh>;
    close $fh;
    return decode_json($json);
}

sub save_feeds {
    my ($feeds) = @_;
    my $json = JSON::PP->new->utf8->pretty->canonical->encode($feeds);
    open my $fh, '>:encoding(UTF-8)', FEEDS_FILE or die "Cannot write feeds: $!";
    print $fh $json;
    close $fh;
}

# ─── HTTP helpers ──────────────────────────────────────────────────────────────

sub fetch_url_bytes {
    my ($url, $timeout) = @_;
    $timeout //= 15;
    my $resp = $ua->get($url, 'Timeout' => $timeout);
    unless ($resp->is_success) {
        printf "  [ERROR] HTTP %s: %s\n", $resp->code, $resp->message;
        return undef;
    }
    return $resp->content;
}

sub download_episode {
    my ($ep, $slug) = @_;
    my $url      = $ep->{audio_url};
    my $filename = safe_filename($ep->{title}, $url);
    my $dest_dir = episode_dir($slug);
    my $dest     = File::Spec->catfile($dest_dir, $filename);

    return $dest if -f $dest;

    printf "  ↓ %s\n", substr($ep->{title}, 0, 55);
    print  "    $url\n";

    # HEAD request to get Content-Length
    my $head = $ua->head($url);
    my $total = 0;
    $total = $head->header('Content-Length') // 0 if $head->is_success;

    open my $out_fh, '>:raw', $dest or do {
        print "\n    [ERROR] Cannot open $dest for writing: $!\n";
        return undef;
    };

    my $downloaded = 0;
    my $chunk_size = 64 * 1024;
    my $ok = 1;

    my $resp = $ua->get(
        $url,
        ':content_cb' => sub {
            my ($chunk, $response) = @_;
            print $out_fh $chunk;
            $downloaded += length($chunk);
            if ($total > 0) {
                my $pct    = int($downloaded * 100 / $total);
                my $filled = int($pct / 5);
                my $bar    = ('█' x $filled) . ('░' x (20 - $filled));
                my $mb_done  = sprintf('%.1f', $downloaded / 1_048_576);
                my $mb_total = sprintf('%.1f', $total      / 1_048_576);
                printf "\r    [%s] %3d%%  %s/%s MB", $bar, $pct, $mb_done, $mb_total;
            } else {
                my $mb_done = sprintf('%.1f', $downloaded / 1_048_576);
                print "\r    ${mb_done} MB downloaded…";
            }
        },
    );
    print "\n";
    close $out_fh;

    unless ($resp->is_success) {
        printf "    [ERROR] HTTP %s: %s\n", $resp->code, $resp->message;
        unlink $dest if -f $dest;
        return undef;
    }

    return $dest;
}

# ─── RSS Parsing ───────────────────────────────────────────────────────────────

sub fetch_feed_xml {
    my ($url) = @_;
    my $bytes = fetch_url_bytes($url, 15);
    unless (defined $bytes) {
        print "  [ERROR] Could not fetch feed.\n";
        return undef;
    }
    return $bytes;
}

# We parse RSS with XML::Parser using a simple SAX-style approach.
# We build a tree structure to navigate channel/item elements.

sub parse_feed {
    my ($xml_string) = @_;

    # Use XML::Parser in Tree mode
    my $parser = XML::Parser->new(Style => 'Tree');
    my $tree;
    eval { $tree = $parser->parse($xml_string) };
    if ($@) {
        (my $err = $@) =~ s/ at .+//s;
        print "  [ERROR] Failed to parse XML: $err\n";
        return undef;
    }

    # $tree = [ tag, [ attr_hash, child, child, ... ] ]
    my $root_tag  = $tree->[0];
    my $root_body = $tree->[1];

    # Find <channel> inside <rss> or <feed>
    my $channel_body = find_child_body($root_body, 'channel');
    unless ($channel_body) {
        print "  [ERROR] No <channel> found in feed.\n";
        return undef;
    }

    my $title       = child_text($channel_body, 'title')       // 'Untitled Podcast';
    my $description = child_text($channel_body, 'description') // '';
    my $link        = child_text($channel_body, 'link')        // '';
    my $last_build  = child_text($channel_body, 'lastBuildDate') // '';

    # Image URL: try <image><url> then itunes:image href
    my $image_url = '';
    my $img_body  = find_child_body($channel_body, 'image');
    if ($img_body) {
        $image_url = child_text($img_body, 'url') // '';
    }
    unless ($image_url) {
        $image_url = find_child_attr($channel_body, 'itunes:image', 'href') // '';
    }

    my @episodes;
    my @items = find_all_children($channel_body, 'item');
    for my $item_body (@items) {
        my $ep = parse_episode($item_body);
        push @episodes, $ep if $ep;
    }

    $description = substr($description, 0, 200);

    return {
        title       => $title,
        description => $description,
        link        => $link,
        last_build  => $last_build,
        image_url   => $image_url,
        episodes    => \@episodes,
    };
}

sub parse_episode {
    my ($item_body) = @_;

    my $title       = child_text($item_body, 'title')           // 'Untitled Episode';
    my $pub_date    = child_text($item_body, 'pubDate')         // '';
    my $guid        = child_text($item_body, 'guid')            // '';
    my $description = child_text($item_body, 'description')     // '';
    my $duration    = child_text($item_body, 'itunes:duration') // '';

    my ($audio_url, $file_size, $mime_type) = ('', 0, '');
    my $enc_attrs = find_child_attr_hash($item_body, 'enclosure');
    if ($enc_attrs) {
        $audio_url = $enc_attrs->{url}    // '';
        $file_size = int($enc_attrs->{length} // 0);
        $mime_type = $enc_attrs->{type}   // '';
    }

    return undef unless $audio_url;

    $description = substr($description, 0, 300);
    $description =~ s/^\s+|\s+$//g;

    return {
        title       => $title,
        pub_date    => $pub_date,
        guid        => ($guid || $audio_url),
        audio_url   => $audio_url,
        file_size   => $file_size,
        mime_type   => $mime_type,
        duration    => $duration,
        description => $description,
    };
}

# ─── XML::Parser Tree helpers ─────────────────────────────────────────────────
# Tree format: [ 'tag', [ {attrs}, 0, 'text', 'child_tag', [...], ... ] ]
# Children in the body array alternate: 0 => text node, tagname => body_array

sub find_child_body {
    my ($body, $tag) = @_;
    # body = [ {attrs}, 0, 'text', 'child_tag', [child_body], ... ]
    my $i = 1;
    while ($i < $#$body) {
        my $key = $body->[$i];
        my $val = $body->[$i + 1];
        if ($key ne '0') {
            # Normalize: strip namespace prefix for comparison if needed
            my $local = $key;
            if ($local eq $tag || _tag_matches($local, $tag)) {
                return $val;
            }
        }
        $i += 2;
    }
    return undef;
}

sub find_all_children {
    my ($body, $tag) = @_;
    my @results;
    my $i = 1;
    while ($i < $#$body) {
        my $key = $body->[$i];
        my $val = $body->[$i + 1];
        if ($key ne '0' && _tag_matches($key, $tag)) {
            push @results, $val;
        }
        $i += 2;
    }
    return @results;
}

sub child_text {
    my ($body, $tag) = @_;
    my $child = find_child_body($body, $tag);
    return undef unless $child;
    # Text is at position 2 (after attr hash at 0, then key '0' at 1, text at 2)
    my $text = '';
    my $i = 1;
    while ($i < $#$child) {
        if ($child->[$i] eq '0') {
            $text .= $child->[$i + 1] // '';
        }
        $i += 2;
    }
    $text =~ s/^\s+|\s+$//g;
    return $text eq '' ? undef : $text;
}

sub find_child_attr {
    my ($body, $tag, $attr) = @_;
    my $child = find_child_body($body, $tag);
    return undef unless $child;
    return $child->[0]{$attr};
}

sub find_child_attr_hash {
    my ($body, $tag) = @_;
    my $child = find_child_body($body, $tag);
    return undef unless $child;
    return $child->[0];
}

sub _tag_matches {
    my ($actual, $wanted) = @_;
    return 1 if $actual eq $wanted;
    # Match local part after colon (e.g. 'itunes:duration' matches 'itunes:duration')
    return 1 if $actual =~ /:\Q$wanted\E$/;
    # Strip namespace URI prefix that XML::Parser may expand
    (my $local = $actual) =~ s/^.*[}:]//;
    (my $want_local = $wanted) =~ s/^.*://;
    return $local eq $want_local;
}

# ─── Feed slug helpers ─────────────────────────────────────────────────────────

sub slugify {
    my ($title) = @_;
    my $s = lc $title;
    $s =~ s/[^\w\s-]//g;
    $s =~ s/[\s_-]+/-/g;
    $s =~ s/^-+|-+$//g;
    $s = substr($s, 0, 40);
    return $s || 'podcast';
}

sub unique_slug {
    my ($slug, $feeds) = @_;
    return $slug unless exists $feeds->{$slug};
    my $i = 2;
    $i++ while exists $feeds->{"${slug}-${i}"};
    return "${slug}-${i}";
}

# ─── Timestamp ────────────────────────────────────────────────────────────────

sub now_iso {
    my @t = localtime;
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d',
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

# ─── Commands ──────────────────────────────────────────────────────────────────

sub cmd_add {
    my (%args) = @_;
    my $url = $args{url};
    $url =~ s/^\s+|\s+$//g;

    unless ($url =~ m{^https?://}) {
        print "[ERROR] URL must start with http:// or https://\n";
        exit 1;
    }

    my $feeds = load_feeds();

    for my $slug (keys %$feeds) {
        if ($feeds->{$slug}{url} eq $url) {
            my $t = $feeds->{$slug}{meta}{title};
            print "[INFO] Feed already exists as '$slug': $t\n";
            return;
        }
    }

    print "Fetching feed from $url ...\n";
    my $xml = fetch_feed_xml($url);
    exit 1 unless defined $xml;

    my $meta = parse_feed($xml);
    exit 1 unless defined $meta;

    my $episodes = delete $meta->{episodes};
    my $slug = $args{name} ? $args{name} : slugify($meta->{title});
    $slug = unique_slug($slug, $feeds);

    my @known_guids = map { $_->{guid} } @$episodes;

    $feeds->{$slug} = {
        url          => $url,
        added        => now_iso(),
        last_updated => now_iso(),
        meta         => $meta,
        episodes     => $episodes,
        known_guids  => \@known_guids,
    };

    save_feeds($feeds);
    my $ep_count = scalar @$episodes;
    my $title    = $meta->{title};
    print "\n  ✔ Added '$title' as [$slug]\n";
    print "    $ep_count episode(s) found.\n";
}

sub cmd_list {
    my $feeds = load_feeds();
    unless (%$feeds) {
        print "No feeds. Add one with:  podcatcher add <url>\n";
        return;
    }

    my $col_w = (sort { $b <=> $a } map { length($_) } keys %$feeds)[0] + 2;
    printf "\n%-${col_w}s %9s  %-22s  %s\n", 'SLUG', 'EPISODES', 'LAST UPDATED', 'TITLE';
    print '─' x 90 . "\n";
    for my $slug (keys %$feeds) {
        my $feed     = $feeds->{$slug};
        my $ep_count = scalar @{$feed->{episodes} // []};
        my $updated  = substr($feed->{last_updated} // '', 0, 19);
        my $title    = substr($feed->{meta}{title}, 0, 45);
        printf "%-${col_w}s %9d  %-22s  %s\n", $slug, $ep_count, $updated, $title;
    }
    print "\n";
}

sub cmd_status {
    my (%args) = @_;
    my $feeds = load_feeds();
    my $slug  = $args{slug};

    unless (exists $feeds->{$slug}) {
        print "[ERROR] No feed with slug '$slug'. Run 'list' to see all feeds.\n";
        exit 1;
    }

    my $feed     = $feeds->{$slug};
    my $meta     = $feed->{meta};
    my $episodes = $feed->{episodes} // [];

    print "\n" . '═' x 60 . "\n";
    print "  $meta->{title}\n";
    print '═' x 60 . "\n";
    print "  Slug       : $slug\n";
    print "  URL        : $feed->{url}\n";
    print "  Added      : " . ($feed->{added} // '') . "\n";
    print "  Updated    : " . ($feed->{last_updated} // '') . "\n";
    print "  Episodes   : " . scalar(@$episodes) . "\n";
    if ($meta->{description}) {
        print "  Description: " . substr($meta->{description}, 0, 120) . "\n";
    }
    print "\n";

    unless (@$episodes) {
        print "  No episodes found.\n";
        return;
    }

    my $played_count = scalar grep { $_->{played} } @$episodes;
    my $total        = scalar @$episodes;
    print "  Played     : $played_count / $total\n\n";

    my $count = $args{count} // 10;
    $count = $total if $count > $total;
    print "  Latest $count episode(s):\n";
    print "  " . '─' x 56 . "\n";

    for my $i (0 .. $count - 1) {
        my $ep     = $episodes->[$i];
        my $num    = $i + 1;
        my $pub    = substr($ep->{pub_date} // '', 0, 22);
        my $dur    = $ep->{duration} ? " [$ep->{duration}]" : '';
        my $size   = $ep->{file_size} ? ' ' . int($ep->{file_size} / 1_000_000) . 'MB' : '';
        my $played = $ep->{played}    ? ' ✔' : '  ';
        my $dl     = ($ep->{local_path} && -f $ep->{local_path}) ? ' ⬇' : '  ';
        my $title  = substr($ep->{title}, 0, 48);
        printf "  %3d.%s%s %s\n", $num, $played, $dl, $title;
        print  "        $pub$dur$size\n";
    }
    print "\n";
}

sub cmd_update {
    my (%args) = @_;
    my $feeds = load_feeds();
    unless (%$feeds) {
        print "No feeds to update.\n";
        return;
    }

    my %targets;
    if ($args{slug}) {
        unless (exists $feeds->{$args{slug}}) {
            print "[ERROR] No feed with slug '$args{slug}'.\n";
            exit 1;
        }
        %targets = ($args{slug} => $feeds->{$args{slug}});
    } else {
        %targets = %$feeds;
    }

    my $total_new = 0;

    for my $slug (keys %targets) {
        my $feed = $feeds->{$slug};
        print "\nUpdating [$slug] — $feed->{meta}{title}\n";
        print "  URL: $feed->{url}\n";

        my $xml = fetch_feed_xml($feed->{url});
        unless (defined $xml) { print "  [SKIP] Could not fetch feed.\n"; next; }

        my $parsed = parse_feed($xml);
        unless (defined $parsed) { print "  [SKIP] Could not parse feed.\n"; next; }

        my $new_episodes = delete $parsed->{episodes};

        my %known = map { $_ => 1 } @{$feeds->{$slug}{known_guids} // []};
        my @fresh = grep { !$known{$_->{guid}} } @$new_episodes;

        my %played_guids = map  { $_->{guid} => 1 }
                           grep { $_->{played} }
                           @{$feeds->{$slug}{episodes} // []};
        my %local_paths  = map  { $_->{guid} => $_->{local_path} }
                           grep { $_->{local_path} }
                           @{$feeds->{$slug}{episodes} // []};

        for my $ep (@$new_episodes) {
            $ep->{played}     = $played_guids{$ep->{guid}} ? 1 : 0;
            $ep->{local_path} = $local_paths{$ep->{guid}} // '';
        }

        $feeds->{$slug}{meta}         = { %{$feeds->{$slug}{meta}}, %$parsed };
        $feeds->{$slug}{episodes}     = $new_episodes;
        $feeds->{$slug}{known_guids}  = [ map { $_->{guid} } @$new_episodes ];
        $feeds->{$slug}{last_updated} = now_iso();

        if (@fresh) {
            my $cnt = scalar @fresh;
            print "  ✔ $cnt new episode(s):\n";
            for my $ep (@fresh[0 .. ($cnt > 5 ? 4 : $cnt - 1)]) {
                print "    + " . substr($ep->{title}, 0, 60) . "\n";
            }
            print "    … and " . ($cnt - 5) . " more\n" if $cnt > 5;

            if ($args{download}) {
                print "\n  Downloading $cnt new episode(s)…\n";
                for my $ep (@fresh) {
                    my $local = download_episode($ep, $slug);
                    if ($local) {
                        $ep->{local_path} = $local;
                        # Propagate to main array
                        for my $main_ep (@{$feeds->{$slug}{episodes}}) {
                            if ($main_ep->{guid} eq $ep->{guid}) {
                                $main_ep->{local_path} = $local;
                                last;
                            }
                        }
                        print "    ✔ Saved to $local\n";
                    }
                }
            }
        } else {
            print "  ✔ No new episodes.\n";
        }

        $total_new += scalar @fresh;
    }

    save_feeds($feeds);
    my $n_targets = scalar keys %targets;
    print "\nDone. $total_new new episode(s) across $n_targets feed(s).\n\n";
}

sub cmd_remove {
    my (%args) = @_;
    my $feeds = load_feeds();
    my $slug  = $args{slug};
    unless (exists $feeds->{$slug}) {
        print "[ERROR] No feed with slug '$slug'.\n";
        exit 1;
    }

    my $title = $feeds->{$slug}{meta}{title};
    unless ($args{yes}) {
        print "Remove '$title' [$slug]? [y/N] ";
        my $confirm = lc(<STDIN> // '');
        chomp $confirm;
        if ($confirm ne 'y') { print "Aborted.\n"; return; }
    }

    delete $feeds->{$slug};
    save_feeds($feeds);
    print "  ✔ Removed '$title'.\n";
}

sub cmd_search {
    my (%args) = @_;
    my $feeds = load_feeds();
    my $query = lc $args{query};
    my $limit = $args{limit} // 10;
    my $found = 0;

    for my $slug (keys %$feeds) {
        my $feed    = $feeds->{$slug};
        my @matches = grep {
            index(lc($_->{title}), $query) >= 0 ||
            index(lc($_->{description} // ''), $query) >= 0
        } @{$feed->{episodes} // []};

        if (@matches) {
            $found = 1;
            print "\n[$slug] $feed->{meta}{title}\n";
            for my $ep (@matches[0 .. ($#matches < $limit - 1 ? $#matches : $limit - 1)]) {
                print '  • ' . substr($ep->{title}, 0, 70) . "\n";
                print '    ' . substr($ep->{pub_date} // '', 0, 22) . "\n";
            }
        }
    }

    print "No episodes matched '$args{query}'.\n" unless $found;
}

sub cmd_mark_played {
    my (%args) = @_;
    my $feeds = load_feeds();
    my $slug  = $args{slug};

    unless (exists $feeds->{$slug}) {
        print "[ERROR] No feed with slug '$slug'. Run 'list' to see all feeds.\n";
        exit 1;
    }

    my $episodes = $feeds->{$slug}{episodes};
    unless ($episodes && @$episodes) { print "  No episodes found.\n"; return; }

    my $title    = $feeds->{$slug}{meta}{title};
    my $unplayed = $args{unplayed} ? 1 : 0;
    my $action   = $unplayed ? 'unplayed' : 'played';

    if ($args{episode}) {
        my $idx = int($args{episode}) - 1;
        if ($idx < 0 || $idx >= scalar @$episodes) {
            print "[ERROR] Episode number must be between 1 and " . scalar(@$episodes) . ".\n";
            exit 1;
        }
        my $ep = $episodes->[$idx];
        if ($ep->{played} && !$unplayed) {
            print "  Already marked played: " . substr($ep->{title}, 0, 60) . "\n";
            return;
        }
        $ep->{played} = !$unplayed ? 1 : 0;
        print "  ✔ Marked $action: " . substr($ep->{title}, 0, 60) . "\n";
    } else {
        my $cnt = scalar @$episodes;
        unless ($args{yes}) {
            print "Mark all $cnt episodes of '$title' as $action? [y/N] ";
            my $confirm = lc(<STDIN> // '');
            chomp $confirm;
            if ($confirm ne 'y') { print "Aborted.\n"; return; }
        }
        for my $ep (@$episodes) {
            $ep->{played} = !$unplayed ? 1 : 0;
        }
        print "  ✔ Marked all $cnt episode(s) as $action.\n";
    }

    save_feeds($feeds);
}

sub cmd_download {
    my (%args) = @_;
    my $feeds = load_feeds();

    my %targets;
    if ($args{slug}) {
        unless (exists $feeds->{$args{slug}}) {
            print "[ERROR] No feed with slug '$args{slug}'.\n";
            exit 1;
        }
        %targets = ($args{slug} => $feeds->{$args{slug}});
    } else {
        %targets = %$feeds;
    }

    unless (%targets) {
        print "No feeds. Add one with:  podcatcher add <url>\n";
        return;
    }

    my ($total_ok, $total_fail) = (0, 0);

    for my $slug (keys %targets) {
        my $feed     = $feeds->{$slug};
        my $episodes = $feed->{episodes} // [];
        next unless @$episodes;

        my @queue;
        if ($args{episode}) {
            unless ($args{slug}) {
                print "[ERROR] --episode requires a slug argument.\n";
                exit 1;
            }
            my $idx = int($args{episode}) - 1;
            if ($idx < 0 || $idx >= scalar @$episodes) {
                print "[ERROR] Episode number must be between 1 and " . scalar(@$episodes) . ".\n";
                exit 1;
            }
            @queue = ($episodes->[$idx]);
        } elsif ($args{all}) {
            @queue = grep { !$_->{local_path} || !-f $_->{local_path} } @$episodes;
        } else {
            @queue = grep { !$_->{local_path} } @$episodes;
        }

        unless (@queue) {
            print "[$slug] Nothing to download.\n";
            next;
        }

        my $cnt = scalar @queue;
        print "\n[$slug] $feed->{meta}{title}  —  $cnt episode(s) to download\n";

        for my $ep (@queue) {
            my $local = download_episode($ep, $slug);
            if ($local) {
                $ep->{local_path} = $local;
                for my $main_ep (@$episodes) {
                    if ($main_ep->{guid} eq $ep->{guid}) {
                        $main_ep->{local_path} = $local;
                        last;
                    }
                }
                print "    ✔ Saved: $local\n";
                $total_ok++;
            } else {
                $total_fail++;
            }
        }
    }

    save_feeds($feeds);
    print "\nDownload complete: $total_ok succeeded, $total_fail failed.\n\n";
}

sub cmd_help {
    my (%args) = @_;
    my $topic = $args{topic};
    my $W = 60;

    my %HELP = (
        'add' => <<'HELP',
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

HELP
        'list' => <<'HELP',
  list

  Print a summary table of every subscribed feed showing its slug, total
  episode count, date last refreshed, and title.

  Examples:
    podcatcher list

HELP
        'status' => <<'HELP',
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

HELP
        'update' => <<'HELP',
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

HELP
        'download' => <<'HELP',
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

HELP
        'mark-played' => <<'HELP',
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

HELP
        'remove' => <<'HELP',
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

HELP
        'search' => <<'HELP',
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

HELP
    );

    if ($topic) {
        my $key = lc $topic;
        $key =~ s/_/-/g;
        unless (exists $HELP{$key}) {
            my $available = join(', ', sort keys %HELP);
            print "[ERROR] Unknown command '$topic'. Available: $available\n";
            exit 1;
        }
        print "\n" . '═' x $W . "\n";
        print "  podcatcher $key\n";
        print '═' x $W . "\n";
        print $HELP{$key};
        return;
    }

    print <<EOT;

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

EOT
}

# ─── Argument Parsing ──────────────────────────────────────────────────────────

sub parse_args {
    my @argv = @_;

    unless (@argv) {
        show_usage();
        exit 1;
    }

    my $command = shift @argv;
    my %args = (command => $command);

    if ($command eq 'add') {
        $args{url}  = undef;
        $args{name} = undef;
        my $i = 0;
        while ($i < @argv) {
            if ($argv[$i] eq '--name' && $i + 1 < @argv) {
                $args{name} = $argv[++$i];
            } elsif (!defined $args{url}) {
                $args{url} = $argv[$i];
            }
            $i++;
        }
        unless ($args{url}) { print "[ERROR] 'add' requires a URL.\n"; exit 1; }

    } elsif ($command eq 'list') {
        # no args

    } elsif ($command eq 'status') {
        $args{slug}  = undef;
        $args{count} = 10;
        my $i = 0;
        while ($i < @argv) {
            if ($argv[$i] eq '--count' && $i + 1 < @argv) {
                $args{count} = int($argv[++$i]);
            } elsif (!defined $args{slug}) {
                $args{slug} = $argv[$i];
            }
            $i++;
        }
        unless ($args{slug}) { print "[ERROR] 'status' requires a slug.\n"; exit 1; }

    } elsif ($command eq 'update') {
        $args{slug}     = undef;
        $args{download} = 0;
        my $i = 0;
        while ($i < @argv) {
            if ($argv[$i] eq '--slug' && $i + 1 < @argv) {
                $args{slug} = $argv[++$i];
            } elsif ($argv[$i] eq '--download') {
                $args{download} = 1;
            }
            $i++;
        }

    } elsif ($command eq 'remove') {
        $args{slug} = undef;
        $args{yes}  = 0;
        my $i = 0;
        while ($i < @argv) {
            if ($argv[$i] eq '-y' || $argv[$i] eq '--yes') {
                $args{yes} = 1;
            } elsif (!defined $args{slug}) {
                $args{slug} = $argv[$i];
            }
            $i++;
        }
        unless ($args{slug}) { print "[ERROR] 'remove' requires a slug.\n"; exit 1; }

    } elsif ($command eq 'search') {
        $args{query} = undef;
        $args{limit} = 10;
        my $i = 0;
        while ($i < @argv) {
            if ($argv[$i] eq '--limit' && $i + 1 < @argv) {
                $args{limit} = int($argv[++$i]);
            } elsif (!defined $args{query}) {
                $args{query} = $argv[$i];
            }
            $i++;
        }
        unless ($args{query}) { print "[ERROR] 'search' requires a query.\n"; exit 1; }

    } elsif ($command eq 'mark-played') {
        $args{slug}     = undef;
        $args{episode}  = undef;
        $args{unplayed} = 0;
        $args{yes}      = 0;
        my $i = 0;
        while ($i < @argv) {
            if ($argv[$i] eq '--episode' && $i + 1 < @argv) {
                $args{episode} = int($argv[++$i]);
            } elsif ($argv[$i] eq '--unplayed') {
                $args{unplayed} = 1;
            } elsif ($argv[$i] eq '-y' || $argv[$i] eq '--yes') {
                $args{yes} = 1;
            } elsif (!defined $args{slug}) {
                $args{slug} = $argv[$i];
            }
            $i++;
        }
        unless ($args{slug}) { print "[ERROR] 'mark-played' requires a slug.\n"; exit 1; }

    } elsif ($command eq 'download') {
        $args{slug}    = undef;
        $args{episode} = undef;
        $args{all}     = 0;
        my $i = 0;
        while ($i < @argv) {
            if ($argv[$i] eq '--episode' && $i + 1 < @argv) {
                $args{episode} = int($argv[++$i]);
            } elsif ($argv[$i] eq '--all') {
                $args{all} = 1;
            } elsif (substr($argv[$i], 0, 1) ne '-' && !defined $args{slug}) {
                $args{slug} = $argv[$i];
            }
            $i++;
        }

    } elsif ($command eq 'help') {
        $args{topic} = $argv[0];

    } else {
        print "[ERROR] Unknown command '$command'.\n";
        show_usage();
        exit 1;
    }

    return %args;
}

sub show_usage {
    print <<'EOT';
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
EOT
}

# ─── Entry Point ───────────────────────────────────────────────────────────────

sub main {
    ensure_dirs();
    my %args = parse_args(@ARGV);

    my %dispatch = (
        'add'         => \&cmd_add,
        'list'        => \&cmd_list,
        'status'      => \&cmd_status,
        'update'      => \&cmd_update,
        'remove'      => \&cmd_remove,
        'search'      => \&cmd_search,
        'mark-played' => \&cmd_mark_played,
        'download'    => \&cmd_download,
        'help'        => \&cmd_help,
    );

    my $fn = $dispatch{$args{command}};
    unless ($fn) {
        print "[ERROR] Unknown command '$args{command}'.\n";
        exit 1;
    }

    $fn->(%args);
}

main();
