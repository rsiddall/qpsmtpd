#!/usr/bin/perl

use strict;
use warnings;

use Cwd;
use Data::Dumper;
use File::Tail;

$Data::Dumper::Sortkeys = 1;

my (%plugins, %plugin_aliases, %seen_plugins, %pids);
my %hide_plugins = map { $_ => 1 } qw/ hostname /;

my $qpdir = get_qp_dir();
my $file  = "$qpdir/log/main/current";
populate_plugins_from_registry();
my @sorted_plugins = sort { $plugins{$a}{id} <=> $plugins{$b}{id} } keys %plugins;

my $fh = File::Tail->new(name=>$file, interval=>1, maxinterval=>1, debug =>1, tail =>1000 );
my $printed = 0;
my $has_cleanup;

my %formats = (
    ip                    => "%-15.15s",
    hostname              => "%-20.20s",
    distance              =>    "%5.5s",

    'ident::geoip'        => "%-20.20s",
    'ident::p0f'          => "%-10.10s",
    count_unrecognized_commands => "%-5.5s",
    unrecognized_commands => "%-5.5s",
    dnsbl                 => "%-3.3s",
    rhsbl                 => "%-3.3s",
    relay                 => "%-3.3s",
    karma                 => "%-3.3s",
    earlytalker           => "%-3.3s",
    check_earlytalker     => "%-3.3s",
    helo                  => "%-3.3s",
    tls                   => "%-3.3s",
    badmailfrom           => "%-3.3s",
    check_badmailfrom     => "%-3.3s",
    sender_permitted_from => "%-3.3s",
    resolvable_fromhost   => "%-3.3s",
    'queue::qmail-queue'  => "%-3.3s",
    connection_time       => "%-4.4s",
);

my %formats3 = (
    %formats,
    badrcptto            => "%-3.3s",
    check_badrcptto      => "%-3.3s",
    qmail_deliverable    => "%-3.3s",
    rcpt_ok              => "%-3.3s",
    check_basicheaders   => "%-3.3s",
    headers              => "%-3.3s",
    uribl                => "%-3.3s",
    bogus_bounce         => "%-3.3s",
    check_bogus_bounce   => "%-3.3s",
    domainkeys           => "%-3.3s",
    dkim                 => "%-3.3s",
    spamassassin         => "%-3.3s",
    dspam                => "%-3.3s",
    'virus::clamdscan'   => "%-3.3s",
);


while ( defined (my $line = $fh->read) ) {
    chomp $line;
    next if ! $line;
    my ( $type, $pid, $hook, $plugin, $message ) = parse_line( $line );
    next if ! $type;
    next if $type =~ /info|unknown|response/;
    next if $type eq 'init';           # doesn't occur in all deployment models

    if ( ! $pids{$pid} ) {             # haven't seen this pid 
        next if $type ne 'connect';    # ignore unless connect
        my ($host, $ip) = split /\s/, $message;
        $ip = substr $ip, 1, -1;
        $pids{$pid}{ip} = $ip;      
        $pids{$pid}{hostname} = $host if $host ne 'Unknown';
    };

    if ( $type eq 'close' ) {
        next if $has_cleanup;           # it'll get handled later
        print_auto_format($pid, $line);
        delete $pids{$pid};
    }
    elsif ( $type eq 'cleanup' ) {
        print_auto_format($pid, $line);
        delete $pids{$pid};
    }
    elsif ( $type eq 'plugin' ) {
        next if $plugin eq 'naughty';    # housekeeping only
        if ( ! $pids{$pid}{$plugin} ) {  # first entry for this plugin
            $pids{$pid}{$plugin} = $message;
        }
        else {                           # subsequent log entry for this plugin
            if ( $pids{$pid}{$plugin} !~ /^(?:pass|fail|skip)/i ) {
                $pids{$pid}{$plugin} = $message;  # overwrite 1st
            }
            else {
                #print "ignoring subsequent hit on $plugin: $message\n";
            };
        };

        if ( $plugin eq 'ident::geoip' ) {
            my ($gip, $distance) = $message =~ /(.*?),\s+([\d]+)\skm/;
            if ( $distance ) {
                $pids{$pid}{$plugin}  = $gip;
                $pids{$pid}{distance} = $distance;
            };
        };
    }
    elsif ( $type eq 'reject' ) { }
    elsif ( $type eq 'connect' ) { }
    elsif ( $type eq 'dispatch' ) {
        if ( $message =~ /^dispatching MAIL FROM/i ) {
            my ($from) = $message =~  /<(.*?)>/;
            $pids{$pid}{from} = $from;
        }
        elsif ( $message =~ /^dispatching RCPT TO/i ) {
            my ($to) = $message =~  /<(.*?)>/;
            $pids{$pid}{to} = $to;
        }
        elsif ( $message =~ m/dispatching (EHLO|HELO) (.*)/ ) {
            $pids{$pid}{helo_host} = $2;
        }
        elsif ( $message eq 'dispatching DATA' ) { }
        elsif ( $message eq 'dispatching QUIT' ) { }
        elsif ( $message eq 'dispatching STARTTLS' ) { }
        elsif ( $message eq 'dispatching RSET' ) {
            print_auto_format($pid, $line);
        }
        else {
            # anything here is likely an unrecognized command
            #print "$message\n";
        };
    }
    else {
        print "$type $pid $hook $plugin $message\n";
    };
};

sub parse_line {
    my $line = shift;
    my ($tai, $pid, $message) = split /\s+/, $line, 3;
    return if ! $message;  # garbage in the log file

    # lines seen many times per connection
    return parse_line_plugin( $line ) if substr($message, 0, 1) eq '(';
    return ( 'dispatch', $pid, undef, undef, $message ) if substr($message, 0, 12) eq 'dispatching ';
    return ( 'response', $pid, undef, undef, $message ) if $message =~ /^[2|3]\d\d/;

    # lines seen about once per connection
    return ( 'init',     $pid, undef, undef, $message ) if substr($message, 0, 19) eq 'Accepted connection';
    return ( 'connect',  $pid, undef, undef, substr( $message, 16) ) if substr($message, 0, 15) eq 'Connection from';
    return ( 'close',    $pid, undef, undef, $message ) if substr($message, 0, 6) eq 'close ';
    return ( 'close',    $pid, undef, undef, $message ) if substr($message, 0, 20) eq 'click, disconnecting';
    return parse_line_cleanup( $line ) if substr($message, 0, 11) eq 'cleaning up';

    # lines seen less than once per connection
    return ( 'info',     $pid, undef, undef, $message ) if $message eq 'spooling message to disk';
    return ( 'reject',   $pid, undef, undef, $message ) if $message =~ /^[4|5]\d\d/;
    return ( 'reject',   $pid, undef, undef, $message ) if substr($message, 0, 14) eq 'deny mail from';
    return ( 'reject',   $pid, undef, undef, $message ) if substr($message, 0, 18) eq 'denysoft mail from';
    return ( 'info',     $pid, undef, undef, $message ) if substr($message, 0, 15) eq 'Lost connection';
    return ( 'info',     $pid, undef, undef, $message ) if $message eq 'auth success cleared naughty';
    return ( 'info',     $pid, undef, undef, $message ) if substr($message, 0, 15) eq 'Running as user';
    return ( 'info',     $pid, undef, undef, $message ) if substr($message, 0, 16) eq 'Loaded Qpsmtpd::';
    return ( 'info',     $pid, undef, undef, $message ) if substr($message, 0, 24) eq 'Permissions on spool_dir';
    return ( 'info',     $pid, undef, undef, $message ) if substr($message, 0, 13) eq 'Listening on ';

    print "UNKNOWN LINE: $line\n";
    return ( 'unknown',  $pid, undef, undef, $message );
};

sub parse_line_plugin {
    my ($line) = @_;

    # @tai 13486 (connect) ident::p0f: Windows (XP/2000 (RFC1323+, w, tstamp-))
    # @tai 13681 (connect) dnsbl: fail, NAUGHTY
    # @tai 15787 (connect) karma: pass, no penalty (0 naughty, 3 nice, 3 connects)
    # @tai 77603 (queue) queue::qmail_2dqueue: (for 77590) Queuing to /var/qmail/bin/qmail-queue
    my ($tai, $pid, $hook, $plugin, $message ) = split /\s/, $line, 5;
    $plugin =~ s/:$//;
    if ( $plugin =~ /_3a/ ) {
        ($plugin) = split '_3a', $plugin;  # trim :N off the plugin log entry
    };
    $plugin =~ s/_2d/-/g;

    $plugin = $plugin_aliases{$plugin} if $plugin_aliases{$plugin};  # map alias to master
    if ( $hook eq '(queue)' ) {
        ($pid) = $message =~ /\(for ([\d]+)\)\s/;
        $message = 'pass';
    };

    return ( 'plugin', $pid, $hook, $plugin, $message );
};

sub parse_line_cleanup {
    my ($line) = @_;
    # @tai 85931 cleaning up after 3210
    my $pid = (split /\s+/, $line)[-1];   
    $has_cleanup++;
    return ( 'cleanup', $pid, undef, undef, $line );
};

sub print_auto_format {
    my ($pid, $line) = @_;

    my $format;
    my @headers;
    my @values;

    foreach my $plugin ( qw/ ip hostname distance /, @sorted_plugins ) {
        if ( defined $pids{$pid}{$plugin} ) {
            if ( ! $seen_plugins{$plugin} ) { # first time seeing this plugin
                $printed = 0;                 # force header print
            };
            $seen_plugins{$plugin}++;
        };

        next if ! $seen_plugins{$plugin};     # hide plugins not used
        if ( $hide_plugins{$plugin} ) {       # user doesn't want to see
            delete $pids{$pid}{$plugin};
            next;
        };               

        if ( defined $pids{$pid}{helo_host} && $plugin =~ /helo/ ) {
            $format .= " %-18.18s";
            push @values, delete $pids{$pid}{helo_host};
            push @headers, 'HELO';
        }
        elsif ( defined $pids{$pid}{from} && $plugin =~ /from/ ) {
            $format .= " %-20.20s";
            push @values, delete $pids{$pid}{from};
            push @headers, 'MAIL FROM';
        }
        elsif ( defined $pids{$pid}{to} && $plugin =~ /to|rcpt|recipient/ ) {
            $format .= " %-20.20s";
            push @values, delete $pids{$pid}{to};
            push @headers, 'RCPT TO';
        };

        $format .= $formats3{$plugin} ? " $formats3{$plugin}" : " %-10.10s";

        if ( defined  $pids{$pid}{$plugin} ) {
            push @values, show_symbol( delete $pids{$pid}{$plugin} );
        }
        else {
            push @values, '';
        };
        push @headers, ($plugins{$plugin}{abb3} ? $plugins{$plugin}{abb3} : $plugin);
    }
    $format .= "\n";
    printf( "\n$format", @headers ) if ( ! $printed || $printed % 20 == 0 );
    printf( $format, @values );
    print Data::Dumper::Dumper( $pids{$pid} ) if keys %{$pids{$pid}};
    $printed++;
};

sub show_symbol {
    my $mess = shift;
    return ' o' if $mess eq 'TLS setup returning';
    return ' -' if $mess eq 'skip';
    return ' -' if $mess =~ /^skip[,:\s]/i;
    return ' o' if $mess eq 'pass';
    return ' o' if $mess =~ /^pass[,:\s]/i;
    return ' X' if $mess =~ /^fail[,:\s]/i;
    return ' x' if $mess =~ /^negative[,:\s]/i;
    return ' o' if $mess =~ /^positive[,:\s]/i;
    return ' !' if $mess =~ /^error[,:\s]/i;
    $mess =~ s/\s\s/ /g;
    return $mess;
};

sub get_qp_dir {
    foreach my $user ( qw/ qpsmtpd smtpd / ) {
        my ($homedir) = (getpwnam( $user ))[7] or next;

        if ( -d "$homedir/plugins" ) {
            return "$homedir";
        };
        foreach my $s ( qw/ smtpd qpsmtpd qpsmtpd-dev / ) {
            if ( -d "$homedir/smtpd/plugins" ) {
                return "$homedir/smtpd";
            };
        };
    };
    if ( -d "./plugins" ) {
        return Cwd::getcwd();
    };
};

sub populate_plugins_from_registry {

    my $file = "$qpdir/plugins/registry.txt";
    if ( ! -f $file ) {
        die "unable to find plugin registry\n";
    };

    open my $F, '<', $file;
    while ( defined ( my $line = <$F> ) ) {
        next if $line =~ /^#/;  # discard comments
        my ($id, $name, $abb3, $abb5, $aliases) = split /\s+/, $line;
        next if ! defined $name;
        $plugins{$name} = { id=>$id, abb3=>$abb3, abb5=>$abb5 };

        next if ! $aliases;
        $aliases =~ s/\s+//g;
        $plugins{$name}{aliases} = $aliases;
        foreach my $a ( split ',', $aliases ) {
            $plugin_aliases{$a} = $name;
        };
    };
};

