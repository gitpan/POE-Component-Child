#!/usr/bin/perl -w

use Test::Simple tests => 13;

$, = " "; $\ = "\n";
$t1 = $t2 = 1;				# tests to run

my $debug = $ENV{DEBUG} || 0;
#sub POE::Kernel::TRACE_GARBAGE ()  { 1 }
#sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use POE qw(Component::Child Filter::Stream);
ok(1, 'use PoCo::Child'); # If we made it this far, we're ok.

my %t1 = (					# tests a non-interactive client
	stdout	=> "t1_out",
	stderr	=> "t1_err",
	error	=> "t1_error",
	done	=> "t1_done",
	died	=> "t1_died",
	);

my %t2 = (					# tests interactive client
	stderr	=> "t2_err",
	error	=> "t2_error",
	died	=> "t2_died",
	);

# create main session

$r = POE::Session->create(
	package_states => ["main" => [ values(%t1), values(%t2) ]],
	inline_states => {
		_start => sub { $_[KERNEL]->alias_set("main"); },
		_stop => sub { print "_stop" if $debug; },
		_default => \&_default,
		}
	);

ok(defined($r), "session created");

# test non-interactive child

if ($t1) {
	$t1 = POE::Component::Child->new(
		callbacks => \%t1, debug => $debug
		);
	ok(defined $t1 && $t1->isa('POE::Component::Child'), "component 1");
	$t1->run("./echosrv --stdout");
	}

# test interactive child

if ($t2) {
	$t2 = POE::Component::Child->new(
		quit => "bye",
		callbacks => { %t2, done => \&t2_done },
		debug => $debug
		);
	ok(defined $t2 && $t2->isa('POE::Component::Child'), "component 2");
	$t2->run("./echosrv");
	$t2->write("hej");
	}

# POEtry in motion

POE::Kernel->run();

ok(1, "all tests successful");

# --- event handlers - non-interactive child ----------------------------------

sub t1_out {
	my ($self, $args) = @_[ARG0 .. $#_];
	local $_ = $args->{out};

	ok(/echo/, "standard output");
	}

sub t1_err {
	my ($self, $args) = @_[ARG0 .. $#_];
	ok($args->{out} =~ /echo/, "standard error");
	}

$t1n = 0;
sub t1_done {
	my ($self, $args) = @_[ARG0 .. $#_];

	if ($t1n++ == 0) {
		$t1->run("./echosrv", "--stderr");
		}

	else {
		ok(1, "done");
		$t1->run("./echosrv", "--die");
		}
	}

sub t1_died {
	ok(1, "died");
	}

sub t1_error {
	my ($self, $args) = @_[ARG0 .. $#_];
	ok(0, "Co1: unexpected error: $args->{error}");
	}

# --- event handlers - interactive child --------------------------------------

sub t2_err {
	my ($self, $args) = @_[ARG0 .. $#_];
	ok($args->{out} eq "hej", "client write tested");
	$t2->quit();
	}

$t2n = 0;
sub t2_done {
	my ($self, $args) = @_[ARG0 .. $#_];

	if ($t2n++) {
		ok(0, "kill problem");
		return;
		}

	ok(1, "callback references");
	ok(1, "quit method");
	$t2->run("./echosrv");
	$t2->kill();
	}

sub t2_died {
	my ($kernel, $self, $args) = @_[KERNEL, ARG0 .. $#_];
	ok(1, "killed");
	}
	
sub t2_error {
	my ($self, $args) = @_[ARG0 .. $#_];
	ok(0, "Co2: unexpected error: $args->{error}");
	}

sub _default {
	return unless $debug;
	print qq/> _default: "$_[ARG0]" event, args: @{$_[ARG1]}/;
	exit if $_[ARG1][0] eq "INT";
	}
