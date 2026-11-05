# Loads the Now Playing bridge into Apple's signed perl, which is still
# allowed to read MediaRemote on modern macOS. Talks JSON lines over stdio.
use strict;
use DynaLoader;
my $lib = shift @ARGV or die "usage: run.pl <libbridge.dylib>";
my $h = DynaLoader::dl_load_file($lib, 0) or die DynaLoader::dl_error();
my $s = DynaLoader::dl_find_symbol($h, "dia_run") or die DynaLoader::dl_error();
my $x = DynaLoader::dl_install_xsub("main::dia_run", $s);
&$x();
