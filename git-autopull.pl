#!/usr/bin/env perl

use warnings;
use strict;

use Net::HTTPServer;
use Config::Scoped;
use Proc::Daemon;
use JSON;
use File::stat;
use threads;
use Cwd;
use Data::Dumper;

my $daemon_run = 1;
my $conf_path = "/etc/git-autopull.conf";
my $config;

$SIG{TERM} = sub { $daemon_run = 0 };

sub logger {
    my $lfd;
    my $message = $_[0];
    #open($lfd, '>>', './autopull.log');
    print $message;
    #close($lfd);
}

sub readConfig {

    if(not -f $conf_path) {
        logger("Unable to read $conf_path: No such file!\n");
        exit(-1);
    }

    # Since this daemon probably will be run as root some day, make sure
    # we don't open all doors for other users to execute arbitrary commands.
    my $running_uid = (getpwuid($<))[2];
    my $filestat = stat($conf_path);
    my $filemode = sprintf("0%o", $filestat->mode & 07777);
    if($running_uid != $filestat->uid or $filemode ne "0600") {
        logger($conf_path.": Permissions must be 0600 (currently $filemode) and owned by the running user (uid $running_uid)\n");
        exit(-1);
    }

    logger("Reading configuration $conf_path\n");
    my $cs = Config::Scoped->new(
        file    => $conf_path,
    );

    $config = $cs->parse;
    if(not $config) {
        logger("Unable to parse configuration file!\n");
        exit(-1);
    }

    if(not $config->{'repo'}) {
        logger("No repositories configured, my job here is done...!\n");
        exit(0);
    }

    while(my($repo, $rs) = each(%{$config->{'repo'}})) {
        if(not $rs->{'cmd'}) {
            $rs->{'cmd'} = "git pull origin master";
        }

        # Not sure if this should be a MUST, but it is for now.
        if(not $rs->{'workdir'}) {
            logger("You must specify a working directory!\n");
            exit(-1);
        }elsif(not -d $rs->{'workdir'}) {
            logger($rs->{'workdir'}.": Directory does not exist!\n");
            exit(-1);
        }


    }

    while(my($server, $settings) = each(%{$config->{'listen'}})) {

        if(not $settings->{'log'}) {
            my $log = "/var/log/gitlab-autopull/access.log";
            logger("No log path set for server $server, using default $log\n");
            $settings->{'log'} = $log;
        }

        if(not -f $settings->{'log'}) {
            logger($settings->{'log'}.": File or directory does not exist!\n");
            exit(-1);
        }
    }
}

sub http_json {

    my $req = shift;
    my $res = $req->Response();
    my $js;

    # Just get the JSON part of the request
    if($req->{'REQUEST'} =~ m/(\{.*\})/) {
        my $json_source = $1;
        $js = decode_json($json_source);
    }

    while(my($repo, $repo_settings) = each(%{$config->{'repo'}})) {
        if($repo eq $js->{'repository'}->{'name'}) {
            logger("Executing \"".$repo_settings->{'cmd'}."\" for repo $repo\n");
            if(not chdir($repo_settings->{'workdir'})) {
                logger("Unable to change to workdir ".$repo_settings->{'workdir'}.": $!\n");
                return $res;
            }
            system($repo_settings->{'cmd'});
        }
    }

    return $res;
}

sub startServer {
    my $servername = shift;
    my $settings = shift;

    logger("Starting $servername... ");
    my $s = Net::HTTPServer->new(
                                port => $settings->{'port'},
                                host => $settings->{'address'},
                                type => 'forking',
                                log  => $settings->{'log'},
                            );
    $s->RegisterURL("/", \&http_json);
    if($s->Start()) {
        logger("Done!\n");
        $s->Process();
    }else{
        logger("Failed!\n");
    }

    return 0;
}

sub initServers {
    my @threads;

    while(my($servername, $settings) = each(%{$config->{'listen'}})) {
        push(@threads, threads->create('startServer', $servername, $settings));
    }

    while($daemon_run) {
        # Clean up.
        foreach my $thr (threads->list(threads::joinable)) {
            $thr->join();
        }
        if((threads->list(threads::running)) <= 0) {
            $daemon_run = 0;
            logger("Something bad happened, all servers are down!\n");
        }
        sleep(1);
    }

    # Clean up.
    foreach my $thr (threads->list(threads::joinable)) {
        $thr->join();
    }

    # Rather ugly(?) way of letting our threads go
    # so we don't get errors when exiting the program.
    foreach my $thr (threads->list(threads::running)) {
        $thr->detach();
    }

    return 0;
}

sub main {
    $conf_path = $ARGV[0] if $ARGV[0];
    readConfig();

    my $pid = Proc::Daemon::Init({work_dir => getcwd()});
    if($pid) {
        print "Daemon PID $pid\n";
        return 0;
    }
    initServers();

    return 0;
}
main();
