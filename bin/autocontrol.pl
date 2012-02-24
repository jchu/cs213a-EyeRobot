#!/usr/bin/perl

use strict;
use warnings;

use Net::Telnet;
use Time::HiRes qw(gettimeofday tv_interval nanosleep);
use Data::Dumper::Concise;

use OEMModule3;
use OEMModule3::Telnet;
use IRobot;
use IRobot::Telnet;

use SDL;
use SDL::Event;
use SDLx::App;
use SDLx::Controller;

my $MAX_DISTANCE_SKEW = 10; # mm
my $DISTANCE_SKEW_LIMIT = 100; # mm
my $FORWARD_SPEED = 258; # mm/s

my $checkpoint_script = '/usr/bin/python script.py';

my $oem;
my $robot;
my $state;

my $app = SDLx::Controller->new(
    dt      => 0.001, # length movement step in seconds
    min_t   => 0,
    delay   => 0, # milleseconds between loops
);

$app->add_move_handler(\&check_status);
$app->add_move_handler(\&move);

print "Initializing...";
init_components();
center_robot();

$app->run();

$oem->off();
sleep(1);
$robot->drive_stop();
sleep(1);

sub move {
    if( $state->{moveable} ) {
        unless( $state->{action} eq 'MOVE_FORWARD' ) {
            $state->{action} = 'MOVE_FORWARD';
            $robot->drive_forward();
            sleep(1);
            warn "Moving...\n";
            $state->{last_movement_check} = [gettimeofday()];
        }
    } else {
        $robot->drive_stop();
        $state->{action} = 'STOP';
        warn "Stopped...\n";
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
    $state->{moveable} = 1;
}

sub recenter_robot {
}


sub check_status {
    warn Dumper($state);

    my $distance_travelled = $state->{distance_travelled_since_checkpoint};

    # Calculate forward distance travelled
    if( $state->{action} eq 'MOVE_FORWARD' ) {
        my $new_time = [gettimeofday()];
        my $old_time = $state->{last_movement_check};
        my $diff_time = tv_interval($old_time, $new_time);
        my $distance = $diff_time * $FORWARD_SPEED;
        warn "$diff_time: $distance\n";
        $distance_travelled += $distance;
    }

    # CHECKPOINT
    if( $state->{distance_to_checkpoint} <= $distance_travelled ) {
        $state->{total_distance_travelled} += $distance_travelled;
        print "Checkpoint reached at " . $state->{total_distance_travelled} . "\n";

        if( int($state->{total_distance_travelled} / $state->{major_checkpoint}) > $state->{checkpointed} ) {
            # major checkpoint
            $state->{checkpointed}++;

            $state->{moveable} = 0;
            $state->{action} = 'STOP';
            move();
            sleep(1);
            if( system($checkpoint_script) ) {
                die 'checkpoint script exited with error';
            }
        }


        $state->{moveable} = 1;

        $state->{distance_to_checkpoint} = 1000 - ($state->{total_distance_travelled} % 1000);

        $state->{distance_travelled_since_checkpoint} = 0;
        $state->{last_movement_check} = [gettimeofday()];
    }

    # Check sensors
    #
    # if error or distance exceed, reached a drop off and need to turn
    my $dist = $oem->measure_distance();
    if ($dist) {
        print $app->current_time . ": $dist\n";

        if( abs($state->{distance_to_wall} - $dist) > $MAX_DISTANCE_SKEW ) {
            warn "Side distance skew detected. Need to autocorrect\n";
            if( abs($state->{distance_to_wall} - $dist) > $DISTANCE_SKEW_LIMIT ) {
                warn "Drop off detected";
                # turn_left();
        #    recenter_robot();
            }
        }
    } else {
        warn "error: " . $oem->error() . "\n";
        warn "possible drop off detected\n";
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

    $robot->start(1);
    sleep(1);
    $robot->drive_stop();
    sleep(1);

    $state->{total_distance_travelled} = 0;
    $state->{distance_travelled_since_checkpoint} = 0;
    $state->{distance_to_checkpoint} = 1000;
    $state->{major_checkpoint} = 5000;
    $state->{checkpointed} = 0;
    $state->{action} = 'STOP';

    print "DONE!\n"
}
