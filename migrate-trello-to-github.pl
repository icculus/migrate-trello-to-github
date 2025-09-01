#!/usr/bin/perl -w

# sudo apt-get install libwww-perl libjson-pp-perl libnet-github-perl liburi-encode-perl

use strict;
use warnings;
use Net::GitHub;
use Net::GitHub::V3;
use Net::GitHub::V4;
use JSON qw( decode_json );
use Data::Dumper;
use LWP::Simple;
use File::Copy;
use Time::Piece;
use URI::Encode qw( uri_encode );

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

# Globals...
my $trello = undef;  # the decoded JSON of the board export.
my $github = undef;  # Access handle for talking to GitHub (v3 API).
my $github4 = undef;  # Access handle for talking to GitHub (v4 API).
my $github_repo = undef;  # "username/reponame"
my $github_user_node_id = undef;

my $restart_state_actions_downloaded = 0;
my $restart_state_actions_oldest = undef;
my $restart_state_attachment_download = 0;
my $restart_state_created_repo = 0;
my $restart_state_card_upload = 0;
my $restart_state_card_action = 0;
my $restart_state_card_current_issue = 0;
my $no_rate_limit = 0;
my $skip_card_activity = 0;
my $migration_finished = -1;

my %list_map = ();        # map hash strings to actual lists.
my %checklist_map = ();   # map hash strings to actual checklists.
my %label_map = ();   # map hash strings to actual labels.
my %member_map = ();   # map hash strings to actual members.

# Command line stuff...
my $trello_json_path = undef;
my $github_username = undef;
my $github_reponame = undef;
my $github_repo_title = undef;
my $github_token = undef;
my $trello_api_key = undef;
my $trello_api_token = undef;
my $restart_state_path = undef;
my $destroy_existing_repo = 0;
my %usermap = ();

sub usage {
    print STDERR "USAGE: $0 <trello_export_json> <github_username> <github_reponame> <github_repo_title> <github_api_token> <workdir> [--usermap=a:b] [--destroy-existing-repo] [--trello-api-key=STRING] [--trello-api-token=STRING] [--no-rate-limit] [--skip-card-activity]\n";
    exit(1);
}

sub parse_commandline {
    foreach (@ARGV) {
        if (/\A\-\-usermap\=(.*)\Z/) {
            my @mapping = split(/:/, $1);
            usage() if (scalar(@mapping) != 2);
            $usermap{$mapping[0]} = $mapping[1];
            next;
        }
        $trello_api_key = $1, next if (/\A\-\-trello\-api\-key\=(.*)\Z/);
        $trello_api_token = $1, next if (/\A\-\-trello\-api\-token\=(.*)\Z/);
        $destroy_existing_repo = 1, next if $_ eq '--destroy-existing-repo';
        $no_rate_limit = 1, next if $_ eq '--no-rate-limit';
        $trello_json_path = $_, next if not defined $trello_json_path;
        $github_username = $_, next if not defined $github_username;
        $github_reponame = $_, next if not defined $github_reponame;
        $github_repo_title = $_, next if not defined $github_repo_title;
        $github_token = $_, next if not defined $github_token;
        $restart_state_path = $_, next if not defined $restart_state_path;

        usage();
    }

    usage() if not defined $trello_json_path;
    usage() if not defined $github_username;
    usage() if not defined $github_reponame;
    usage() if not defined $github_repo_title;
    usage() if not defined $github_token;
    usage() if not defined $restart_state_path;

    $github_repo = "$github_username/$github_reponame";

    print("Trello export filename: $trello_json_path\n");
    print("GitHub repo: https://github.com/$github_repo\n");
    print("GitHub repo title: $github_repo_title\n");
    print("GitHub API token: $github_token\n");
    print("Trello API key: " . ((defined $trello_api_key) ? $trello_api_key : '[none]') . "\n");
    print("Trello API token: " . ((defined $trello_api_token) ? $trello_api_token : '[none]') . "\n");
    print("Work dir: $restart_state_path\n");


    if ((not $skip_card_activity) and ((not defined $trello_api_key) or (not defined $trello_api_token))) {
        print STDERR "\n\n\nNo Trello API key/token provided. We will probably lose card activity!\n\n\n\n";
    }

    foreach (sort keys %usermap) {
        my $k = $_;
        my $v = $usermap{$k};
        print("USERMAP '$k' -> '$v'\n");
    }
}

sub load_restart_state {
    if (open(STATEIN, '<', "$restart_state_path/migrate-state.txt")) {
        $restart_state_actions_downloaded = int(<STATEIN>);
        $restart_state_actions_oldest = <STATEIN>; chomp($restart_state_actions_oldest); $restart_state_actions_oldest = undef if $restart_state_actions_oldest eq '';
        $restart_state_attachment_download = int(<STATEIN>);
        $restart_state_created_repo = int(<STATEIN>);
        $restart_state_card_upload = int(<STATEIN>);
        $restart_state_card_action = int(<STATEIN>);
        $restart_state_card_current_issue = int(<STATEIN>);
        close(STATEIN);
    }
    $migration_finished = 0;  # now safe to save this out on exit.
}

sub save_restart_state {
    return if not defined $restart_state_path;
    open(STATEOUT, '>', "$restart_state_path/migrate-state.txt") or die("Failed to open '$restart_state_path': $!\n");
    print STATEOUT "$restart_state_actions_downloaded\n";
    print STATEOUT defined $restart_state_actions_oldest ? "$restart_state_actions_oldest\n" : "\n";
    print STATEOUT "$restart_state_attachment_download\n";
    print STATEOUT "$restart_state_created_repo\n";
    print STATEOUT "$restart_state_card_upload\n";
    print STATEOUT "$restart_state_card_action\n";
    print STATEOUT "$restart_state_card_current_issue\n";
    close(STATEOUT) or die("Failed to write '$restart_state_path': $!\n");
}

sub rate_limit_sleep {
    my $secs = shift;
    return if $no_rate_limit;
    sleep($secs);
}

sub load_trello_json {
    open(JSONIN, '<', $trello_json_path) or die("Failed to open '$trello_json_path': %!\n");
    # Don't set this, decode_json expects binary.
    #binmode JSONIN, ':utf8';
    my $str = '';
    while (<JSONIN>) {
        $str .= $_;
    }
    close(JSONIN);
    $trello = decode_json($str) or die("Failed to decode json: $!\n");
    #print Dumper($trello);

    my $trello_checklists = $trello->{'checklists'};
    foreach (@$trello_checklists) {
        my $checklist = $_;
        $checklist_map{$$checklist{'id'}} = $checklist;
    }

    my $trello_lists = $trello->{'lists'};
    foreach (@$trello_lists) {
        my $list = $_;
        $list_map{$$list{'id'}} = $list;
    }

    my $trello_labels = $trello->{'labels'};
    foreach (@$trello_labels) {
        my $label = $_;
        $label_map{$$label{'id'}} = $label;
    }

    my $trello_members = $trello->{'members'};
    foreach (@$trello_members) {
        my $member = $_;
        $member_map{$$member{'id'}} = $member;
    }
}

sub check_usermap {
    # This isn't perfect, it might be we see a comment later by someone that
    # isn't a member _anymore_, but I don't want to parse out every possible
    # place there could be a username mentioned right now.
    my $members = $trello->{'members'};
    my $failed = 0;
    foreach (@$members) {
        my $member = $_;
        my $membername = $$member{'username'};
        if (not defined $usermap{$membername}) {
            print STDERR "\n\n\nNo usermap in place for Trello username '$membername'!\n\n\n\n";
            $failed = 1;
        }
    }
    #die("Please add the appropriate --usermap=a:b entries to the command line.\n") if $failed;
}

sub init_label_colors {
    my %label_colormap = (
        "black" => "596773",
        "black_dark" => "454f59",
        "black_light" => "8c9bab",
        "blue" => "0055cc",
        "blue_dark" => "09326c",
        "blue_light" => "579dff",
        "green" => "216e4e",
        "green_dark" => "164b35",
        "green_light" => "4bce97",
        "lime" => "4c6b1f",
        "lime_dark" => "37471f",
        "lime_light" => "94c748",
        "orange" => "a54800",
        "orange_dark" => "702e00",
        "orange_light" => "fea362",
        "pink" => "943d73",
        "pink_dark" => "50253f",
        "pink_light" => "e774bb",
        "purple" => "5e4db2",
        "purple_dark" => "352c63",
        "purple_light" => "9f8fef",
        "red" => "ae2e24",
        "red_dark" => "5d1f1a",
        "red_light" => "f87168",
        "sky" => "206a83",
        "sky_dark" => "164555",
        "sky_light" => "6cc3e0",
        "yellow" => "7f5f01",
        "yellow_dark" => "533f04",
        "yellow_light" => "e2b203"
    );

    my $trello_labels = $trello->{'labels'};
    foreach (@$trello_labels) {
        my $label = $_;
        my $colorname = $$label{'color'};
        my $labelname = $$label{'name'};
        if ((not defined $labelname) or ($labelname eq '')) {
            $labelname = ucfirst($colorname);
            $$label{'name'} = $labelname;
        }
        my $htmlcolor = $label_colormap{$colorname};
        die("Unexpected label color '$colorname', please update this script!\n") if not defined $htmlcolor;
        $$label{'htmlcolor'} = $htmlcolor;
        print("LABEL '$labelname' -> $colorname -> #$htmlcolor\n");
    }
}

sub auth_to_github {
    $github = Net::GitHub::V3->new(version => 3, access_token => $github_token, RaiseError => 1) or die("Failed to connect to GitHub v3: $!\n");
    #$github4 = Net::GitHub::V4->new(version => 4, access_token => $github_token, RaiseError => 1) or die("Failed to connect to GitHub v4: $!\n");
    my $u = $github->user->show();

    $github_user_node_id = $u->{'node_id'};
    print("GitHub user node_id for '$github_username' is '$github_user_node_id'\n");
}

sub prep_repo {
    my $clonepath = "$restart_state_path/repo";

    if ($destroy_existing_repo) {
        print("Destroying existing repo...\n");
        $github->repos->RaiseError(0);
        $github->repos->delete( $github_username, $github_reponame );
        $github->repos->RaiseError(1);
        $restart_state_created_repo = 0;
        $restart_state_card_upload = 0;
        $restart_state_card_action = 0;
        $restart_state_card_current_issue = 0;
        system("rm -rf '$clonepath'");
    }

    $github->set_default_user_repo($github_username, $github_reponame);

    if (!$restart_state_created_repo) {
        print("Have to create a new repo...\n");
        my $repo = $github->repos->create( {
            "name" => $github_reponame,
            "description" => $github_repo_title,
            "private" => 1,
            "has_issues" => 1,
            "has_projects" => 0,
            "has_wiki" => 0,
            "has_discussions" => 0,
            "has_downloads" => 0,
        } );

        #print Dumper($repo);
        my $github_repo_node_id = $repo->{'node_id'};

        my @oldlabels = $github->issue->labels;
        foreach (@oldlabels) {
            print("Deleting old GitHub label " . $_->{'name'} . " ...\n");
            $github->issue->delete_label($_->{'name'});
        }

        print("Building new Trello labels...\n");
        my $trello_labels = $trello->{'labels'};
        foreach (@$trello_labels) {
            my $label = $_;
            my $labelname = $$label{'name'};
            my $htmlcolor = $$label{'htmlcolor'};
            $github->issue->create_label({
                "name" => $labelname,
                "color" => $htmlcolor
            });
        }

        # we can't really mess with project boards in a meaningful way here,
        # so add a label for each Trello card list instead.
        my $trello_lists = $trello->{'lists'};
        foreach (@$trello_lists) {
            my $list = $_;
            my $labelname = $$list{'name'};
            $labelname = substr($labelname, 0, 50); # no more than 50 characters long!
            $github->issue->create_label({
                "name" => $labelname,
                "color" => '000000'    # make each label black so we know it's a list tag.
            });
        }

if (0) {  # !!! FIXME: you can't really do much with project boards through the API, only the web UI.  :(
        print("Building project board...\n");
        my $github_project = $github4->query(qq{
                mutation{
                    createProjectV2(
                        input: {
                            ownerId: "$github_user_node_id",
                            repositoryId: "$github_repo_node_id",
                            title: "$github_repo_title"
                        }
                    ){
                        projectV2 {
                            id
                        }
                    }
                }
            });

        print Dumper($github_project);
        my $github_project_node_id = $github_project->{'node_id'};
}

        $restart_state_created_repo = 1;
    }

    if ( -d $clonepath ) {
        print("Updating clone of repository...\n");
        die("Update failed!\n") if (system("cd '$clonepath' && git pull --rebase") != 0);
    } else {
        print("Cloning repository...\n");
        my $url = "https://$github_username:$github_token\@github.com/$github_username/$github_reponame.git";
        die("Clone of '$url' failed!\n") if (system("git clone '$url' '$clonepath'") != 0);
    }


    print("Copying files to the repo clone...\n");
    my $cloneattachments = "$clonepath/attachments";
    if ( ! -d $cloneattachments ) {
        mkdir($cloneattachments) or die("Couldn't make '$cloneattachments' directory: $!\n");
    }
    my $trello_cards = $trello->{'cards'};
    foreach (@$trello_cards) {
        my $card = $_;
        my $trello_attachments = $$card{'attachments'};
        foreach (@$trello_attachments) {
            my $attachment = $_;
            my $attachment_id = $$attachment{'id'};
            my $attachment_fname = $$attachment{'fileName'};
            my $srcpath = "$restart_state_path/attachments/$attachment_id";
            my $dstparentpath = "$cloneattachments/$attachment_id";
            my $dstpath = "$dstparentpath/$attachment_fname";
            if ( ! -d $dstparentpath ) {
                mkdir($dstparentpath) or die("Couldn't make '$dstparentpath' directory: $!\n");
            }
            unlink($dstpath) if ( -f $dstpath );
            copy($srcpath, $dstpath) or die("Failed to copy file '$srcpath' -> '$dstpath': $!\n");
        }
    }

    my $readmepath = "$clonepath/README.md";
    if ( ! -f $readmepath ) {
        open(my $fh, '>', $readmepath) or die("Couldn't create '$readmepath': $!\n");
        my $trello_url = $trello->{'url'};
        print $fh "# $github_repo_title\n\nThis is a migration of [a Trello board]($trello_url) to GitHub.\n\n";
        close($fh) or die("Couldn't write '$readmepath': $!\n");
    }

    if (int(`cd '$clonepath' && git status -s |wc -l`) != 0) {
        print("Pushing to GitHub...\n");
        die("Upload to git failed!\n") if (system("cd '$clonepath' && git add -A . && git commit -m 'Added Trello resources.' && git push") != 0);
    }

    print("Git repository is prepared!\n");
    print("github repo is https://github.com/$github_username/$github_reponame\n");
}

sub date_from_iso8601 {
    my $iso8601 = shift;
    $iso8601 =~ s/\.\d+Z$//;  # dump extra ISO8601 cruft from end so strptime can parse it.
    my $t = Time::Piece->strptime($iso8601, "%Y-%m-%dT%H:%M:%S");
    return $t->month . ' ' . $t->mday . ', ' . $t->year . ', ' . ($t->hour - (($t->hour > 12) ? 12 : 0)) . ':' . $t->min . ' ' . (($t->hour > 12) ? 'PM' : 'AM') . ' UTC';
}

sub attachment_url {
    my $att_id = shift;
    my $att_fname = shift;
    $att_fname = uri_encode($att_fname);
    return "https://github.com/$github_username/$github_reponame/raw/refs/heads/main/attachments/$att_id/$att_fname";
}

sub find_attachment {
    my $card = shift;
    my $att_id = shift;
    my $attachments = $$card{'attachments'};
    foreach (@$attachments) {
        my $attachment = $_;
        if ($$attachment{'id'} eq $att_id) {
            return $attachment;
        }
    }
    return undef;
}

sub upload_cards {
    my $trello_cards = $trello->{'cards'};
    my $card_index = 0;
    my $total_cards = scalar(@$trello_cards);
    @$trello_cards = sort { $$a{'idShort'} <=> $$b{'idShort'} } @$trello_cards;
    foreach (@$trello_cards) {
        next if ($card_index++ < $restart_state_card_upload);  # skip ones we already did.
        my $card = $_;
        my $card_id = $$card{'id'};
#next if $card_id ne '5283049e1bedb9473d00440a';
        my $name = $$card{'name'};
        my $desc = $$card{'desc'};
        my $cardurl = $$card{'url'};
        my $cover = $$card{'cover'};
        my $issue = undef;

        my @labels = ();
        my $card_labels = $card->{'labels'};
        foreach (@$card_labels) {
            my $label = $_;
            push @labels, $$label{'name'};
        }

        my $listlabel = $list_map{$$card{'idList'}}->{'name'};
        $listlabel = substr($listlabel, 0, 50); # no more than 50 characters long!
        push @labels, $listlabel;

        if ($restart_state_card_current_issue) {
            print("Continuing on card $card_index of $total_cards: '$name'\n");
            $issue = $github->issue->issue($restart_state_card_current_issue);
        } else {
            print("Creating card $card_index of $total_cards: '$name'\n");

            my $body = "# $name\n\n";

            if (defined $cover->{'idAttachment'}) {
                my $att_id = $cover->{'idAttachment'};
                my $attachment = find_attachment($card, $att_id);
                if (defined $attachment) {
                    my $att_fname = $$attachment{'fileName'};
                    my $att_name = $$attachment{'name'};
                    my $url = attachment_url($att_id, $att_fname);
                    $body .= "![$att_name]($url)\n\n";
                }
            }

            $body .= "###### (This issue was originally from [this Trello card]($cardurl).)\n\n";
            $body .= "$desc\n\n";

            my $attachments = $card->{'attachments'};
            if (scalar(@$attachments) > 0) {
                $body .= "## Attachments\n\n";
                foreach (@$attachments) {
                    my $attachment = $_;
                    my $att_id = $$attachment{'id'};
                    my $att_fname = $$attachment{'fileName'};
                    my $att_name = $$attachment{'name'};
                    my $url = attachment_url($att_id, $att_fname);
                    my $date = date_from_iso8601($$attachment{'date'});
                    $body .= "- [**$att_name**]($url)\n";
                    $body .= "  Added $date\n";
                }
                $body .= "\n";
            }

            my $idchecklists = $card->{'idChecklists'};
            foreach (@$idchecklists) {
                my $checklist = $checklist_map{$_};
                my $checklistname=  $$checklist{'name'};
                my $checkitems = $$checklist{'checkItems'};
                $body .= "## $checklistname\n\n";
                foreach (@$checkitems) {
                    my $checkitem = $_;
                    my $checkitemname = $$checkitem{'name'};
                    my $X = ($$checkitem{'state'} eq 'complete') ? 'X' : ' ';
                    $body .= " - [$X] $checkitemname\n";
                }
                $body .= "\n";
            }

            $issue = $github->issue->create_issue( {
                "title" => $name,
                "body" => $body,
            } );

            # block a few seconds, this tends to help with GitHub rate limits.
            rate_limit_sleep(5);
        }

        my $issue_number = int($$issue{'number'});

        $restart_state_card_current_issue = $issue_number;
        print("  - Original Trello card is $cardurl\n");
        print("  - GitHub issue is https://github.com/$github_username/$github_reponame/issues/$issue_number\n");

        if (!$skip_card_activity) {
            my $trello_actions = $trello->{'actions'};
            my %actions = ();
            my %seen_actions = ();
            foreach (@$trello_actions) {
                my $action = $_;
                next if (not defined $action->{'data'}->{'card'}) or ($action->{'data'}->{'card'}->{'id'} ne $card_id);
                next if (defined $seen_actions{$action->{'id'}});  # we might have gotten duplicates in the full actions set.
                $seen_actions{$action->{'id'}} = 1;
                my $date = $$action{'date'};
                my $extra = 0.0;
                if ($date =~ s/\.(\d+)Z$//) {  # dump extra ISO8601 cruft from end so strptime can parse it.
                    $extra = 0.0 + "0.$1";
                }
                my $t = Time::Piece->strptime($date, "%Y-%m-%dT%H:%M:%S");
                my $epoch = $t->epoch + $extra;
                while (defined $actions{$epoch}) { $epoch += 0.00001; }
                $actions{$epoch} = $action;
            }

            my $comment_post_intensity = 0;
            my $comment_post_intensity_threshold = 10;
            my $action_index = 0;
            foreach (sort { $a <=> $b } keys %actions) {
                next if ($action_index++ < $restart_state_card_action);  # skip ones we already did.
                my $action = $actions{$_};
                my $origdate = date_from_iso8601($$action{'date'});
                my $date = $origdate;
                my $fullname = $$action{'memberCreator'}->{"fullName"};
                my $username = $$action{'memberCreator'}->{"username"};
                my $ghusername = $usermap{$username};
                my $namestr = defined $ghusername ? "$fullname (\@$ghusername)" : $fullname;
                my $action_id = $$action{'id'};
                my $type = $$action{'type'};
                my $data = $$action{'data'};
                my $comment = undef;
                my $cardurl = undef;

                if (defined $data->{'card'}->{'shortLink'}) {
                    $cardurl = "https://trello.com/c/" . $data->{'card'}->{'shortLink'} . "#action-$action_id";
                    $date = "[$origdate]($cardurl)";
                }

                if ($type eq 'addAttachmentToCard') {
                    my $att_id = $data->{'attachment'}->{'id'};
                    my $attachment = find_attachment($card, $att_id);
                    if (defined $attachment) {
                        my $att_name = $$attachment{'name'};
                        my $att_fname = $$attachment{'fileName'};
                        my $url = attachment_url($att_id, $att_fname);
                        $comment = "$namestr attached [$att_name]($url) to this card\n\n$date\n";
                    }
                } elsif ($type eq 'addChecklistToCard') {
                    my $checklist = $$data{'checklist'};
                    my $checklistname = $$checklist{'name'};
                    $comment = "$namestr added $checklistname to this card\n\n$date\n";
                } elsif ($type eq 'updateCheckItemStateOnCard') {
                    my $verbed = ($data->{'checkItem'}->{'state'} eq 'complete') ? 'completed' : 'reverted';
                    my $checkitemname = $data->{'checkItem'}->{'name'};
                    $comment = "$namestr $verbed $checkitemname on this card\n\n$date\n";
                } elsif ($type eq 'commentCard') {
                    my $text = $$data{'text'};
                    $cardurl = "https://trello.com/c/" . $data->{'card'}->{'shortLink'} . "#comment-$action_id";
                    $date = "[$origdate]($cardurl)";
                    $comment = "$namestr $date\n\n$text\n";
                } elsif ($type eq 'createCard') {
                    my $listname = $data->{'list'}->{'name'};
                    $comment = "$namestr added this card to $listname\n\n$date\n";
                } elsif ($type eq 'emailCard') {
                    my $listname = $data->{'list'}->{'name'};
                    $comment = "$namestr emailed this card to $listname\n\n$date\n";
                } elsif ($type eq 'updateCard') {
                    my $listname = $data->{'list'}->{'name'};
                    my $old = $$data{'old'};
                    if (exists $$old{'idList'}) {
                        my $oldlistname = $data->{'listBefore'}->{'name'};
                        my $newlistname = $data->{'listAfter'}->{'name'};
                        $comment = "$namestr moved this card from $oldlistname to $newlistname\n\n$date\n";
                    } elsif (exists $$old{'closed'}) {
                        my $verbed = ($data->{'card'}->{'closed'}) ? 'archived' : 'unarchived';
                        $comment = "$namestr $verbed this card\n\n$date\n";
                    } elsif (exists $$old{'pos'}) {
                        # Ignore this one, I think it's the card moving to a different position in the same list.
                    } elsif (exists $$old{'idLabels'}) {
                        # build hashes of old vs new arrays, figure out what changed.
                        my $oldidlabels = $$old{'idLabels'};
                        my %oldlabels = ();
                        foreach(@$oldidlabels) {
                            $oldlabels{$label_map{$$_{'id'}}} = $_;
                        }
                        my $newidlabels = $data->{'card'}->{'idLabels'};
                        my %newlabels = ();
                        foreach(@$newidlabels) {
                            $newlabels{$label_map{$$_{'id'}}} = $_;
                        }

                        my @added = ();
                        my @removed = ();
                        foreach (keys %oldlabels) {
                            push @removed, $label_map{$_}->{'name'} if (not defined $newlabels{$_});
                        }
                        foreach (keys %newlabels) {
                            push @added, $label_map{$_}->{'name'} if (not defined $oldlabels{$_});
                        }

                        if (scalar(@added) > 1) {
                            $comment = "$namestr added labels:";
                            my $sep = ' ';
                            foreach (@added) {
                                $comment .= "$sep$_";
                                $sep = ', '
                            }
                            $comment .= "\n\n$date\n";
                        } elsif (scalar(@added) == 1) {
                            $comment = "$namestr added the label " . $added[0] . "\n\n";
                        }

                        if (scalar(@removed) > 1) {
                            $comment = "$namestr removed labels:";
                            my $sep = ' ';
                            foreach (@removed) {
                                $comment .= "$sep$_";
                                $sep = ', '
                            }
                            $comment .= "\n\n";
                        } elsif (scalar(@removed) == 1) {
                            $comment = "$namestr removed the label " . $added[0] . "\n\n$date\n";
                        }
                    } elsif (exists $$old{'desc'}) {
                        # Ignore this one, Trello doesn't report this either, and it could be a massive edit.
                    } elsif (exists $$old{'name'}) {
                        my $newname = $data->{'card'}->{'name'};
                        my $oldname = $$old{'name'};
                        $comment = "$namestr renamed this card from $oldname to $newname\n\n$date\n";
                    } elsif (exists $$old{'due'}) {
                        my $due = $data->{'card'}->{'due'};
                        if (defined $due) {
                            my $newdate = date_from_iso8601($due);
                            $comment = "$namestr changed this card's due date to $newdate\n\n$date\n";
                        } else {
                            $comment = "$namestr removed this card's due date\n\n$date\n";
                        }
                    } else {
                        print STDERR "\n\n\nUnknown updateCard type for id $action_id! Ignoring it! Please update the script!\n\n\n\n";
                    }
                } elsif ($type eq 'addMemberToCard') {
                    # ignore this.
                } elsif ($type eq 'removeMemberFromCard') {
                    # ignore this.
                } elsif ($type eq 'addToOrganizationBoard') {
                    # ignore this.
                } elsif ($type eq 'createList') {
                    # ignore this.
                } elsif ($type eq 'updateList') {
                    # ignore this.
                } elsif ($type eq 'moveListFromBoard') {
                    # ignore this.
                } elsif ($type eq 'deleteCard') {
                    # ignore this (we shouldn't have gotten any other card metadata to have build one in the first place).
                } elsif ($type eq 'updateChecklist') {
                    # ignore this (I think...?)
                } else {
                    print STDERR "\n\n\nUnknown action type '$type' for id $action_id! Ignoring it! Please update the script!\n\n\n\n";
                }

                if (defined $comment) {
                    print("  - Creating comment for action $type from $origdate...\n");
                    $github->issue->create_comment($issue_number, { 'body' => $comment });
                    $comment_post_intensity++;
                    if ($comment_post_intensity >= $comment_post_intensity_threshold) {
                        rate_limit_sleep(5);  # add a delay to make this friendly to rate-limiting.
                        $comment_post_intensity = 0;
                    }
                }
                $restart_state_card_action = $action_index;
            }
        }

        if (scalar(@labels) > 0) {
            print("  - Setting labels...\n");
            $github->issue->create_issue_label($issue_number, \@labels);
            rate_limit_sleep(2);
        }

        if ($card->{'closed'}) {
            print("  - Closing issue...\n");
            $github->issue->update_issue($issue_number, { state => 'closed' });
            rate_limit_sleep(1);
        }

        $restart_state_card_action = 0;
        $restart_state_card_current_issue = 0;
        $restart_state_card_upload = $card_index;
    }
}

sub download_attachments {
    my $trello_cards = $trello->{'cards'};
    my $attachment_index = 0;
    foreach (@$trello_cards) {
        my $card = $_;
        my $trello_attachments = $$card{'attachments'};
        foreach (@$trello_attachments) {
            next if ($attachment_index++ < $restart_state_attachment_download);  # skip ones we already did.
            my $attachment = $_;
            my $attachment_id = $$attachment{'id'};
            my $path = "$restart_state_path/attachments/$attachment_id";
            my $url = $$attachment{'url'};
            die("attachment id '$attachment_id' is already downloaded! Hash collision?! This is a bug!!\n") if ( -f $path );
            print("Downloading attachment '$url' to '$path' ...\n");
            my $data = get($url);
            if (not defined $data) {
                die("Couldn't download '$url' ...please make sure the Trello board is public while we download all attachments.\n");
            }
            open(my $fh, '>', $path) or die("Failed to open '$path' for writing: $!\n");
            binmode($fh);
            if ((not print $fh $data) or (not close($fh))) {
                my $err = "Failed to write to '$path': $!\n";
                unlink($path);
                die($err);
            }

            print("Attachment downloaded.\n");
            $restart_state_attachment_download = $attachment_index;
        }
    }

    print("\n\n\nAll attachments have been downloaded from Trello. You can make the board private now, if you like.\n\n\n\n");
}

sub make_workdir {
    my $path = $restart_state_path;
    if ( ! -d $path ) {
        mkdir($path) or die("Couldn't make work directory: $!\n");
    }
    if ( ! -d "$path/attachments") {
        mkdir("$path/attachments") or die("Couldn't make '$path/attachments': $!\n");
    }
}

sub download_actions {
    my $path = "$restart_state_path/full_actions.json";

    if (!$restart_state_actions_downloaded) {
        if ((defined $trello_api_key) and (defined $trello_api_token)) {
            my $board_id = $$trello{'id'};
            my $before = $restart_state_actions_oldest;
            my $baseurl = "https://api.trello.com/1/boards/$board_id/actions?limit=1000&key=$trello_api_key&token=$trello_api_token";
            open(my $fullfh, '>>', $path) or die("Failed to open '$path': $!\n");
            while (1) {
                my $url = $baseurl;
                if (defined $before) {
                    $url .= "&before=$before";
                    print("Downloading block of full Trello actions (before=$before)...\n");
                } else {
                    print("Downloading initial block of full Trello actions...\n");
                }
                my $data = get($url);
                if (not defined $data) {
                    die("Couldn't download '$url'!\n");
                }

                my $block = decode_json($data) or die("Failed to decode action block json: $!\n");
                my $lastitem = pop @$block;
                last if not defined $lastitem;  # ran out of actions to download.

                $before = $$lastitem{'date'};

                $data =~ s/\A\[//;
                $data =~ s/\]\Z//;
                print $fullfh ($data . "\n") or die("Failed to write to '$path': $!\n");
                $restart_state_actions_oldest = $before;
            }
            close($fullfh) or die("Failed to write to '$path': $!\n");

            print("All action blocks downloaded.\n");
            $restart_state_actions_downloaded = 1;
        }
    }

    if ( -f $path ) {
        open(JSONIN, '<', $path) or die("Failed to open '$path': %!\n");
        # Don't set this, decode_json expects binary.
        #binmode JSONIN, ':utf8';
        my $jsonstr = '';
        my $initial_char = '[';
        while (<JSONIN>) {
            chomp;
            $jsonstr .= "$initial_char $_";
            $initial_char = ',';
        }
        close(JSONIN);
        $jsonstr .= ']';
        my $actions = decode_json($jsonstr) or die("Failed to decode full actions json: $!\n");
        $$trello{'actions'} = $actions;
    }
}

sub run_on_exit {
    return if $migration_finished < 0;
    save_restart_state();
    if (!$migration_finished) {
        print STDERR "\n\n\n";
        print STDERR "This script has _NOT_ finished before terminating.\n";
        print STDERR "You can run it again and it will pick up where it left off.\n";
        print STDERR "If you hit a rate limit, you might have to wait awhile before trying again.\n";
        print STDERR "\n\n\n";
    }
}

# Mainline!

local $SIG{INT} = sub { exit(1); };
END { run_on_exit(); }

parse_commandline();
make_workdir();
load_restart_state();
load_trello_json();
download_actions();
check_usermap();
init_label_colors();
download_attachments();
auth_to_github();
prep_repo();
upload_cards();

$migration_finished = 1;
print("\n\nMigration complete!\n\n");
print("You can delete the '$restart_state_path' directory now.\n\n");

# end of migrate-trello-to-github.pl ...
