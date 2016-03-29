
package Bio::Path::Find::Lane::Class::SNP;

# ABSTRACT: a class that adds SNP-finding functionality to the B::P::F::Lane class

use v5.10; # for "say"

use Moose;
use Path::Class;
use Carp qw( carp );

use Types::Standard qw(
  Maybe
  Str
  HashRef
  ArrayRef
);

use Bio::Path::Find::Types qw( :all );

extends 'Bio::Path::Find::Lane';

#-------------------------------------------------------------------------------
#- public attributes -----------------------------------------------------------
#-------------------------------------------------------------------------------

# make the "filetype" attribute require values of type SNPType. This is to make
# sure that this class correctly restrict the sorts of files that it will
# return.

has '+filetype' => (
  isa => Maybe[SNPType],
);

#---------------------------------------

has 'mappers' => (
  is      => 'ro',
  isa     => Mappers,
  lazy    => 1,
  builder => '_build_mappers',
);

sub _build_mappers {
  return Mapper->values;
}

#---------------------------------------

=head1 ATTRIBUTES

=attr reference

The name of the reference genome on which to filter returned lanes.

=cut

has 'reference' => (
  is  => 'ro',
  isa => Str,
);

#-------------------------------------------------------------------------------
#- private attributes ----------------------------------------------------------
#-------------------------------------------------------------------------------

# somewhere to store extra information about the files that we find. The info
# is stored as hashref, keyed on the file path.

has '_verbose_file_info' => (
  is      => 'rw',
  isa     => HashRef[ArrayRef[Str]],
  default => sub { {} },
);

#-------------------------------------------------------------------------------
#- builders --------------------------------------------------------------------
#-------------------------------------------------------------------------------

# this sets the mapping between filetype and patterns matching filenames on
# disk. In this case the value is not needed, because the finding mechanism
# calls "_get_bam", so we never fall back on the general "_get_extensions"
# method.

sub _build_filetype_extensions {
  return {
    bam => 'markdup.bam',
  };
}

# (if there is a "_get_*" method for one of the keys, then calling
# $lane->find_files(filetype=>'<key>') will call that method to find files.  If
# there's no corresponding "_get_*" method, "find_files" will fall back on
# calling "_get_files_by_extension", which will use Find::File::Rule to look
# for files according to the pattern given in the hash value.)

#---------------------------------------

# build an array of headers for the statistics report
#
# required by the Stats Role

sub _build_stats_headers {
  return [
    'Study ID',
    'Sample',
    'Lane Name',
    'Cycles',
    'Reads',
    'Bases',
    'Map Type',
    'Reference',
    'Reference Size',
    'Mapper',
    'Mapstats ID',
    'Mapped %',
    'Paired %',
    'Mean Insert Size',
    'Depth of Coverage',
    'Depth of Coverage sd',
    'Genome Covered (% >= 1X)',
    'Genome Covered (% >= 5X)',
    'Genome Covered (% >= 10X)',
    'Genome Covered (% >= 50X)',
    'Genome Covered (% >= 100X)',
  ];
}

#-------------------------------------------------------------------------------

# collect together the fields for the statistics report
#
# required by the Stats Role

sub _build_stats {
  my $self = shift;

  # for each mapstats row for this lane, get a row of statistics, as an
  # arrayref, and push it into the return array.
  my @stats = map { $self->_get_stats_row($_) } $self->_all_mapstats_rows;

  return \@stats;
}

#-------------------------------------------------------------------------------
#- methods ---------------------------------------------------------------------
#-------------------------------------------------------------------------------

=head1 METHODS

=head2 print_details

For each bam file found by this lane, print:

=over

=item the path to the file itself

=item the reference to which reads were mapped

=item the name of the mapping software used

=item the date at which the mapping was generated

=back

The items are printed as a simple tab-separated list, one row per file.

=cut

sub print_details {
  my $self = shift;

  foreach my $file ( $self->all_files ) {
    say join "\t", $file, @{ $self->_verbose_file_info->{$file} };
  }
}

#-------------------------------------------------------------------------------
#- private methods -------------------------------------------------------------
#-------------------------------------------------------------------------------

# find VCF files for the lane

sub _get_vcf {
  my $self = shift;

  return $self->_get_snp_files('vcf');
}

sub _get_pseudogenome {
  my $self = shift;

  return $self->_get_snp_files('pseudogenome');
}

#-------------------------------------------------------------------------------

# this method is cargo-culted from Bio::Path::Find::Lane::Class::Map

sub _get_snp_files {
  my ( $self, $filetype ) = @_;

  my $lane_row = $self->row;

  my $mapstats_rows = $lane_row->search_related_rs( 'latest_mapstats', { is_qc => 0 } );

  # if there are no rows for this lane in the mapstats table, it hasn't had
  # mapping run on it, so we're done here
  return unless $mapstats_rows->count;

  MAPPING: foreach my $mapstats_row ( $mapstats_rows->all ) {

    my $mapstats_id = $mapstats_row->mapstats_id;
    my $prefix      = $mapstats_row->prefix;

    # find the path (on NFS) to the job status file for this mapping run
    my $job_status_file = file( $lane_row->storage_path, "${prefix}job_status" );

    # if the job failed or is still running, the file "<prefix>job_status" will
    # still exist, in which case we don't want to return *any* bam files
    next MAPPING if -f $job_status_file;

    # at this point there's no job status file, so the mapping job is done

    #---------------------------------------

    # apply filters

    # this is the mapper that was actually used to map this lane's reads
    my $lane_mapper = $mapstats_row->mapper->name;

    # this is the reference that was used for this particular mapping
    my $lane_reference = $mapstats_row->assembly->name;

    # return only mappings generated using a specific mapper
    if ( $self->mappers ) {
      # the user provided a list of mappers. Convert it into a hash so that
      # we can quickly look up the lane's mapper in there
      my %wanted_mappers = map { $_ => 1 } @{ $self->mappers };

      # unless the lane's mapper is one of the mappers that the user specified,
      # skip this mapping
      next MAPPING unless exists $wanted_mappers{$lane_mapper};
    }

    # return only mappings that use a specific reference genome
    next MAPPING if ( $self->reference and $lane_reference ne $self->reference );

    #---------------------------------------

    # build the name of the VCF file for this mapping

    # single or paired end ?
    my $pairing = $lane_row->paired ? 'pe' : 'se';

    my $mapping_dir = "$mapstats_id.$pairing.markdup.snp";
    my $file = $filetype eq 'vcf'
             ? 'mpileup.unfilt.vcf.gz'
             : 'pseudo_genome.fasta';

    my $returned_file = file($self->symlink_path, $mapping_dir, $file);

    # if the VCF file exists, we show that. Note that we check that the file
    # exists using the storage path (on NFS), but return the symlink path (on
    # lustre)
    carp qq(WARNING: expected to find raw VCF file at "$returned_file", but it was missing)
      unless -f file($self->storage_path, $mapping_dir, $file);

    # store the file itself, plus some extra details, which are used by the
    # "print_details" method
    $self->_add_file($returned_file);
    $self->_verbose_file_info->{$returned_file} = [
      $lane_reference,          # name of the reference
      $lane_mapper,             # name of the mapper
      $mapstats_row->changed,   # last update timestamp
    ];
  }
}

#-------------------------------------------------------------------------------

1;

