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

#-------------------------------------------------
# Variables
#-------------------------------------------------

my $MAX_DISTANCE_SKEW   = 10; # mm
my $DISTANCE_SKEW_LIMIT = 100; # mm
my $FORWARD_SPEED       = 258; # mm/s
my $DEFAULT_CHECKPOINT_DISTANCE = 5000;

my %STATES = (
    STOP    => 0,
    MOVE    => 1,
    TURN    => 2
);

my %ACTIONS = (
    STOP            => 0,
    MOVE_FORWARD    => 1,
    CHECKPOINT      => 2,
    MOVE0           => 3,
    MOVE1           => 4
);

my $checkpoint_script = '/bin/sh checkpoint_script.sh';

my $oem;
my $robot;
my $state;

$ENV{SDL_VIDEODRIVER} = 'dummy';
my $app = SDLx::App->new(
    dt      => 0.001, # length movement step in seconds
    min_t   => 0,
    delay   => 0, # milleseconds between loops
);

$app->add_event_handler(\&quit_handler);
$app->add_move_handler(\&check_status);
$app->add_move_handler(\&move);

#--------------------------------------------------
# Main
#--------------------------------------------------

if( !defined( $ENV{EYEROBOT_TELNET} ) ) {
    print "EYEROBOT_TELNET not defined with ip address";
    exit(1);
}

print "Initializing...";
init_components();
center_robot();

$app->run();


#--------------------------------------------------
# Methods
#--------------------------------------------------
#
sub quit_handler {
    my $event = shift;

    return unless( $event->type == SDL_QUIT );

    warn 'Quitting application...';
    $app->stop();

    $state->{state} = $STATES{STOP};
    $state->{action} = $ACTIONS{STOP};
    $oem->off();
    sleep(1);
    $robot->drive_stop();
    sleep(1);
}

sub move {
    my $left_speed = $state->{speed}->[0];
    my $right_speed = $state->{speed}->[1];

    if( $state->{state} == $STATES{TURN} ) {
        if( $state->{action} == $ACTIONS{MOVE0}
            || $state->{action} == $ACTIONS{MOVE1} ) {
            $robot->drive_forward($left_speed, $right_speed);
            sleep(0.2); # required
            warn "Moving...\n";
            $state->{last_movement_check} = [gettimeofday()];
        } elsif( $state->{action} == $ACTIONS{CHECKPOINT} ) {
            $state->{action} = $ACTIONS{STOP};
            $robot->drive_stop();
            sleep(0.15); # required
            warn "Stopped...\n";
        }
    } elsif( $state->{state} == $STATES{MOVE} ) {
        unless( $state->{action} == $ACTIONS{MOVE_FORWARD} ) {
            $state->{action} = $ACTIONS{MOVE_FORWARD};
            $robot->drive_forward($left_speed, $right_speed);
            sleep(0.2); # required
            warn "Moving...\n";
            $state->{last_movement_check} = [gettimeofday()];
        }
    } elsif( $state->{state} == $STATES{STOP} ) {
        unless( $state->{action} == $ACTIONS{STOP} ) {
            $state->{action} = $ACTIONS{STOP};
            $robot->drive_stop();
            sleep(0.15); # required
            warn "Stopped...\n";
        }
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

# default turn left
sub turn_robot {
    $robot->turn_left();
    sleep(2.35); # quarter turn
}


sub check_status {
    warn Dumper($state);

    my $distance_travelled = $state->{distance_travelled_since_checkpoint};

    # Calculate forward distance travelled
    if( $state->{action} == $ACTIONS{MOVE_FORWARD}
        || $state->{action} == $ACTIONS{MOVE0}
        || $state->{action} == $ACTIONS{MOVE1} ) {
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

        unless( $state->{state} == $STATES{TURN} ) {
            $state->{state} = $STATES{STOP};
        }
        $state->{action} = $ACTIONS{CHECKPOINT};
        move();

        ##############
        $app->stop();
        if( system($checkpoint_script) ) {
            warn 'checkpoint script exited with error';

            $oem->off();
            sleep(1);
            $robot->drive_stop();
            sleep(1);
            exit(1);
        }

        if( $state->{state} == $STATES{TURN} ) {
            turn_robot();
            $state->{action} = $ACTIONS{MOVE1};
            $state->{distance_to_checkpoint} = $state->{distance_to_wall};
        } else {
            $state->{state} = $STATES{MOVE};
            $state->{distance_to_checkpoint} = $DEFAULT_CHECKPOINT_DISTANCE - ($state->{total_distance_travelled} % 1000);
        }

        $state->{distance_travelled_since_checkpoint} = 0;
        $state->{last_movement_check} = [gettimeofday()];

        $app->run();
        ##############

    }

    # Check sensors
    #
    # if error or distance exceed, reached a drop off and need to turn
    my $dist = $oem->measure_distance();
    if ($dist) {
        print $app->current_time . ": $dist\n";

        if( abs($state->{distance_to_wall} - $dist) > $MAX_DISTANCE_SKEW ) {
            my $skew = $state->{distance_to_wall} - $dist;

            warn "Side distance skew detected. Need to autocorrect\n";
            if( abs($skew) > $DISTANCE_SKEW_LIMIT ) {
                warn "Drop off detected";

                # Next checkpoint is a turn
                $state->{distance_to_checkpoint} = $state->{distance_to_wall};
                $state->{state} = $STATES{TURN};
                $state->{action} = $ACTIONS{MOVE0};
            } else {
                if( $skew < 0 ) { # too close to wall
                    $state->{speed} = [ $FORWARD_SPEED + 1, $FORWARD_SPEED ];
                } else { # can be veering left or right
                    $state->{speed} = [ $FORWARD_SPEED, $FORWARD_SPEED + 1 ];
                }
            }
        } else {
            $state->{speed} = [ $FORWARD_SPEED, $FORWARD_SPEED ];
        }

    } else {
        warn "error: " . $oem->error() . "\n";
        warn "possible drop off detected\n";

        $state->{distance_to_checkpoint} = $state->{distance_to_wall};
        $state->{state} = $STATES{TURN};
        $state->{action} = $ACTIONS{MOVE0};
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
    sleep(2); # wait for connection
    # TODO: check connection

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

    $state->{total_distance_travelled} = 0;
    $state->{distance_travelled_since_checkpoint} = 0;
    $state->{distance_to_checkpoint} = 0;
    $state->{speed} = [ $FORWARD_SPEED, $FORWARD_SPEED ];

    $state->{state} = $STATES{STOP};
    $state->{action} = $ACTIONS{CHECKPOINT};
    move();

    print "DONE!\n"
}
