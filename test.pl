#!/usr/bin/perl

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

#########################

use Test::Simple tests => 14;
use POE qw(Component::Child Filter::Stream);
ok(1, 'use PoCo::Child'); # If we made it this far, we're ok.

#########################

# Insert your test code below, the Test module is use()ed here so read
# its man page ( perldoc Test ) for help writing this test script.

$, = " ";
$\ = "\n";

my $debug = $ENV{DEBUG};

# event handlers

my %echo = (
	stdout => "echo_out",
	stderr => "echo_err",
	error => "echo_error",
	done => "echo_done",
	died => "echo_died"
	);

# create main session

$r = POE::Session->create(
	package_states => ["main" => [ values(%echo) ]],
	inline_states => {_start => sub { $_[KERNEL]->alias_set("main"); }}
	);

ok(defined($r), "session created");

# kick off first child process

$p = POE::Component::Child->new(
	callbacks => \%echo, debug => $debug
	);

$n1 = $p->run("./echosrv --stdout");	# first test an non-interactive app

ok(defined $p && $p->isa('POE::Component::Child') && $n1
	, "read-only client started"
	);

# POEtry in motion

POE::Kernel->run();

#
#	event handlers
#

sub echo_out {
	my ($self, $args) = @_[ARG0 .. $#_];
	local $_ = $args->{out};

	ok(/echo/, "got stdout");
	}

sub echo_err {
	my ($self, $args) = @_[ARG0 .. $#_];
	local $_ = $args->{out};

	if ($self->wheel() == $n2) {
		ok(/hej/, "client write");
		$self->quit();
		return;
		}

	ok($args->{out} =~ /echo/, "got stderr");
	}

sub echo_done {
	my ($self, $args) = @_[ARG0 .. $#_];

	my $wheel = $self->wheel();
	if ($wheel == $n1) {
		$p->run("./echosrv", "--stderr");
		ok(1, "second instance");
		return;
		}

	if ($wheel == $n2) {
		ok(1, "quit tested");
		$n3 = $self->run("./echosrv");
		ok(1, "client restarted");
		$self->kill();
		return;
		}

	if ($wheel == $n3) {
		return;
		}

	ok(1, "done");

	# now test callbacks

	$p = POE::Component::Child->new(
		callbacks => { done => \&echo_done_call }, debug => $debug
		);

	$p->run("ls", "--die");
	}

sub echo_error {
	my ($self, $args) = @_[ARG0 .. $#_];
	ok(0, "got unexpected error: $args->{error}");
	}

sub echo_died {
	my ($self, $args) = @_[ARG0 .. $#_];

	if ($self->wheel() ==  $n3) {
		ok(1, "killed");
		ok(1, "all tests successful");
		exit();
		}
	
	ok(0, "client died! [$args->{err}]: $args->{error}");
	}

sub echo_done_call {
	ok(1, "hard callbacks");

	# now test an interactive creature

	$p = POE::Component::Child->new(
		quit => "bye",
		callbacks => \%echo,
		debug => $debug,
		);

	ok($p && $p->isa("POE::Component::Child"),
		"interactive client started"
		);

	$n2 = $p->run("./echosrv");
	$p->write("hej");
	}
