# migrate-trello-to-github

## What is this?

This is a perl script to migrate a [Trello](https://trello.com/) board to
a [Github](https://github.com/) issue tracker.

GitHub does not offer a way to fully manage their "Project" boards through
their API, so this _only_ builds issues out of Trello cards.

This script expects that we're starting with a new repository. It can probably
work to migrate bugs into an existing repo, but it will want to overwrite
your README.md and add an "attachments" directory to the git repo. Do so at
your own risk!

Most data will migrate from Trello: comments, checklists, attachments, covers,
etc.

This has only been tested on Linux, but probably works anywhere Perl and a
few extra Perl modules work.


## Setup

This script does not need to be installed system-wide. However, it needs some
common Perl modules installed:

- Net::GitHub
- LWP::Simple
- URI::Encode
- JSON

Ubuntu/Debian users can install these with:

```bash
sudo apt-get install libwww-perl libjson-pp-perl libnet-github-perl liburi-encode-perl
```

Other distros likely have similar packages, check your package manager. If all
else fails, you can try forcing the issue with CPAN:

```bash
sudo perl -MCPAN -e 'install Net::GitHub;'
```

(etc.)


If the script starts at all, you have all the modules you need, but you should
gather some other important things.

You'll need a GitHub Personal Access Token. These are free and created through
the GitHub web interface.

Go here: https://github.com/settings/tokens/new

I checked all the boxes, which basically says "something with this magic
password can do anything with my account" but in practice you can trim most of
this out. Realistically, you might only need the "repo" checkboxes.

Click "Generate token" and copy the string they show you somewhere. It won't be
shown again. This string will allow the script to interact with GitHub on your
behalf.

You also need some pieces from Trello.

First, you need an export of the board to migrate. In the web interface, when
you load a board, the "..." menu in the top right has a
"Print, export, and share" link. Click that, and then the "Export as JSON"
link. Save that to disk. We'll call that saved file board-export.json for the
example below, but the filename doesn't matter.

If the board is private, you'll want to make it public while this script
downloads its attachments. As soon as that is complete you can make the board
private again. The script will tell you when it is done downloading. If the
script has to run multiple times, it'll will still only have to do the
attachment download once, and will save the data between runs.

It is optional, but you should also get an access token from Trello. You can
use this script without one, but we can't migrate the full history for every
card without it. A trello export only lists the latest 1000 action on a given
board, but even a moderately-used board will have thousands, or tens of
thousands, of actions...every time a card is moved, commented on, etc,
generates a new action. Without the full action data, you'll still have the
most important card info (description, attachments, checklists) but older
pieces will be lost. If you have an access token for Trello, though, the
script can download the complete information and no history/comments will be
lost.

To get an access token from Trello, got to https://trello.com/power-ups/admin/new
and fill in the form. The name can be "trello-to-github" or whatever, "Iframe
connector URL" can be any valid URL; we don't use it. Click "Create". On the
next page, click "API key" and then "Generate a new API key." On the next
page, you'll want to copy the "API key" and "Secret" strings.


## Run the script

The simplest form is this:

```bash
./migrate-trello-to-github.pl board-export.json MyGithubUsername NewGithubRepoName GITHUB_API_TOKEN state-directory
```

Where `GITHUB_API_TOKEN` is the GitHub API token you generated,
state-directory is a temporary scratch directory that the script will create.

This will make a new GitHub repo at https://github.com/MyGithubUsername/NewGithubRepoName
and import all the data from board-export.json. Some comments and other
activity from the Trello cards might be missing because we didn't provide a
Trello API key in this example.


Other options you can add to the script:

- `--usermap=a:b`

  Tell the script that when you see Trello username `a`, it maps to GitHub
  username `b`. This is not required (we'll just use their full name from
  Trello otherwise), but it might be useful. Specify this option once for
  each username you want to map.

- `--destroy-existing-repo`

  This will **WITHOUT WARNING** destroy the existing repo and build it from
  scratch. This cannot be undone! Any changes made to this repo outside of
  this script will be gone permanently.

- `--trello-api-key=STRING --trello-api-token=STRING`

  Specify Trello API keys. These are the "API key" and "Secret" fields we
  mentioned before.

-- `--no-rate-limit`

  This script sleeps a little from time to time to try to avoid triggering
  GitHub's rate limiting. If you have permission from GitHub to go
  full-speed, or you don't have much data to upload, this will remove the
  sleeps. If we hit a rate limit, the script can pick up where it left off
  later, though, so you might want this if you plan to babysit the script,
  too.

-- `--skip-card-activity`

  Just upload the description, cover, attachments, and checklists for all
  cards. Comments and other activity will be ignored. Cleaner, if the
  history isn't useful to you.


## Cleanup

Done with this script?

If it didn't work out, you can delete the GitHub repo through their web
interface.

You can delete the state-directory now, if you want.

You can delete the GitHub API key now at https://github.com/settings/tokens

If you made a Trello API key, you can delete it now at
https://trello.com/power-ups/admin



## Questions? Problems?

Ask me, or file a bug. Pull requests are always welcome!

