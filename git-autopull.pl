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

$SIG{TERM} = "daemon_shutdown";

sub daemon_shutdown {
    $daemon_run = 0;
    logger("Received signal to shutdown, cleaning up!\n");

    logger("Killing ".threads->list(threads::running)." server threads...\n");
    foreach my $thr (threads->list(threads::running)) {
        $thr->kill('USR1');
    }
    
    while(threads->list(threads::running) or threads->list(threads::joinable)) {
        # Clean up.
        logger("Joining ".threads->list(threads::joinable)." server threads\n");
        foreach my $thr (threads->list(threads::joinable)) {
            $thr->join();
        }
        sleep(1);
    }

    exit(0);
}

sub logger {
    my $lfd;
    my $message = $_[0];
    if(defined $config->{'global'}->{'log_file'} and -f $config->{'global'}->{'log_file'}) {
        open($lfd, '>>', $config->{'global'}->{'log_file'});
        print $lfd $message;
        close($lfd);
    }else{
        print $message;
    }
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

    if(not $config->{'global'}) {
        logger("No global configuration definitions found!\n");
        exit(-1);
    }

    while(my ($key, $value) = each($config->{'global'})) {
       if(not $key->{'pid_file'}) {
          $key->{'pid_file'} = "/var/run/gitlab-autopull.pid";
       }
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

        if(($settings->{'ssl_cert_file'} and (not $settings->{'ssl_key_file'} or not $settings->{'ssl_ca_file'}))
                or ($settings->{'ssl_key_file'} and (not $settings->{'ssl_cert_file'} or not $settings->{'ssl_ca_file'}))
                or ($settings->{'ssl_ca_file'} and (not $settings->{'ssl_cert_file'} or not $settings->{'ssl_key_file'}))) {
            logger("ssl_cert_file, ssl_key_file and ssl_ca_file are needed for SSL support!\n");
            exit(-1);
        }

        if($settings->{'ssl_cert_file'} and not -f $settings->{'ssl_cert_file'}) {
            logger($settings->{'ssl_cert_file'}.": No such file!\n");
            exit(-1);
        }

        if($settings->{'ssl_key_file'} and not -f $settings->{'ssl_key_file'}) {
            logger($settings->{'ssl_key_file'}.": No such file!\n");
            exit(-1);
        }

        if($settings->{'ssl_ca_file'} and not -f $settings->{'ssl_ca_file'}) {
            logger($settings->{'ssl_ca_file'}.": No such file!\n");;
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
    my $server_run = 1;
    my $s;

    logger("Starting $servername... ");

    if($settings->{'ssl_cert_file'} and $settings->{'ssl_key_file'}) {
        $s = Net::HTTPServer->new(
                                port => $settings->{'port'},
                                host => $settings->{'host'},
                                type => 'forking',
                                log  => $settings->{'log'},
                                ssl  => 1,
                                ssl_cert => $settings->{'ssl_cert_file'},
                                ssl_key  => $settings->{'ssl_key_file'},
                                ssl_ca   => $settings->{'ssl_ca_file'},
                            );
    }else{
        $s = Net::HTTPServer->new(
                                port => $settings->{'port'},
                                host => $settings->{'address'},
                                type => 'forking',
                                log  => $settings->{'log'},
                            );
    }
    $s->RegisterURL("/", \&http_json);
    $SIG{'USR1'} = sub {$server_run = 0;};

    if($s->Start()) {
        logger("Done!\n");
        while($server_run) {
            $s->Process(1);
        }
    }else{
        logger("Failed!\n");
    }

    logger("Shutting down $servername!\n");
    $s->Stop();
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
            logger("Something bad happened, all servers are down!\n");
            daemon_shutdown();
        }
        sleep(1);
    }

    daemon_shutdown();
    return 0;
}

sub main {
    $conf_path = $ARGV[0] if $ARGV[0];
    readConfig();

    my $pid = Proc::Daemon::Init({work_dir => getcwd(), pid_file => $config->{'global'}->{'pid_file'}});
    if($pid) {
        return 0;
    }
    initServers();

    return 0;
}
main();
