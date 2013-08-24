gitlab Auto Pull
=========================================

This is a script that will run as a daemon and handle web hook POSTs sent by gitlabhq.
The script is completely stand-alone which means there is no requirement for web-servers like Apache or nginx.

By default the script will execute a git pull for repositories defined in the configuration file but you can define
any commands to be executed to a specific repository.

Required perl modules
-------------------------
- Socket (libsocket-perl)
- Net::HTTPServer (https://github.com/diddi-/Net-HTTPServer.git for IPv6 support)
    * URI (liburi-perl)
- Config::Scoped (libconfig-scoped)
- Proc::Daemon (libproc-daemon-perl)
- JSON (libjson-perl)
- threads (libthreads-perl)

Optional perl modules
---------------------------

- IO::Socket::SSL (libio-socket-ssl-perl)

Installing
-----------------------------

To install gitlab-autopull, all you have to do is the following

1. Copy git-autopull.pl to somewhere in your $PATH (e.g. /usr/local/bin/)

2. Copy git-autopull.conf to /etc/

3. Copy gitlab-autopull to /etc/init.d/ if your system uses LSB Init scripts

4. Configure your gitlab-autopull daemon (see below) and set a web hook destination in gitlabhq

- Go to Settings -> Web Hooks and enter your destination (e.g. http://IP:PORT/) 

Configuring gitlab-autopull
------------------------------------

All configurations to gitlab-autopull is done in git-autopull.conf. 
Normally all you have to edit is the different "listen" directives to start the server, and then the "repo" directives 
to actually make something useful when a push is made to a repository.

See git-autopull.conf for examples and comments on how to configure it.

