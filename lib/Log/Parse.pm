package Log::Parse;

use 5.008008;
use strict;
use warnings;
use Carp;

use vars qw($VERSION); # FIXME: why this line?
our $VERSION = '0.04';

=head1 NAME

Log::Parse - Parse log files incrementally, extracting dates/times

=head1 SYNOPSIS

    our %month = (
        Jan => 0,  Feb => 1,  Mar => 2,  Apr => 3,  May =>  4,  Jun =>  5,
        Jul => 6,  Aug => 7,  Sep => 8,  Oct => 9,  Nov => 10,  Dec => 11,
    );
    my $month_re = join('|', keys %month);
    my $log = Log::Parse->new(
        resume_dir     => '/some/dir',
        entry_regex    => qr/^($month_re) (\d+) (\d+):(\d+):(\d+)\b/m,
        entry_callback => sub {
            use Time::Local;
            my ($year) = (localtime)[5];
            return reverse($year, $month{shift}, @_);
        },
    );
    $log->open('/var/log/messages');
    while (my ($entry, @epoch) = $log->read()) {
	print "$epoch:$entry";
    }
    $log->close();

The above should parse your '/var/log/messages', outputting each log
event preceded by its time in epoch. YMMV, though (depending on log
format).


=head1 DESCRIPTION

Simple log parser.

It has a couple of benefits over other log parsers.

=over 4

=item Support for multiple line log entries.

=item Automatic extraction/processing of time (or other) info.

=item Incremental reading mode (for "tail -f"-similar operation).

=back


=head2 EXPORT

Nothing is exported by default. As should be, with an object-oriented
module.


=head1 METHODS


=over 8

=item $obj = new(
B<buffer_size> => I<1048576>,
B<entry_callback> => I<sub { @_ }>,
B<entry_regex> => I<qr/^/m>,
B<resume_dir> => 'PATH' );

B<entry_regex> a regular expression defining the start of a log entry
(e.g. B<qr/^/m> to match beginning of all lines).

B<entry_callback> reference to a callback function. Function will be
called for each entry with all parenthesized subexpressions in
B<entry_regex> as arguments. (If calling B<read()> in list context you
automatically the return value for each read log entry.)
B<entry_callback> defaults to C<sub { @_ }> (returning all
subexpressions as-is). It is chiefly ment to convert a datestamp in
the entry header to some more usable format (like epoch time).

B<buffer_size> is the size of the chunks in which the logfile is read.
Defaults to 1Mb. May increase/decrease performance, but should have no
other effect.

If B<resume_dir> is specified, this directory will be used to store
the data necessary for each input file (first log entry + byte offset)
to resume reading of any updated files, instead of reading them from
the beginning, the next time Log::Parse.

The basename (excluding path) and the first log entry of the input
file is used to identify it when resuming. This is intentional, and
means that it is a simple thing to feed Log::Parse, logfiles as
they're being produced, as well as any previously made incrementally
made backups of logfiles.

Log::Parse never look at the filedate, only at the first log entry (to
uniquely identify a file -- if the first entry has changed, the file
is assumed to have been overwritten and is read from the beginning).
If the first logentry is unchanged, parsing continues from the offset
where was Log::Parse when file was last close()d.

=cut

sub new {
    my ($class, %arg) = @_;
    # some default values
    use File::Spec;
    my $me = {                                                                       # default
	buffer_size    => exists $arg{buffer_size}    ? $arg{buffer_size}    : 1048576,    # 1Mb
        entry_callback => exists $arg{entry_callback} ? $arg{entry_callback} : sub { @_ }, # as-is
        entry_regex    => exists $arg{entry_regex}    ? $arg{entry_regex}    : qr/^()/m,   # newline
	resume_dir     => exists $arg{resume_dir}     ? do {                               # no state
	    my $dir = defined($arg{resume_dir}) ? $arg{resume_dir} : '';                   #   save
	    ($dir)  = File::Spec->rel2abs($dir) =~ /^(.*)$/
		unless $dir eq '';
	    $dir;
	} : '',
    };
    bless($me, $class);
    $me->_clear();
    return $me;
}

sub _clear {
    my ($me) = @_;
    $me->{_1st_entry}     = '';
    $me->{_buffer}        = [];
    $me->{_callback_args} = [];
    $me->{_filehandle}    = undef;
    $me->{filename}       = undef;
    $me->{position}       = 0;
}

=item $offset = $obj->open($file);

Opens a new logfile (or, if $file is set to `-', standard input) for reading
(use `./-' if you want to open a file literally called `-'). If in resume mode
(see B<new()>), B<resume_dir> is set, and file has not been overwritten since
last read, reading will continue reading where it last left off (similar to
"tail -f").

Returns the undef on error ($! is set to whatever sysopen set it to, so check
there for failure reason) or otherwise the offset at which reading will begin.
If file is to be read from the beginning it returns "0 but true" (This string is
true in boolean context and 0 in numeric context. It is also exempt from the
normal B<-w> warnings on improper numeric conversions.)

=cut

sub open {
    my ($me, $file) = @_;
    defined($me->{_filehandle}) and $me->close();
    if (defined($file) and $file ne '-') {  # open a file
	# make file absolute path
	use File::Spec;
	($file) = File::Spec->rel2abs($file) =~ /^(.*)$/;
	$me->{filename} = $file;
	$me->_load_resume_data();
	use Fcntl 'O_RDONLY';
	defined(sysopen $me->{_filehandle}, $me->{filename}, O_RDONLY) or do {
	    $me->{_filehandle} = undef;
	    return undef;
	};
	$me->_read_into_buffer();               # read 1st chunk into buffer
	if ($me->{position} > 0 and @{$me->{_buffer}} and
	    $me->{_1st_entry}   eq  ${$me->{_buffer}}[0]) {
	    # This is the same file as last time (i.e. the 1st entry
	    # is unmodified) and _load_resume_data() above set
	    # {position} to a positive value, indicating that this is
	    # a resumed read. Thus we seek forward in file here.
	    defined(sysseek $me->{_filehandle}, $me->{position}, 0) or
		croak "Failed to seek to byte $me->{position} in file " .
		    "`$me->{filename}': $!";
	    $me->{_buffer} = [];
	    $me->_read_into_buffer();
	} else {
	    $me->{_1st_entry} = ${$me->{_buffer}}[0];   # store 1st entry
	    $me->{position}   = 0;
	}
    } else {                  # open standard input
	# FIXME: test this some more
	if (-t STDIN) {
	    carp "Cannot read standard input: Not connected to pipe";
	    return undef;
	}
	$me->{filename}    = '';
	$me->{_filehandle} = *STDIN;
	# FIXME: add seeking by reading past stuff
	# (but under what filename should the STDIN be saved under in resume dir?)
	if ($me->{resume_dir}) {
	    carp "Cannot do resumed read: Seek not possible on standard input";
	    $me->{resume_dir} = '';
	}
	$me->_read_into_buffer();               # read 1st chunk into buffer
	$me->{_1st_entry} = ${$me->{_buffer}}[0];   # store 1st entry
	$me->{position}   = 0;
    }
    unshift @{ $me->{_buffer} }, '';
    return $me->{position} == 0 ? '0 but true' : $me->{position};
}


=item $obj->read();

Much as the built-in "readline", but returns a (possibly multi-line)
log event in each read.

In list context, returns a list where the first element is the read
log entry, and the subsequent elements are whatever (list) was
returned by the B<entry_callback> function. When end-of-file is
reached the empty list () is returned.

In scalar context, returns the log entry as read from file, or undef
if end-of-file is reached. (In scalar context the B<entry_callback> is
never called.)

=cut

sub read {
    my ($me) = @_;                              #
    shift @{ $me->{_buffer}  };                 # remove 1st entry in buffer
    return wantarray ? () : undef               #
	if @{ $me->{_buffer} } == 0;            # empty buffer
    $me->_read_into_buffer();
    $me->{position} += length(${ $me->{_buffer} }[0]);
    return $me->apply;
}


sub _read_into_buffer {
    my ($me) = @_;
    while (@{ $me->{_buffer} } <= 1) {          # while buffer is only one entry
	my $length =                            #   read a chunk into $_
	    sysread $me->{_filehandle}, $_, $me->{buffer_size};
	!defined($length) and croak "Cannot read logfile `$me->{filename}': $!";
	$length == 0 and last;                  #   eof: stop
	$_ = pop(@{ $me->{_buffer} }) . $_      #   add old buffer content to $_
	    if @{ $me->{_buffer} };             #   add old buffer content to $_
	my $last = 0;                           #
	pos()    = 1;                           #
	while (/$me->{entry_regex}/gc) {        #   split $_ into entries
	    push @{ $me->{_buffer} },           #     and push them onto buffer
	        substr($_, $last, $-[0]-$last); #
	    $last = $-[0];                      #
	}                                       #
	push @{ $me->{_buffer} },               #   put remaining $_ into buffer
	    substr($_, $last);                  #     as well
    }                                           #
}                                               #


sub _load_scalar {
    my ($file, $default_value) = @_;
    local $/;
    return $default_value unless -e $file;
    CORE::open my $fh, '<', $file or croak "Failed to open state file `$file' for reading: $!";
    defined(my $data = <$fh>)     or croak "Failed to read from state file `$file': $!";
    close $fh                     or croak "Failed to close state file `$file' after reading: $!";
    return $data;
}

sub _save_scalar {
    my ($file, $data) = @_;
    (my $dir  = $file) =~ s{/[^/]+$}{};
    if (not -d $dir) {
	# FIXME: use perl internal recursive mkdir?
	$ENV{PATH} = '/bin:/usr/bin:/usr/local/bin';
	!system('mkdir', '-p', $dir) or
	    croak "Failed to create directory `$dir' for state file";
    }
    CORE::open my $fh, '>', $file or croak "Failed to open state file `$file' for writing: $!";
    # FIXME: Use of uninitialized value in print at /usr/local/share/perl/5.8.8/Log/Parse.pm line 268.
    print $fh $data               or croak "Failed to write to state file `$file': $!";
    close $fh                     or croak "Failed to close state file `$file' after writing: $!";
    return 1;
}


# Usage: $obj->_load_resume_data($file);
# gaga.1st + gaga.pos
sub _load_resume_data {
    my ($me) = @_;
    if ($me->{filename} ne '' and $me->{resume_dir} ne '') {
	# filename must be absolute path
	my ($file) = $me->{filename} =~ m{^.*/([^/]*)$};
	$file      = "$me->{resume_dir}/$file";
	#my $file = $me->{resume_dir} . $me->{filename};
	$me->{position}   = _load_scalar("$file.pos",  0);
	$me->{_1st_entry} = _load_scalar("$file.1st", '');
	return 1;
    }
    $me->{position}   =  0;
    $me->{_1st_entry} = '';
}

sub _save_resume_data {
    my ($me) = @_;
    if ($me->{resume_dir}) {
	my ($file) = $me->{filename} =~ m{^.*/([^/]*)$};
	$file      = "$me->{resume_dir}/$file";
	#my $file = $me->{resume_dir} . $me->{filename};
	_save_scalar("$file.pos", $me->{position});
	_save_scalar("$file.1st", $me->{_1st_entry});
	return 1;
    }
}


=item $obj->close();

Close the file. Closing a file causes the C<resume_dir> files to be
written. Any previously opened files is automatically B<close()>d when
you B<open()> a new one -- but make sure that you close your last file
before exiting, or you will lose the B<resume_dir> data for that file!

Returns true if file was successfully closed, false otherwise. If close()
returned false $! is set.

=cut

sub close {
    my ($me) = @_;
    # Avoid "Can't use an undefined value as a symbol reference" error by
    # emulating what happens if you try to close a non-existing filehandle.
    if (not defined $me->{_filehandle}) {       # no filehandle defined
	use Errno 'EBADF';                      #   see errno(3)
	$! = EBADF;                             #   $! = "Bad file descriptor"
	return '';                              #   return false
    }                                           #
    my $ret   = close($me->{_filehandle});      # close
    my $errno = $!;                             # remember close ERRNO
    if (defined($ret) && $ret ne '') {          # if close worked
	$me->_save_resume_data();               #   save resume data
    }                                           #
    $me->_clear();                              # clear variables
    $! = $errno;                                # restore close ERRNO
    return $ret;                                #
}                                               #


=item $obj->position();

Returns the position where the next read() will start in the currently open
file. If at the beginning of the file returns "0 but true" (This string is true
in boolean context and 0 in numeric context. It is also exempt from the normal
B<-w> warnings on improper numeric conversions.)

Returns false (empty string) If no file is currently open.

FIXME: Is position returned in bytes or in characters?

=cut

sub position {
    my ($me) = @_;
    return '' unless defined($me->{_filehandle});
    return $me->{position} == 0 ? '0 but true' : $me->{position};
}


=item $obj->apply();

FIXME.

=cut

sub apply {
    my ($me) = @_;
    if (wantarray) {
	my      $entry = ${ $me->{_buffer} }[0];
        return ($entry,  &{ $me->{entry_callback} }($entry =~ /$me->{entry_regex}/));
    } else {
        return ${ $me->{_buffer} }[0];
    }
}

1;
__END__

=head1 SEE ALSO

I found the following guide on how to make Perl modules very helpful
when writing this:

http://world.std.com/~swmcd/steven/perl/module_mechanics.html

My tiny page of programs will probably contain this module (and do
contain some other interesting tidbits and programs):

http://www.update.uu.se/~zrajm/programs/


=head1 AUTHOR

Zrajm, E<lt>log-parse-mail@klingonska.orgE<gt>. Suggestions are much
welcome, and, as long as any changes are good and sound, and don't
break backward compatibility, sending me modified sources is the
quickest way to get your suggestions included. :) Don't forget to
include tests, if you write new code! (Come to think of it, improved
tests for my own code would also be greatly appreciated.)

I'm pretty new to the object-oriented Perl game, as well as to unit
testing, so suggestions for improvement in those two areas are
especially welcome!


=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by zrajm.

This Perl module is published under a Creative Commons
Attribution-Share Alike 3.0 license. See:
[http://creativecommons.org/licenses/by-sa/3.0/]

=cut

#[[eof]]
