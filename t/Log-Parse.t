# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Log-Parse.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use strict;
use Test::More tests => 112;
BEGIN { use_ok('Log::Parse') };

#########################

$ENV{PATH} = '/bin:/usr/bin:/usr/local/bin'; # needed because of taint mode
sub msg  { print "# @_\n" }
sub full {
    use File::Spec;
    File::Spec->rel2abs($_[0]);  # (tainted!)
} 
sub abbr {
    use Cwd;
    my $cwd = getcwd;
    $_[0] =~ m#^$cwd/(.*)# ? $1 : $_[0];
}

can_ok('Log::Parse', $_) foreach qw/new open read apply close
    _clear _read_into_buffer _load_scalar _save_scalar
    _load_resume_data _save_resume_data/;

# Test low-level subroutines
{
    my $value = 'whatever';
    my $file  = '/tmp/test/x';
    my $dir   = '/tmp/test';
    is(Log::Parse::_save_scalar($file, $value), 1,      '_save_scalar()');
    ok(-d $dir,                                         '_save_scalar() - created dir ok');
    ok(-f $file,                                        '_save_scalar() - created file ok');
    is(`cat "$file"`,                           $value, '_save_scalar() - file contains saved value');
    is(Log::Parse::_load_scalar($file),         $value, '_load_scalar()');
    system "rm -f $file";
    system "rmdir -p $dir 2>/dev/null";
}


# Test high-level methods
my $statefile;
my $obj;
my %opt;
my $file  = '/tmp/test_logfile';
my $dir;

system "echo 1a >$file";
system "echo 2b >>$file";

msg "setting options";
$dir = '';
%opt = (
    buffer_size    => 10,
    entry_callback => sub { join(':', @_) },
    entry_regex    => qr/^(.)(.)$/m,
    resume_dir     => '',
    );
isa_ok   ( $obj = Log::Parse->new(%opt), 'Log::Parse', 'new()');
is       ( $obj->{buffer_size},          10,           '  {buffer_size}');
isa_ok   ( $obj->{entry_callback},       'CODE',       '  {entry_callback}');
is       ( $obj->{entry_regex},          qr/^(.)(.)$/m,'  {entry_regex}');
is       ( $obj->{resume_dir},           '',           '  {resume_dir}');
is       ( $obj->{filename},             undef,        '  {filename}');
isnt     ( $obj->open($file),            undef,        'open() - numbered lines file');
$statefile ="$obj->{resume_dir}$obj->{filename}";
is_deeply([$obj->read()],              [ "1a\n",'1:a'],'read() 1st line' );
is_deeply([$obj->read()],              [ "2b\n",'2:b'],'read() 2nd line' );
is_deeply([$obj->read()],              [ ],            'read() at eof' );
isnt     ( $obj->close(),                undef,        'close()');
#for my $file ("$statefile.pos", "$statefile.1st") {
#    ok (!-f $file,  "  shan't exist: `".abbr($file)."'");
#}

msg "empty file";
system "echo -n >$file";
isa_ok   ( $obj = Log::Parse->new(),     'Log::Parse', 'new()');
isnt     ( $obj->open($file),            undef,        'open() - empty file');
is       ( $obj->read(),                 undef,        'read()');
is       ( $obj->read(),                 undef,        'read()');
isnt     ( $obj->close(),                undef,        'close()');

msg "open/close without resume";
system "echo 1a >$file";
system "echo 2b >>$file";
system "rm -fr $dir" if $dir; # remove statedir from last run
isa_ok   ( $obj = Log::Parse->new(),     'Log::Parse', 'new()');
is       ( $obj->{buffer_size},          1048576,      '  {buffer_size}');
isa_ok   ( $obj->{entry_callback},       'CODE',       '  {entry_callback}');
is       ( $obj->{entry_regex},          qr/^()/m,     '  {entry_regex}');
is       ( $obj->{resume_dir},           '',           '  {resume_dir}');
is       ( $obj->read(),                 undef,        '  read() before open()');
isnt     ( $obj->open($file),            undef,        'open() - numbered lines file');
$statefile ="$obj->{resume_dir}$obj->{filename}";
is       ( $obj->{filename},             full($file),  '  {filename} is absolute');
is       ( $obj->{_1st_entry},           "1a\n",       '  {_1st_entry}');
is       ( $obj->{position},             0,            '  {position} is zero');
is       ( $obj->read(),                 "1a\n",       'read() 1st line');
is       ( $obj->{_1st_entry},           "1a\n",       '  {_1st_entry}');
is       ( $obj->{position},             3,            '  {position}');
isnt     ( $obj->close(),                undef,        'close()');

msg "close() before eof and re-read";
is       ( $obj->{buffer_size},          1048576,      '  {buffer_size}');
isa_ok   ( $obj->{entry_callback},       'CODE',       '  {entry_callback}');
is       ( $obj->{entry_regex},          qr/^()/m,     '  {entry_regex}');
is       ( $obj->{resume_dir},           '',           '  {resume_dir}');
is       ( $obj->read(),                 undef,        '  read() before open()');
isnt     ( $obj->open($file),            undef,        'open() - numbered lines file');
is       ( $obj->{filename},             full($file),  '  {filename} is absolute');
is       ( $obj->{_1st_entry},           "1a\n",       '  {_1st_entry}');
is       ( $obj->{position},             0,            '  {position} is zero');
is       ( $obj->read(),                 "1a\n",       'read() 1st line');
is       ( $obj->{_1st_entry},           "1a\n",       '  {_1st_entry}');
is       ( $obj->{position},             3,            '  {position}');
is       ( $obj->read(),                 "2b\n",       'read() 2nd line');
is       ( $obj->{_1st_entry},           "1a\n",       '  {_1st_entry}');
is       ( $obj->{position},             6,            '  {position}');
is       ( $obj->read(),                 undef,        'read() at eof');
is       ( $obj->{_1st_entry},           "1a\n",       '  {_1st_entry}');
is       ( $obj->{position},             6,            '  {position}');
isnt     ( $obj->close(),                undef,        'close()');
#for my $file ("$statefile.pos", "$statefile.1st") {
#    ok (!-f $file,  "  shan't exist: `".abbr($file)."'");
#}

#print "buflen >>>".@{ $obj->{_buffer} },"\n";
#print ">>>$_<<<\n" foreach @{ $obj->{_buffer} };

#my $x = $obj->read();
#print "xx".$x;

msg "open/close with resume";
$dir = '/tmp/test_resume_dir';
system "echo 1a >$file";
system "echo 2b >>$file";

%opt   = (resume_dir => $dir);
isa_ok   ( $obj = Log::Parse->new(%opt), 'Log::Parse', 'new()');
is       ( $obj->{buffer_size},          1048576,      '  {buffer_size}');
isa_ok   ( $obj->{entry_callback},       'CODE',       '  {entry_callback}');
is       ( $obj->{entry_regex},          qr/^()/m,     '  {entry_regex}');
is       ( $obj->{resume_dir},           full($dir),   '  {resume_dir}');
isnt     ( $obj->open($file),            undef,        'open() - numbered lines file');
$statefile ="$obj->{resume_dir}$obj->{filename}";
is       ( $obj->{filename},             full($file),  '  {filename} is absolute');
is       ( $obj->{_1st_entry},           "1a\n",       '  {_1st_entry}');
is       ( $obj->{position},             0,            '  {position} is zero');
is_deeply([$obj->read()],              [ "1a\n", '' ], 'read() 1st line' );
is       ( $obj->{position},             3,            '  {position} increased');
isnt     ( $obj->close(),                undef,        'close()');
#is       (`cat "$statefile.pos"`,        3,            '  {position} savefile');
#is       (`cat "$statefile.1st"`,        "1a\n",       '  {_1st_entry} savefile');

msg "clobbering logfile";
system "echo 3c >$file";
system "echo 4d >>$file";
isa_ok   ( $obj = Log::Parse->new(%opt), 'Log::Parse', 'new() - object reinit -');
isnt     ( $obj->open($file),            undef,        'open()');
is       ( $obj->{filename},             full($file),  '  {filename} is absolute');
is       ( $obj->{_1st_entry},           "3c\n",       '  {_1st_entry}');
is       ( $obj->{position},             0,            '  {position} is zero');
is_deeply([$obj->read()],              [ "3c\n", '' ], 'read() 1st line' );
is       ( $obj->{position},             3,            '  {position} increased');
isnt     ( $obj->close(),                undef,        'close()');
#is       (`cat "$statefile.pos"`,        3,            '  {position} savefile');
#is       (`cat "$statefile.1st"`,        "3c\n",       '  {_1st_entry} savefile');

isa_ok   ( $obj = Log::Parse->new(%opt), 'Log::Parse', 'new() - object reinit -');
isnt     ( $obj->open($file),            undef,        'open()');
is       ( $obj->{filename},             full($file),  '  {filename} is absolute');
is       ( $obj->{_1st_entry},           "3c\n",       '  {_1st_entry}');
is       ( $obj->{position},             3,            '  {position} retained');
is_deeply([$obj->read()],              [ "4d\n", '' ], 'read() 2nd line' );
is       ( $obj->{position},             6,            '  {position} increased');
isnt     ( $obj->close(),                undef,        'close()');
#is       (`cat "$statefile.pos"`,        6,            '  {position} savefile');
#is       (`cat "$statefile.1st"`,        "3c\n",       '  {_1st_entry} savefile');

isa_ok   ( $obj = Log::Parse->new(%opt), 'Log::Parse', 'new() - object reinit -');
isnt     ( $obj->open($file),            undef,        'open()');
is       ( $obj->{filename},             full($file),  '  {filename} is absolute');
is       ( $obj->{_1st_entry},           "3c\n",       '  {_1st_entry}');
is       ( $obj->{position},             6,            '  {position} retained');
is_deeply([$obj->read()],              [ ],            'read() at eof' );
is       ( $obj->{position},             6,            '  {position} retained');
isnt     ( $obj->close(),                undef,        'close()');
#is       (`cat "$statefile.pos"`,        6,            '  {position} savefile');
#is       (`cat "$statefile.1st"`,        "3c\n",       '  {_1st_entry} savefile');

msg "added extra line to logfile `$file'";
system "echo '5e' >>$file"; # 

isa_ok   ( $obj = Log::Parse->new(%opt), 'Log::Parse', 'new() - object reinit -');
isnt     ( $obj->open($file),            undef,        'open()');
is       ( $obj->{filename},             full($file),  '  {filename} is absolute');
is       ( $obj->{_1st_entry},           "3c\n",       '  {_1st_entry}');
is       ( $obj->{position},             6,            '  {position} retained');
is_deeply([$obj->read()],              [ "5e\n", '' ], 'read() 2nd line' );
is       ( $obj->{position},             9,            '  {position} retained');
isnt     ( $obj->close(),                undef,        'close()');
#is       (`cat "$statefile.pos"`,        9,            '  {position} savefile');
#is       (`cat "$statefile.1st"`,        "3c\n",       '  {_1st_entry} savefile');

system "rm -f $file";
system "rm -fr $dir";

close STDERR;
is       ( $obj->open($file),            undef,        'open() - on non-existing file' );
is       ( $obj->close(),                undef,        '  close()');


# FIXME: need tests for reading standard input

#print "buflen >>>".@{ $obj->{_buffer} },"\n";
#print ">>>$_<<<\n" foreach @{ $obj->{_buffer} };

#[[eof]]
