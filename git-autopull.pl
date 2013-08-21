#!/usr/bin/env perl

use warnings;
use strict;

use Net::HTTPServer;
use Config::Scoped;
use Proc::Daemon;
use JSON;
use threads;
use Data::Dumper;

my $daemon_run = 1;
my $conf_path = "/etc/git-autopull.conf";
my $config;

$SIG{TERM} = sub { $daemon_run = 0 };

sub readConfig {

    print "Reading configuration $conf_path\n";
    my $cs = Config::Scoped->new(
        file    => $conf_path,
    );

    $config = $cs->parse;
    if(not $config) {
        print "Unable to parse configuration file!\n";
        exit(-1);
    }

    if(not $config->{'repo'}) {
        print "No repositories configured, my job here is done...!\n";
        exit(0);
    }

    while(my($repo, $rs) = each(%{$config->{'repo'}})) {
        if(not $rs->{'cmd'}) {
            $rs->{'cmd'} = "git pull origin master";
        }

        # Not sure if this should be a MUST, but it is for now.
        if(not $rs->{'workdir'}) {
            print "You must specify a working directory!\n";
            exit(-1);
        }elsif(not -d $rs->{'workdir'}) {
            print $rs->{'workdir'}.": Directory does not exist!\n";
            exit(-1);
        }
    }

    print Dumper($config);
}

sub http_json {

    my $req = shift;
    my $res = $req->Response();
    my $js;

    # Just get the JSON part of the request
    if($req->{'REQUEST'} =~ m/(\{.*\})/) {
        my $json_source = $1;
        $js = decode_json($json_source);
        print Dumper($js);
    }

    while(my($repo, $repo_settings) = each(%{$config->{'repo'}})) {
        if($repo eq $js->{'repository'}->{'name'}) {
            print "Executing \"".$repo_settings->{'cmd'}."\" for repo $repo\n";
            if(not chdir($repo_settings->{'workdir'})) {
                print "Unable to change to workdir ".$repo_settings->{'workdir'}.": $!\n";
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

    print "Starting $servername...\n";
    my $s = Net::HTTPServer->new(
                                port => $settings->{'port'},
                                host => $settings->{'address'},
                                type => 'forking',
                            );
    $s->RegisterURL("/", \&http_json);
    if($s->Start()) {
        $s->Process();
    }else{
        print "Could not start $servername...!\n";
    }

    return 0;
}

sub initServers {
    my @threads;

    while(my($servername, $settings) = each(%{$config->{'listen'}})) {
        push(@threads, threads->create('startServer', $servername, $settings));
    }

    while($daemon_run) {
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

    my $pid = Proc::Daemon::Init();
    if($pid) {
        return 0;
    }
    $conf_path = $ARGV[0] if $ARGV[0];
    readConfig();
    initServers();

    return 0;
}
main();
