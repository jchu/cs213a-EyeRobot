#!/usr/bin/perl

use strict;
use warnings;

use Net::Telnet;
use OEMModule3;
use OEMModule3::Telnet;
use IRobot;
use IRobot::Telnet;

use SDL;
use SDL::Event;
use SDLx::App;
use SDLx::Controller;

my $MAX_DISTANCE_SKEW = 1000;

my $oem;
my $robot;
my $state;

my $app = SDLx::Controller->new(
    dt      => 1, # movement step
    min_t   => 0,
    delay   => 1000, # milleseconds
);

$app->add_move_handler(\&check_status);
$app->add_move_handler(\&move);

init_components();
center_robot();

$app->run();

$oem->off();
$robot->off();

sub move {
    if( $state->{moveable} ) {
        $robot->forward();
    } else {
        $robot->stop();
    }
}

sub center_robot {

    # simple. assume centered
    my $dist = $oem->measure_distance();
    
    if( $dist ) {
        $state->{distance_to_wall} = $dist;
    } else {
        warn "Sensors broken";
        exit(1);
    }

    warn "Maintaining distance " . $state->{distance_to_wall} . " from wall\n";
}

sub recenter_robot {
}


sub check_status {

    # Check sensors
    my $dist = $oem->measure_distance();
    if ($dist) {
        print $app->current_time . ": $dist\n";

        if( abs($state->{distance_to_wall} - $dist) > $MAX_DISTANCE_SKEW ) {
            warn "Distance skew detected\n";
            recenter_robot();
        }
    } else {
        warn "error: " . $oem->error() . "\n";
    }

    # Determine status

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

    my $robot_telnet = IRobot::Telnet->new(
        server_name => $ENV{EYEROBOT_TELNET},
        server_port => 2000,
        telnet => $sock
    );

    $robot = IRobot->new({
            comm_class => 'IRobot::Telnet',
            server_name => $ENV{EYEROBOT_TELNET},
            server_port => 2000,
            comm => $robot_telnet
        });
}
