
package Bio::Path::Find::App::PathFind::Annotation;

# ABSTRACT: find annotation results

use v5.10; # for "say"

use MooseX::App::Command;
use namespace::autoclean;
use MooseX::StrictConstructor;

use Carp qw( croak );
use Path::Class;
use Capture::Tiny qw( capture_stderr );

use Types::Standard qw(
  ArrayRef
  Bool
  Str
);

use Bio::Path::Find::Types qw( :types );

use Bio::Path::Find::Exception;
use Bio::Path::Find::Lane::Class::Annotation;

use Bio::AutomatedAnnotation::ParseGenesFromGFFs;

extends 'Bio::Path::Find::App::PathFind';

with 'Bio::Path::Find::Role::Linker',
     'Bio::Path::Find::Role::Archivist',
     'Bio::Path::Find::Role::Statistician';

#-------------------------------------------------------------------------------
#- usage text ------------------------------------------------------------------
#-------------------------------------------------------------------------------

# this is used when the "pf" app class builds the list of available commands
command_short_description 'Find annotation results';

=head1 NAME

pf annotation - Find annotations for assemblies

=head1 USAGE

  pf annotation --id <id> --type <ID type> [options]

=head1 DESCRIPTION

The C<annotation> command finds annotations for assembled genomes. Search for
lanes with annotation using the C<--type>
option (C<lane>, C<sample>, etc), and the ID, using the C<--id> option. If
a lane has multiple assemblies from different pipelines, you can restrict
results to those generated by a specific assembler using C<--program>. Get
information on specific genes/products using the C<--gene> or C<--product>
options.

=head1 EXAMPLES

  # find GFFs files for lanes
  pf annotation -t lane -i 12345_1



  # get paths for scaffolds for a set of lanes
  pf assembly -t lane -i 12345_1
  pf assembly -t lane -i 12345_1 -f scaffold

  # get contigs for a set of lanes
  pf assembly -t lane -i 12345_1 -f contigs

  # get both contigs and scaffold for a set of lanes
  pf assembly -t lane -i 12345_1 -f all

  # get scaffolds for only IVA assemblies
  pf assembly -t lane -i 12345_1 -p iva

  # write statistics for the assemblies to a CSV file
  pf assembly -t lane -i 12345_1 -s my_assembly_stats.csv

  # archive contigs in a gzip-compressed tar file
  pf assembly -t lane -i 10018_1 -a my_contigs.tar.gz

=head1 OPTIONS

These are the options that are specific to C<pf assembly>. Run C<pf man> to see
information about the options that are common to all C<pf> commands.

=over

=item --program, -p <assembler>

Restrict search to files generated by a specific assembler. Must be one of
C<iva>, C<pacbio>, C<spades>, or C<velvet>. Default: return files from all
assembly pipelines.

=item --filetype, -f <filetype>

Type of assembly files to find. Either C<scaffold> (default) or C<contigs>.

=item --stats, -s [<stats filename>]

Write a file with statistics about found lanes. Save to specified filename,
if given. Default filename: <ID>_assemblyfind_stats.csv

=item --symlink, -l [<symlink directory>]

Create symlinks to found data. Create links in the specified directory, if
given, or in the current working directory by default.

=item --archive, -a [<tar filename>]

Create a tar archive containing data files for found lanes. Save to specified
filename, if given. Default filename: assemblyfind_<ID>.tar.gz

=item --no-tar-compression, -u

Don't compress tar archives.

=item --zip, -z [<zip filename>]

Create a zip archive containing data files for found lanes. Save to specified
filename, if given. Default filename: assemblyfind_<ID>.zip

=item --rename, -r

Rename filenames when creating archives or symlinks, replacing hashed (#)
with underscores (_).

=back

=head1 SCENARIOS

=head2 Find assemblies

The C<pf assembly> command finds and prints the locations of scaffolds by
default:

  % pf assembly -t lane -i 5008_5#1

You can also find contigs for an assembly:

  % pf assembly -t lane -i 5008_5#1 -f contigs

If you want to see both scaffolds and contigs for each assembly:

  % pf assembly -t lane -i 5008_5#1 -f all

=head2 Find assemblies from a particular pipeline

If reads from a given lane have been assembled by multiple assemblies, for
example by both IVA and SPAdes, the default behaviour is to return either
contigs or scaffolds from both assemblies. If you are interested in the
results of a particular assembler, you can specify it using the C<--program>
options:

  % pf assembly -t lane -i 5008_5#1 --program iva

=head2 Get statistics for an assembly

You can generate a file with the statistics for an assembly using the
C<--stats> option:

  % pf assembly -t lane -i 5008_5#1 --stats

You can specify the name of the stats file by adding to the C<-s> option:

  % pf assembly -t lane -i 5008_5#1 -s my_assembly_stats.csv

You can also write the statistics as a more readable tab-separated file:

  pf accession -t lane -i 10018_1 -o -c "<tab>"

(To enter a tab character you might need to press ctrl-V followed by tab.)

=cut

#-------------------------------------------------------------------------------
#- command line options --------------------------------------------------------
#-------------------------------------------------------------------------------

option 'filetype' => (
  documentation => 'type of files to find',
  is            => 'ro',
  isa           => AnnotationType,
  cmd_aliases   => 'f',
  # default       => 'gff',
  # don't specify a default here; it screws up the gene finding method
);

#---------------------------------------

option 'gene' => (
  documentation => 'gene name',
  is            => 'ro',
  isa           => Str,
  cmd_aliases   => 'g',
);

#---------------------------------------

option 'product' => (
  documentation => 'product name',
  is            => 'ro',
  isa           => Str,
  cmd_aliases   => 'p',
);

#---------------------------------------

option 'output' => (
  documentation => 'output filename for genes',
  is            => 'ro',
  isa           => Str,
  cmd_aliases   => 'o',
);

#---------------------------------------

option 'nucleotides' => (
  documentation => 'output nucleotide sequence instead of protein sequence',
  is            => 'ro',
  isa           => Bool,
  cmd_aliases   => 'n',
);

#---------------------------------------

option 'program' => (
  documentation => 'look for annotation created by a specific assembly pipeline',
  is            => 'ro',
  isa           => Assemblers,
  cmd_aliases   => 'P',
  cmd_split     => qr/,/,
);

#-------------------------------------------------------------------------------
#- private attributes ----------------------------------------------------------
#-------------------------------------------------------------------------------

# this is a builder for the "_lane_class" attribute that's defined on the
# parent class, B::P::F::A::PathFind. The return value specifies the class of
# the B::P::F::Lane objects that should be returned by the Finder.

sub _build_lane_class {
  return 'Bio::Path::Find::Lane::Class::Annotation';
}

#---------------------------------------

# this is a builder for the "_stats_file" attribute that's defined by the
# B::P::F::Role::Statistician. This attribute provides the default name of the
# stats file that the command writes out

sub _build_stats_file {
  my $self = shift;
  return file( $self->_renamed_id . '.annotationfind_stats.csv' );
}

#---------------------------------------

# set the default name for the symlink directory

around '_build_symlink_dir' => sub {
  my $orig = shift;
  my $self = shift;

  my $dir = $self->$orig->stringify;
  $dir =~ s/^pf_/assemblyfind_/;

  return dir( $dir );
};

#---------------------------------------

# set the default names for the tar or zip files

around [ '_build_tar_filename', '_build_zip_filename' ] => sub {
  my $orig = shift;
  my $self = shift;

  my $filename = $self->$orig->stringify;
  $filename =~ s/^pf_/annotationfind_/;

  return file( $filename );
};

#---------------------------------------

# these are the sub-directories of a lane's data directory where we will look
# for annotation files

has '_subdirs' => (
  is => 'ro',
  isa => ArrayRef[PathClassDir],
  builder => '_build_subdirs',
);

sub _build_subdirs {
  return [
    dir(qw( iva_assembly annotation )),
    dir(qw( spades_assembly annotation )),
    dir(qw( velvet_assembly annotation )),
    dir(qw( pacbio_assembly annotation )),
  ];
}

#-------------------------------------------------------------------------------
#- public methods --------------------------------------------------------------
#-------------------------------------------------------------------------------

sub run {
  my $self = shift;

  # TODO fail fast if we're going to end up overwriting a file later on

  # set up the finder

  # build the parameters for the finder
  my %finder_params = (
    ids      => $self->_ids,
    type     => $self->_type,
    filetype => $self->filetype || 'gff',
    subdirs  => $self->_subdirs,
  );

  # tell the finder to set "search_depth" to 3 for the Lane objects that it
  # returns. The files that we want to find using Lane::find_files are in the
  # sub-directory containing assembly information, so the default search depth
  # of 1 will miss them.
  $finder_params{lane_attributes}->{search_depth}    = 3;

  # make Lanes store found files as simple strings, rather than
  # Path::Class::File objects. The list of files is handed off to
  # Bio::AutomatedAnnotation::ParseGenesFromGFFs, which spits the dummy if it's
  # handed objects.
  $finder_params{lane_attributes}->{store_filenames} = 1;

  # should we restrict the search to a specific assembler ?
  if ( $self->program ) {
    # yes; tell the Finder to set the "assemblers" attribute on every Lane that
    # it returns
    $finder_params{lane_attributes}->{assemblers} = $self->program;
  }

  # find lanes
  my $lanes = $self->_finder->find_lanes(%finder_params);

  $self->log->debug( 'found a total of ' . scalar @$lanes . ' lanes' );

  if ( scalar @$lanes < 1 ) {
    say STDERR 'No data found.';
    exit;
  }

  # do something with the found lanes
  if ( $self->_symlink_flag or
       $self->_tar_flag or
       $self->_zip_flag or
       $self->_stats_flag or
       $self->gene or
       $self->product ) {
    $self->_make_symlinks($lanes) if $self->_symlink_flag;
    $self->_make_tar($lanes)      if $self->_tar_flag;
    $self->_make_zip($lanes)      if $self->_zip_flag;
    $self->_make_stats($lanes)    if $self->_stats_flag;

    if ( $self->gene or $self->product ) {
      $self->_print_files($lanes);
      $self->_find_genes($lanes);
    }
  }
  else {
    $self->_print_files($lanes);
  }
}

#-------------------------------------------------------------------------------
#- private methods -------------------------------------------------------------
#-------------------------------------------------------------------------------

sub _print_files {
  my ( $self, $lanes ) = @_;

  my $pb = $self->_create_pb('collecting files', scalar @$lanes);

  my @files;
  foreach my $lane ( @$lanes ) {
    push @files, $lane->all_files;
    $pb++;
  }

  say $_ for @files;
}

#-------------------------------------------------------------------------------

sub _find_genes {
  my ( $self, $lanes ) = @_;

  croak 'ERROR: either "gene" or "product" must be set'
    unless ( $self->gene or $self->product );

  my @gffs;
  if ( defined $self->filetype and $self->filetype eq 'gff' ) {
    push @gffs, $_->all_files for @$lanes;
  }
  else {
    my $pb = $self->_create_pb('finding GFFs', scalar @$lanes);
    for ( @$lanes ) {
      push @gffs, $_->find_files('gff', $self->_subdirs);
      $pb++;
    }
  }

  # set up the parameters for the GFF parser
  my %params = (
    gff_files   => \@gffs,
    amino_acids => $self->nucleotides ? 0 : 1,
  );

  if ( $self->product ) {
    $params{search_query}      = $self->product;
    $params{search_qualifiers} = [ 'product' ];
  }
  elsif ( $self->gene ) {
    $params{search_query}      = $self->gene;
    $params{search_qualifiers} = [ 'gene', 'ID' ];
  }
  elsif ( $self->gene and $self->product ) {
    # TODO we're not searching for the value of "product" here. Should we be ?
    $params{search_query} = $self->gene;
    $params{search_qualifiers} = [ 'gene', 'ID', 'product' ];
  }

  $params{output_file} = $self->output if defined $self->output;

  my $gf = Bio::AutomatedAnnotation::ParseGenesFromGFFs->new(%params);


  print "finding genes... ";

  # the "ParseGenesFromGFFs" method calls out to BioPerl which issues several
  # apparently harmless warnings -- the original annotationfind shows them too.
  # Capture (and discard) STDERR to avoid the user seeing the warnings.
  capture_stderr { $gf->create_fasta_file };

  print "\r"; # make the next line overwrite "finding genes..."

  say 'Outputting nucleotide sequences' if $self->nucleotides;
  say "Samples containing gene/product:\t" . $gf->files_with_hits;
  say "Samples missing gene/product:   \t" . $gf->files_without_hits;
}

#-------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

1;

