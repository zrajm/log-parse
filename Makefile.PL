use 5.008008;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

# make list of executables in bin/
my @exe_file = ();
if (open my $in, 'MANIFEST') {
    @exe_file = grep {
	chomp;
	m{^bin/} and -x $_;
    } <$in>;
}

WriteMakefile(
    NAME              => 'Log::Parse',
    VERSION_FROM      => 'lib/Log/Parse.pm', # finds $VERSION
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/Log/Parse.pm', # retrieve abstract from module
       AUTHOR         => 'Zrajm <zrajm@klingonska.org>') : ()),
    EXE_FILES         => [ @exe_file ],
);
