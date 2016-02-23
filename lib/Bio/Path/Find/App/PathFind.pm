
package Bio::Path::Find::App::PathFind;

# ABSTRACT: find data for sequencing runs

use MooseX::App qw( Man BashCompletion Color );

use Path::Class;
use Text::CSV_XS;
use Try::Tiny;
use FileHandle;

use Types::Standard qw(
  ArrayRef
  Str
  Maybe
  Bool
  Int
  ClassName
);

use Bio::Path::Find::Types qw( :types );

use Bio::Path::Find::Lane;
use Bio::Path::Find::Finder;
use Bio::Path::Find::Exception;

with 'MooseX::Log::Log4perl',
     'Bio::Path::Find::Role::HasConfig',
     'Bio::Path::Find::Role::HasProgressBar';

# configure the app

# don't automatically run a guessed command; shows a "did you mean X" message
# instead
app_fuzzy 0;

# throw an exception if extra options or parameters are found on the command
# line
app_strict 1;

#-------------------------------------------------------------------------------

=head1 NAME

pf - Find data for sequencing runs

=head1 SYNOPSIS

  pf <command> --id <ID or file> --type <ID type> [options]

=head1 DESCRIPTION

The pathfind commands find and display various kinds of information about
sequencing projects.

Run "pf man" to see full documentation for this main "pf" command. Run "pf man
<command>" or "pf <command> --help" to see documentation for a particular
sub-command.

=head1 COMMANDS

These are the available commands:

=head2 accession

Finds accessions associated with lanes. The default behaviour is to list
the accessions, but the command can also show the URLs for retrieving
FASTQ files from the ENA FTP archive, or for retrieving the submitted
file from ENA.

=head2 annotation

Finds annotation data for lanes with assembled genomes. By default the
command returns the paths to the GFF files for each lane. You can also search
for lanes with specific genes or products. Equivalent to the original
C<annotationfind>.

=head2 assembly

Find genome assemblies. Lists assembly files, creates archives of or symbolic
links to assembly data files. Equivalent to the original C<assemblyfind>
command.

=head2 data

Shows information about the files and directories that are associated with
sequencing runs. Can also generate archives (tar or zip format) containing data
files for found lanes, or create symbolic links to data files. Equivalent to
the original C<pathfind> command.

=head2 info

Shows information about the samples associated with sequencing runs.
Equivalent to the original C<infofind> command.

=head2 status

Shows the status of lanes for various pathogen informatics pipelines.
Equivalent to the original C<statusfind> command.

=cut

=head1 COMMON OPTIONS

The following options can be used with all of the pathfind commands.

=head2 REQUIRED OPTIONS

All commands have two required options:

=over

=item --id, -i <ID or filename>

Specifies the ID for which to search. The ID can be given on the command line
using C<--id> or C<-i> or, if you have lots of IDs to find, they can be read
from a file or from STDIN. To read from file, set C<--id> to the name of the
file containing the IDs. To read IDs from STDIN, set C<-id> to C<->.

When reading from file or STDIN, C<--type> must be set to C<file> and you must
give the ID type using C<--file-id-type>.

=item --type, -t <type>

The type of ID(s) to look for, or C<file> to read IDs from a file. Type must
be one of C<lane>, C<library>, C<sample>, C<species>, C<study>, or C<file>.

=back

=head2 FURTHER OPTIONS

=over

=item --file-id-type, --ft <ID type>

Specify the type ID that is found in a file of IDs. Required when C<--type>
is set to C<file>.

=item --no-progress-bars, -N

Don't show progress bars.

The default behaviour is to show progress bars, except when running in a
non-interactive session, such as when called by a script.

=item --csv-separator, -c <separator>

When writing comma separated values (CSV) files (e.g. when writing statistics
using C<pf data>), use the specified string as a separator. Defaults to comma
(C<,>).

=item --force, -F

When writing files, you will see an error message if the output file already
exists. Add C<--force> to force C<pf> to silently overwrite any existing files.
Note that this will not affect the creation of symbolic links. Trying to create
links where the destination file or directory already exist will cause an error
or a warning.

=item --rename, -r

When creating archives of files or symbolic links to existing files, you can
rename the files in the archive or the names of the links, replacing hash
symbols (#) in the filename with underscores (_). This may be useful to make
the filename more portable and to avoid problems with systems that don't
handle hashes in filenames correctly.

B<Note> that C<--rename> only takes effect when archiving or linking.

=item --verbose, -v

Show debugging information.

=back

=cut

=head1 CONFIGURATION VIA ENVIRONMENT VARIABLES

You can set defaults for several options using environment variables. For
example, when using bash:

  export PF_NO_PROGRESS_BARS=1

or tcsh:

  setenv PF_NO_PROGRESS_BARS 1

Values set by environment variables will be overridden if the corresponding
option is given on the command line.

=over

=item PF_TYPE

Set a value for C<--type>. This can still be overridden using the C<--type>
command line option, but setting it avoids the need to add the flag if you
only ever search for one type of data.

=item PF_NO_PROGESS_BARS

Set to a true value to avoid showing progress bars, even when running
interactively. Corresponds to C<--no-progress-bars>.

=item PF_CSV_SEP

Set the separator to be used when writing comma separated values (CSV) files.
Corresponds to C<--csv-separator>.

=item PF_FORCE_OVERWRITE

Set to true to force existing files or links to be overwritten.

=item PF_VERBOSE

Set to a true value to show debugging information. Corresponds to C<--verbose>.

=back

=cut

#-------------------------------------------------------------------------------
#- common attributes -----------------------------------------------------------
#-------------------------------------------------------------------------------

# these are attributes that are common to all roles. Attributes that are
# specific to one particular application go in the concrete app class.

# the values of these attributes are taken from the command line options, which
# are set up by the "new_with_options" call that instantiates the *Find object
# in the main script, e.g. pathfind

option 'id' => (
  documentation => 'ID or name of file containing IDs',
  is            => 'rw',
  isa           => Str,
  cmd_aliases   => 'i',
  cmd_env       => 'PF_ID',
  required      => 1,
  trigger       => sub {
    my ( $self, $id ) = @_;
    ( my $renamed_id = $id ) =~ s/\#/_/g;
    $self->_renamed_id( $renamed_id );
  },
);

option 'type' => (
  documentation => 'ID type. Use "file" to read IDs from file',
  is            => 'rw',
  isa           => IDType,
  cmd_aliases   => 't',
  cmd_env       => 'PF_TYPE',
  required      => 1,
);

option 'file_id_type' => (
  documentation => 'type of IDs in the input file',
  is            => 'rw',
  isa           => FileIDType,
  cmd_flag      => 'file-id-type',
  cmd_aliases   => 'ft',
);

option 'csv_separator' => (
  documentation => 'field separator to use when writing CSV files',
  is            => 'rw',
  isa           => Str,
  cmd_flag      => 'csv-separator',
  cmd_aliases   => 'c',
  cmd_env       => 'PF_CSV_SEP',
  default       => ',',
);

option 'no_progress_bars' => (
  documentation => "don't show progress bars",
  is            => 'ro',
  isa           => Bool,
  cmd_flag      => 'no-progress-bars',
  cmd_aliases   => 'N',
  cmd_env       => 'PF_NO_PROGRESS_BARS',
  trigger       => sub {
    my ( $self, $flag ) = @_;
    # set a flag on the config object to tell interested objects whether they
    # should show progress bars when doing work
    $self->config->{no_progress_bars} = $flag;
  },
);

option 'rename' => (
  documentation => 'replace hash (#) with underscore (_) in filenames',
  is            => 'rw',
  isa           => Bool,
  cmd_aliases   => 'r',
);

option 'force' => (
  documentation => 'force commands to overwrite existing files',
  is            => 'ro',
  isa           => Bool,
  cmd_aliases   => 'F',
  cmd_env       => 'PF_FORCE_OVERWRITE',
  default       => 0,
);

option 'verbose' => (
  documentation => 'show debugging messages',
  is            => 'rw',
  isa           => Int,
  cmd_count     => 1,
  cmd_aliases   => 'v',
  cmd_env       => 'PF_VERBOSE',
  default       => 0,
);

#-------------------------------------------------------------------------------
#- private attributes ----------------------------------------------------------
#-------------------------------------------------------------------------------

# these are just internal slots to hold the real list of IDs and the correct
# ID type, after we've worked out what the user is handing us by examining the
# input parameters in "sub BUILD"
has '_ids' => (  is => 'rw', isa => ArrayRef[Str] );
has '_type' => ( is => 'rw', isa => IDType );

#---------------------------------------

# define the configuration for the Log::Log4perl logger

has '_logger_config' => (
  is      => 'ro',
  isa     => 'Ref',
  lazy    => 1,
  builder => '_build_logger_config',
);

sub _build_logger_config {
  my $self = shift;

  my $LEVEL = $self->verbose ? 'DEBUG' : 'WARN';

  my $config_string = qq(

    # appenders

    log4perl.appender.Screen                           = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.layout                    = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Screen.layout.ConversionPattern  = %M:%L %p: %m%n

    # loggers

    # set log levels for individual classes
    log4perl.logger.Bio.Path.Find.App.TestFind         = $LEVEL, Screen
    log4perl.logger.Bio.Path.Find.App.PathFind         = $LEVEL, Screen
    log4perl.logger.Bio.Path.Find.Finder               = $LEVEL, Screen
    log4perl.logger.Bio.Path.Find.Lane                 = $LEVEL, Screen
    log4perl.logger.Bio.Path.Find.DatabaseManager      = $LEVEL, Screen

    log4perl.oneMessagePerAppender                     = 1
  );

  return \$config_string;
}

#---------------------------------------

# this is the name of the class of lane object that should be returned by the
# finder. The builder method on this parent class returns the name of the
# parent Lane class, so by default Lanes won't have any command-specific
# functionality. Command classes, like B::P::F::A::P::Data, should override the
# builder and make it return the name of the lane class that they want returned
# e.g. Bio::Path::Find::Lane::Data

has '_lane_class' => (
  is      => 'ro',
  isa     => ClassName,
  lazy    => 1,
  builder => '_build_lane_class',
);

sub _build_lane_class {
  return 'Bio::Path::Find::Lane';
}

#---------------------------------------

has '_finder' => (
  is      => 'ro',
  isa     => BioPathFindFinder,
  lazy    => 1,
  builder => '_build_finder',
);

sub _build_finder {
  my $self = shift;

  return Bio::Path::Find::Finder->new( lane_class => $self->_lane_class );
}

#---------------------------------------

# a slot to store the ID, but with hashes converted to underscores. Written by
# a trigger on the "id" attribute

has '_renamed_id' => (
  is => 'rw',
  isa => Str,
);

#-------------------------------------------------------------------------------
#- construction ----------------------------------------------------------------
#-------------------------------------------------------------------------------

sub BUILD {
  my $self = shift;

  # initialise the logger
  Log::Log4perl->init_once($self->_logger_config);

  $self->log->debug('verbose logging is on');
  # (should only appear when "-verbose" is used)

  # if "-verbose" is used multiple times, turn on DBIC query logging too
  $ENV{DBIC_TRACE} = 1 if $self->verbose > 1;

  # check for dependencies between parameters: if "type" is "file", we need to
  # know what type of IDs we'll find in the file
  Bio::Path::Find::Exception->throw( msg => q(ERROR: if "type" is "file", you must also specify "file_id_type") )
    if ( $self->type eq 'file' and not $self->file_id_type );

  # look at the input parameters and decide whether we're dealing with a single
  # ID or many, and what the type of the ID(s) is/are
  my ( $ids, $type );

  if ( $self->type eq 'file' ) {

    $type = $self->file_id_type;

    if ( $self->id eq '-' ) {
      # read IDs from STDIN
      while ( <STDIN> ) {
        chomp;
        push @$ids, $_;
      }
      $self->log->debug('found ' . scalar @$ids . qq( IDs from STDIN)
                        . qq(, of type "$type") );
    }
    else {
      # read multiple IDs from a file
      $ids  = $self->_load_ids_from_file( file($self->id) );
      $self->log->debug('found ' . scalar @$ids . qq( IDs from file "$ids")
                        . qq(, of type "$type") );
    }
  }
  else {
    # use the single ID from the command line
    $ids  = [ $self->id ];
    $type = $self->type;

    $self->log->debug( qq(looking for single ID, "$ids->[0]", of type "$type") );
  }

  $self->_ids($ids);
  $self->_type($type);
}

#-------------------------------------------------------------------------------
#- private methods -------------------------------------------------------------
#-------------------------------------------------------------------------------

# reads a list of IDs from the supplied filename. Treats lines beginning with
# hash (#) as comments and ignores them

sub _load_ids_from_file {
  my ( $self, $filename ) = @_;

  Bio::Path::Find::Exception->throw( msg => "ERROR: no such file ($filename)" )
    unless -f $filename;

  # TODO check if this will work with the expected usage. If users are used
  # TODO to putting plex IDs as search terms, stripping lines starting with
  # TODO "#" will break those searches
  my @ids = grep ! m/^#/, $filename->slurp(chomp => 1);

  Bio::Path::Find::Exception->throw( msg => "ERROR: no IDs found in file ($filename)" )
    unless scalar @ids;

  return \@ids;
}

#-------------------------------------------------------------------------------

# generates a new filename by converting hashes to underscores in the supplied
# filename. Also converts the filename to unix format, for use with tar and
# zip

sub _rename_file {
  my ( $self, $old_filename ) = @_;

  my $new_basename = $old_filename->basename;

  # honour the "-rename" option
  $new_basename =~ s/\#/_/g if $self->rename;

  # add on the folder to get the relative path for the file in the
  # archive
  ( my $folder_name = $self->id ) =~ s/\#/_/g;

  my $new_filename = file( $folder_name, $new_basename );

  # filenames in an archive are specified as Unix paths (see
  # https://metacpan.org/pod/Archive::Tar#tar-rename-file-new_name)
  $old_filename = file( $old_filename )->as_foreign('Unix');
  $new_filename = file( $new_filename )->as_foreign('Unix');

  $self->log->debug( "renaming |$old_filename| to |$new_filename|" );

  return $new_filename;
}

#-------------------------------------------------------------------------------

# modifier for methods that write to file. Takes care of validating arguments
# and opening a filehandle for writing

around [ '_write_csv', '_write_list' ] => sub {
  my $orig = shift;
  my $self = shift;
  my ( $data, $filename ) = @_;

  Bio::Path::Find::Exception->throw( msg => 'ERROR: must supply some data when writing a file' )
   unless ( defined $data and scalar @$data );

  Bio::Path::Find::Exception->throw( msg => 'ERROR: must supply a filename when writing a file' )
    unless defined $filename;

  # see if the supplied filename exists and complain if it does
  if ( -e $filename and not $self->force ) {
    Bio::Path::Find::Exception->throw(
      msg => qq(ERROR: output file "$filename" already exists; not overwriting existing file. Use "-F" to force overwriting)
    );
  }

  my $fh = FileHandle->new;

  $fh->open( $filename, '>' );

  # run the original "write_X" method
  $self->$orig( $data, $fh );

  $fh->close;
};

#-------------------------------------------------------------------------------

# writes the supplied array of arrays in CSV format to the specified file.
# Uses the separator specified by the "csv_separator" attribute

sub _write_csv {
  my ( $self, $data, $fh ) = @_;

  my $csv = Text::CSV_XS->new;
  $csv->eol("\n");
  $csv->sep( $self->csv_separator );
  $csv->print($fh, $_) for @$data;
}

#-------------------------------------------------------------------------------

sub _write_list {
  my ( $self, $data, $fh ) = @_;

  print $fh "$_\n" for @$data;
}

#-------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

1;

