#
#	POE child management
#	Copyright (c) Erick Calder, 2002.
#	All rights reserved.
#

package POE::Component::Child;

# --- external modules --------------------------------------------------------

use warnings;
use strict;
use Carp;

use POE qw(Wheel::Run Filter::Line Driver::SysRW);

# --- module variables --------------------------------------------------------

use vars qw($VERSION);
$VERSION = substr q$Revision: 1.16 $, 10;

# --- module interface --------------------------------------------------------

sub new {
	my $class = shift;
	my $self = bless({}, $class);

	my $opts = shift;
	my %opts = !defined($opts) ? () : ref($opts) ? %$opts : ($opts, @_);
	%$self = (%$self, %opts);

	$self->{alias} ||= "main";
	$self->{callbacks}{stdout} ||= "stdout";
	$self->{callbacks}{stderr} ||= "stderr";
	$self->{callbacks}{error} ||= "error";
	$self->{callbacks}{done} ||= "done";
	$self->{callbacks}{died} ||= "died";

	# session handler list
	my @sh =	qw(_start _stop);
	push @sh,	qw(stdout stderr error sig_child);
	push @sh,	qw(got_run got_write got_kill);

	POE::Session->create(
		package_states => [ "POE::Component::Child" => \@sh ],
		heap => { self => $self }
		);

	return $self;
	}

sub run {
	my $self = shift;
	POE::Kernel->call($self->{session}, got_run => $self, \@_);
	}

sub write {
	my $self = shift;
	POE::Kernel->post($self->{session},
		got_write => $self, $self->wheel(), \@_
		);
	}

sub quit {
	my $self = shift;
	my $quit = shift || $self->{quit};

	$quit ? $self->write($quit) : $self->kill();

	$self->{wheels}{$self->wheel()}{quit} = 1;
	}

sub kill {
	my $self = shift;
	POE::Kernel->post($self->{session},
		got_kill => $self, $self->wheel()
		);
	}

sub wheel {
	my $self = shift;
	$self->{wheels}{current} = shift if @_;
	$self->{wheels}{current};
	}

# --- session handlers --------------------------------------------------------

sub _start {
	my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
	my $self = $heap->{self};
	$self->{session} = $session->ID;
	$self->debug("session-id: $self->{session}");

	# install death handler
    $kernel->sig(CHLD => 'sig_child');

	# to make sure our session sticks around between
	# wheel invocations we set an alias (unique per sesion)

	$kernel->alias_set("PoCo::Child::$self->{session}");
	}

sub _stop {
	my ($heap, $session) = @_[HEAP, SESSION];
	my $self = $heap->{self};

	# felicitous infanticide
	CORE::kill 9, $_ for keys %{ $self->{pids} };

	# for enlightenment
	$self->debug("_stop=" . $session->ID);
	}

#	not currently handled by the session.  not sure how
#	to propagate

sub _default {
	my $heap = $_[HEAP];
	my $self = $heap->{self};
	$self->debug(qq/_default: "$_[ARG0]", args: @{$_[ARG1]}/);
	}

sub got_run {
	my ($kernel, $session, $self, $cmd) = @_[KERNEL, SESSION, ARG0, ARG1];

	# init stuff

	my $conduit = $self->{conduit};
	$self->{StdioFilter} ||= POE::Filter::Line->new(OutputLiteral => "\n");

	my $wheel = POE::Wheel::Run->new(
		Program		=> $cmd,
		StdioFilter	=> $self->{StdioFilter},
		StdoutEvent	=> "stdout",
		$conduit ? (Conduit => $conduit) : (StderrEvent => "stderr"),
		ErrorEvent	=> "error"
		);

	my $id = $wheel->ID;
	$self->debug(qq/run(): "@$cmd", wheel=$id, pid=/ . $wheel->PID);

	$self->{pids}{$wheel->PID} = $id;
	$self->{wheels}{$id}{cmd} = $cmd;
	$self->{wheels}{$id}{ref} = $wheel;
	$self->{wheels}{$id}{quit} = 0;
	$self->wheel($id);
	}

sub got_write {
	my ($self, $wheel, $args) = @_[ARG0 .. ARG2];
	$self->{wheels}{$wheel}{ref}->put(@$args);
	$self->debug(qq/got_write(): "/ . join(" ", @$args) . '"');
	}

sub got_kill {
	my ($self, $wheel) = @_[ARG0, ARG1];
	my $pid = $self->{wheels}{$wheel}{ref}->PID;
	CORE::kill 9, $pid;
	$self->debug("got_kill(): $pid");
	}

sub callback {
	my ($self, $event, $args) = @_;
	my $call = $self->{callbacks}{$event};
	ref($call) eq "CODE"
		? $call->($self, $args)
		: POE::Kernel->post($self->{alias}, $call, $self, $args)
		;
	}

sub stdio {
	my ($kernel, $heap, $event) = @_[KERNEL, HEAP, STATE];
	return unless $_[ARG0];

	my $self = $heap->{self};
	$self->callback($event, { out => $_[ARG0], wheel => $_[ARG1] });

	$self->debug(qq/$event(): "$_[ARG0]"/);
	}

*stdout = *stderr = *stdio;

#   these signals are issued by the OS and thus are sent to all
#   sessions.  any children this session owns will be stored in
#   the {pids} hash

sub sig_child {
    my ($kernel, $heap, $pid, $rc) = @_[KERNEL, HEAP, ARG1, ARG2];
	my $self = $heap->{self};
	my $sid = $_[SESSION]->ID;
	my $id = $self->{pids}{$pid} || "";

	return unless $id;	# handle only our own children

	# all expiring children should issue a "done" except when
	# the return code is non-zero which indicates a failure
	# if the caller asked we quit, fire a "done" regardless
	# of the child's return code value (we might have hard killed)

	my $event = ($self->{wheels}{$id}{quit} || $rc == 0) ? "done" : "died";
	$self->callback($event, { wheel => $id, rc => $rc });

	# clean up

	delete $self->{wheels}{$id}{ref};
	delete $self->{pids}{$id};

	$self->debug("sig_child(): session=$sid, wheel=$id, pid=$pid, rc=$rc");
	}

sub error {
	my ($kernel, $heap, $event) = @_[KERNEL, HEAP, STATE];
	my $args = {
		syscall	=> $_[ARG0],
		err		=> $_[ARG1],
		error	=> $_[ARG2],
		wheel	=> $_[ARG3],
		fh		=> $_[ARG4],
		};

	return if $args->{syscall} eq "read" && $args->{err} == 0;

	my $self = $heap->{self};
	$self->callback($event, $args);
	$self->debug("$event() [$args->{err}]: $args->{error}");
	}

# --- internal methods --------------------------------------------------------

sub debug {
	my $self = shift;
	return unless $self->{debug};
	local $\ = "\n"; print "> PoCo::Child:", join(" ", @_);
	}

1; # yipiness

__END__

=head1 NAME

POE::Component::Child - Child management component

=head1 SYNOPSIS

	use POE qw(Component::Child);

	$p = POE::Component::Child->new();
	$p->run("ls", "-alF", "/tmp");

	POE::Kernel->run();

=head1 DESCRIPTION

This POE component serves as a wrapper for POE::Wheel::Run, obviating the need to create a session to receive the events it dishes out.

=head1 METHODS

The module provides an object-oriented interface as follows: 

=head2 new [hash-ref]

Used to initialise the system and create a component instance.  The function may be passed either a hash or a reference to a hash.  The keys below are meaningful to the component, all others are passed to the provided callbacks.

=item alias

Indicates the name of a session to which module callbacks will be posted.  Default: C<main>.

=item callbacks

This hash reference contains mappings for the events the component will generate.  Callers can set these values to either event handler names (strings) or to callbacks (code references).  If names are given, the events are thrown at the I<alias> specified; when a code reference is given, it is called directly.  Allowable keys are listed below under section "Event Callbacks".

- I<exempli gratia> -

	$p = POE::Component::Child->new(
		alias => "my_session",
		callbacks => { stdout => "my_out", stderr => \&my_err }
		);

In the above example, any output produced by children on I<stdout> generates an event I<my_out> for the I<my_session> session, whilst output on I<stderr> causes a call to I<my_err()>.

=item quit

Indicates a string which should be sent to the child when attempting to quit.  This is only useful for interactive clients e.g. ftp, for whom either "bye" or "quit" will work.

=item conduit

If left unspecified, POE::Wheel::Run assumes "pipe".  Alternatively "pty" may be provided in which case no I<stderr> events will be fired.

=item debug

Setting this parameter to a true value generates debugging output (useful mostly to hacks).

=head2 run {array}

This method requires an array indicating the command (and optional parameters) to run.  The command and its parameters may also be passed as a single string.  The method returns the I<id> of the wheel which is needed when running several commands simultasneously.

Before calling this function, the caller may set stdio filter to a value of his choice.  The example below shows the default used.

I<$p-E<gt>{StdioFilter} = POE::Filter::Line-E<gt>new(OutputLiteral => '\n');>

=head2 write {array}

This method is used to send input to the child.  It can accept an array and will be passed through as such to the child.

=head2 quit [command]

This method requests that the client quit.  An optional I<command> string may be passed which is sent to the child - this is useful for graceful shutdown of interactive children e.g. the ftp command understands "bye" to quit.

If no I<command> is specified, the system will use whatever string was passed as the I<quit> argument to I<new()>.  If this too was left unspecified, a kill is issued.  Please note if the child is instructed to quit, it will not generate a I<died> event, but a I<done> instead (even when hard killed).

=head2 kill

Instructs the component to hard kill (-9) the child.  Note that the event generated is I<died> and not I<done>.

=head2 wheel

Used to set the current wheel for other methods to work with.  Please note that ->write(), ->quit() and ->kill() will work on the wheel most recently created.  I you wish to work with a previously created wheel, set it with this method.

=head1 EVENTS / CALLBACKS

Events are are thrown at the session indicated as I<alias> and may be specified using the I<callbacks> argument to the I<new()> method.  If no such preference is indicated, the default event names listed below are used.  Whenever callbacks are specified, they are called directly instead of generating an event.

Event handlers are passed two arguments: ARG0 which is a reference to the component instance being used (i.e. I<$self>), and ARG1, a hash reference containing the wheel id being used (as I<wheel>) + values specific to the event.  Callbacks are passed the same arguments but as @_[0,1] instead.

=head2 stdout

This event is fired upon any generation of output from the client.  The output produces is provided in C<out>, e.g.:

I<$_[ARG1]-E<gt>{out}>

=head2 stderr

Works exactly as with I<stdout> but for the error channel.

=head2 done

Fired upon termination of the child, including such cases as when the child is asked to quit or when it ends naturally (as with non-interactive children).

=head2 died

Fired upon abnormal ending of a child.  This event is generated only for interactive children who terminate without having been asked to.  Inclusion of the C<died> key in the C<callbacks> hash passed to I<new()> qualifies a process for receiving this event and distinguishes it as interactive.  This event is mutually exclusive with C<done>.

=head2 error

This event is fired upon generation of any error by the child.  Arguments passed include: I<syscall>, I<err> (the numeric value of the error), I<error> (a textual description), and I<fh> (the file handle involved).

=head1 AUTHOR

Erick Calder <ecalder@cpan.org>

=head1 ACKNOWLEDGEMENTS

1e6 thx pushed to Rocco Caputo for suggesting this needed putting together, for giving me the privilege to do it, and for all the late night help.

=head1 AVAILABILITY

This module may be found on the CPAN.  Additionally, both the module and its RPM package are available from:

F<http://perl.arix.com>

=head1 DATE

$Date: 2002/09/30 01:07:44 $

=head1 VERSION

$Revision: 1.16 $

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2002 Erick Calder. This product is distributed under the MIT License. A copy of this license was included in a file called LICENSE. If for some reason, this file was not included, please see F<http://www.opensource.org/licenses/mit-license.html> to obtain a copy of this license.
