#!/usr/bin/perl

use strict;
use warnings;

use Net::Telnet;
use OEMModule3;

use SDL;
use SDL::Event;
use SDLx::App;
use SDLx::Controller;

my $oem;
my $robot;

my $app = SDLx::Controller->new(
    dt      => 1, # movement step
    min_t   => 0,
    delay   => 1000, # milleseconds
);

$app->add_move_handler(\&check_status);

init_components();
$app->run();

$oem->off();


sub check_status {
    my $dist = $oem->measure_distance();
    warn $app->current_time . ": $dist\n";
}

sub init_components {
    my $sock = new Net::Telnet(
        Host => $ENV{EYEROBOT_TELNET},
        Port => 2000,
        Binmode => 1,
    );
    $sock->open();
    sleep(2);

    my $oem_telnet = OEMModule3::Telnet->new(
        server_name => $ENV{EYEROBOT_TELNET},
        server_port => 2000,
        telnet => $sock
    );

    $oem = OEMModule3->new({
            comm_class => 'OEMModule3::Telnet',
            server_name => $ENV{EYEROBOT_TELNET},
            server_port => 2000,
            comm => $oem_telnet
        });
    $oem->on();
}
