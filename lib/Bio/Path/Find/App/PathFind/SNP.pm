
package Bio::Path::Find::App::PathFind::SNP;

# ABSTRACT: Find VCF files for lanes

use v5.10; # for "say"

use MooseX::App::Command;
use namespace::autoclean;
use MooseX::StrictConstructor;

use Carp qw ( carp );
use Path::Class;
use Try::Tiny;
use DateTime;

use Types::Standard qw(
  ArrayRef
  Str
  +Bool
);

use Bio::Path::Find::Types qw( :types );

use Bio::Path::Find::Exception;
use Bio::Path::Find::RefFinder;
use Bio::Path::Find::Lane::Class::SNP;

extends 'Bio::Path::Find::App::PathFind';

with 'Bio::Path::Find::App::Role::Archivist',
     'Bio::Path::Find::App::Role::Linker',
     'Bio::Path::Find::App::Role::UsesMappings';

#-------------------------------------------------------------------------------
#- usage text ------------------------------------------------------------------
#-------------------------------------------------------------------------------

# this is used when the "pf" app class builds the list of available commands
command_short_description 'Find VCF files for lanes';

# the module POD is used when the users runs "pf man snp"

=head1 NAME

pf snp - Find VCF files for lanes

=head1 USAGE

  pf snp --id <id> --type <ID type> [options]

=head1 DESCRIPTION

This pathfind command will return information about VCF (and related) files.
Specify the type of data using C<--type> and give the accession, name or
identifier for the data using C<--id>.

Use "pf man" or "pf man snp" to see more information.

=head1 EXAMPLES

  # get a list of VCF files for a lane
  pf snp -t lane -i 12345_1#1

  # find VCF files for lanes mapped using bwa
  pf smp -t lane -i 12345_1 -M bwa

  # find VCF files for lanes mapped against a specific reference
  pf snp -t lane -i 12345_1 -R Streptococcus_suis_P1_7_v1

  # find pseudogenome sequence files for a set of samples
  pf snp -t sample -i ERS123456 -f pseudogenome

  # generate pseudogenomes for lanes
  pf snp -t lane -i 12345_1 -p

  # get mapping information (reference, mapper, date) for files
  pf snp -t lane -i 12345_1 -d

  # create a tar file containing the VCF files for a study
  pf snp -t study -i 123 -a study_123_vcf.tar.gz

=cut

=head1 OPTIONS

These are the options that are specific to C<pf snp>. Run C<pf snp> to see
information about the options that are common to all C<pf> commands.

=over

=item --filetype, -f <file type>

Show only files of the specified type. Must be either C<vcf> or
C<pseudogenome>.

=item --qc, -q <status>

Only show files from lanes with the specified QC status. Must be either
C<passed>, C<failed>, or C<pending>.

=item --details, -d

Show the details of each mapping.

=item --mapper, -M <mapper>

Only show files that were generated using the specified mapper(s). You can
specify multiple mappers by providing a comma-separated list. The name of the
mapper must be one of: C<bowtie2>, C<bwa>, C<bwa_aln>, C<smalt>, C<ssaha2>,
C<stampy>, C<tophat>.

=item --reference, -R <reference genome>

Only show files generated by mapping against a specific reference genome. The
name of the genome must be exact; use C<pf ref -R> to find the name of a
reference.

=item --pseudogenome

Generate pseudogenomes for the found lanes.

=item --exclude-reference, x

When building pseudogenomes, omit the reference sequence from the resulting
sequence file. Default is to include the reference genome sequence.

=item --symlink, -l [<symlink directory>]

Create symlinks to found data. Create links in the specified directory, if
given, or in the current working directory.

=item --archive, -a [<tar filename>}

Create a tar archive containing the found files. Save to the specified
filename, if given

=item --no-tar-compression, -u

Don't compress tar archives.

=item --zip, -z [<zip filename>]

Create a zip archive containing data files for found lanes. Save to
specified filename, if given.

=item --rename, -r

Rename filenames when creating archives or symlinks, replacing hashed
(#) with underscores (_).

=back

=cut

=head1 SCENARIOS

=head2 Find VCF files

The default behaviour of the C<pf snp> command is to print the paths to
VCF files for a set of lanes:

  pf snp -t lane -i 12345_1#1

You can also see a few more details about each mapping, using the C<--details>
(C<-d>) option:

  pf snp -t lane -i 12345_1#1 -d
  /scratch/pathogen/prokaryotes/seq-pipelines/Escherichia/coli/TRACKING/3893STDY6199423/SLX/15100687/12345_1#1/593103.pe.markdup.snp/mpileup.unfilt.vcf.gz        Escherichia_coli_ST131_strain_EC958_v1  smalt   2016-03-19T14:52:19

The output now includes four tab-separated columns for each file, giving:

=over

=item full file path

=item reference genome that was used during mapping

=item name of the mapping software used

=item creation date of the mapping

=back

=head2 Show files from mappings generated by a specific mapper

You can filter the list of returned files in a couple of ways. Some lanes will
be mapped multiple times using different mappers, so you can specify which
mapping program you need using the C<--mapper> (C<-M>) option:

  pf snp -t lane -i 12345_1 -M bwa

You will now see only mappings generated using C<bwa>. If you want to see
mappings generated by more than one mapper, you can use a comma-separated list
of mappers:

  pf snp -t lane -i 12345_1 -M bwa,smalt

or you can use the C<-M> option multiple times:

  pf snp -t lane -i 12345_1 -M bwa -M smalt

=head2 Show mappings that use a specific reference genome

You can also filter the list of VCF files according to which reference
genome a lane was mapped against, using C<--reference> (C<-R>):

  pf snp -t lane -i 12345_1 -R Escherichia_coli_NA114_v2

You can only specify one reference at a time.

The name of the reference must be given exactly. You can find the full, exact
name for a reference using C<pf ref>:

  % pf ref -i Eschericia_coli -R
  Escherichia_coli_0127_H6_E2348_69_v1
  Escherichia_coli_042_v1
  Escherichia_coli_9000_v0.1
  ...

=head2 Archive or link the found files

You can generate a tar file or a zip file containing all of the files that are
found:

  pf snp -t lane -i 12345_1 -a vcfs.tar.gz

or

  pf snp -t lane -i 12345_1 -z vcfs.zip

Since the VCF files are compressed, there's not much to be gained from
compressing them again when archiving. If you're creating a tar archive, you
can use the C<--no-tar-compression> (C<-N>) option to skip the compression.
The resulting tar file will not be any larger but it will be much quicker to
generate:

  pf snp -t lane -i 12345_1 -a vcfs.tar -N

Alternatively, you can create symlinks to the files in a directory of your
choice:

  pf snp -t lane -i 12345_1 -l vcf_files

=head2 Generate pseudogenomes

The C<pf snp> command can generate pseudogenome sequence files, taking the
C<pseudo_genome.fasta> file for each lane and concatenating them, optionally
with the sequence of the reference genome to which each lane's reads were
mapped:

  pf snp -t lane -i 12345_1 -p

If more than one reference genome has been used to map reads for a set of
lanes, the command will generate multiple pseudogenome alignments, one for
each reference.

By default, the generated pseudogenome files include the sequence of the
reference genome, but you can omit the reference by adding the
C<--exclude-reference> (C<-x>) option:

  pf snp -t lane -i 12345_1 -p -x

=head1 SEE ALSO

=over

=item pf map - find mappings

=item pf ref - find reference genomes

=back

=cut

#-------------------------------------------------------------------------------
#- command line options --------------------------------------------------------
#-------------------------------------------------------------------------------

option 'filetype' => (
  documentation => 'type of files to find',
  is            => 'ro',
  isa           => SNPType,
  cmd_aliases   => 'f',
  default       => 'vcf',
);

option 'qc' => (
  documentation => 'filter results by lane QC state',
  is            => 'ro',
  isa           => QCState,
  cmd_aliases   => 'q',
);

option 'exclude_reference' => (
  documentation => 'exclude the reference when generating a pseudogenome',
  is            => 'rw',
  isa           => Bool,
  cmd_aliases   => 'x',
  cmd_flag      => 'exclude-reference',
);

option 'pseudogenome' => (
  documentation => 'generate pseudogenome(s)',
  is            => 'rw',
  isa           => Bool,
  cmd_aliases   => 'p',
);

#-------------------------------------------------------------------------------
#- private attributes ----------------------------------------------------------
#-------------------------------------------------------------------------------

# an instance of Bio::Path::Find::RefFinder. Used for converting a reference
# genome name into a path to its sequence file

has '_ref_finder' => (
  is      => 'ro',
  isa     => BioPathFindRefFinder,
  builder => '_build_ref_finder',
  lazy    => 1,
);

sub _build_ref_finder {
  return Bio::Path::Find::RefFinder->new;
}

#-------------------------------------------------------------------------------
#- builders --------------------------------------------------------------------
#-------------------------------------------------------------------------------

# this is a builder for the "_lane_class" attribute, which is defined on the
# parent class, B::P::F::A::PathFind. The return value specifies the class of
# object that should be returned by the B::P::F::Finder::find_lanes method.

sub _build_lane_class {
  return 'Bio::Path::Find::Lane::Class::SNP';
}

#-------------------------------------------------------------------------------
#- public methods --------------------------------------------------------------
#-------------------------------------------------------------------------------

sub run {
  my $self = shift;

  # some quick checks that will allow us to fail fast if things aren't going to
  # let the command run to successfully

  if ( $self->_symlink_flag and           # flag is set; we're making symlinks.
       $self->_symlink_dest and           # destination is specified.
       -e $self->_symlink_dest and        # the destintation path exists.
       not -d $self->_symlink_dest ) {    # but it's not a directory.
    Bio::Path::Find::Exception->throw(
      msg => 'ERROR: symlink destination "' . $self->_symlink_dest
             . q(" exists but isn't a directory)
    );
  }

  if ( not $self->force and       # we're not overwriting stuff.
       $self->_tar_flag and       # flag is set; we're writing stats.
       $self->_tar and            # destination file is specified.
       -e $self->_tar ) {         # output file already exists.
    Bio::Path::Find::Exception->throw(
      msg => 'ERROR: tar archive "' . $self->_tar . '" already exists; not overwriting. Use "-F" to force overwriting'
    );
  }

  if ( not $self->force and
       $self->_zip_flag and
       $self->_zip and
       -e $self->_zip ) {
    Bio::Path::Find::Exception->throw(
      msg => 'ERROR: zip archive "' . $self->_zip . '" already exists; not overwriting. Use "-F" to force overwriting'
    );
  }

  #---------------------------------------

  # build the parameters for the finder
  my %finder_params = (
    ids      => $self->_ids,
    type     => $self->_type,
  );

  # first, if we're building a pseudogenome, we need to collect the
  # pseudogenome sequence files for each lane, so we need to override whatever
  # value we have for filetype and make the lanes return "pseudo_genome.fasta"
  # files.
  $finder_params{filetype} = $self->pseudogenome
                           ? 'pseudogenome'
                           : $self->filetype;

  #---------------------------------------

  # these are filters that are applied by the finder

  # when finding lanes, should the finder filter on QC status ?
  $finder_params{qc} = $self->qc if $self->qc;

  # should we look for lanes with the "snp_called" bit set on the "processed"
  # bit field ? Turning this off, i.e. setting the command line option
  # "--ignore-processed-flag", will allow the command to return data for lanes
  # that haven't completed the SNP calling pipeline.
  $finder_params{processed} = Bio::Path::Find::Types::SNP_CALLED_PIPELINE
    unless $self->ignore_processed_flag;

  #---------------------------------------

  # these are filters that are applied by the lanes themselves, when they're
  # finding files to return (see "B::P::F::Lane::Class::SNP::_get_files")

  # when finding files, should the lane restrict the results to files created
  # with a specified mapper ?
  $finder_params{lane_attributes}->{mappers} = $self->mapper
    if $self->mapper;

  # when finding files, should the lane restrict the results to mappings
  # against a specific reference ?
  $finder_params{lane_attributes}->{reference} = $self->reference
    if $self->reference;

  #---------------------------------------

  # find lanes
  my $lanes = $self->_finder->find_lanes(%finder_params);

  if ( scalar @$lanes < 1 ) {
    say STDERR 'No data found.';
    return;
  }

  # what are we returning ?
  if ( $self->pseudogenome ) {
    $self->_create_pseudogenomes($lanes);
  }
  elsif ( $self->_symlink_flag or
       $self->_tar_flag or
       $self->_zip_flag ) {
    # can make symlinks, tarball or zip archive all in the same run
    $self->_make_symlinks($lanes) if $self->_symlink_flag;
    $self->_make_tar($lanes)      if $self->_tar_flag;
    $self->_make_zip($lanes)      if $self->_zip_flag;
  }
  else {
    # print the list of files. Should we show extra info ?
    if ( $self->details ) {
      # yes; print file path, reference, mapper and timestamp
      $_->print_details for @$lanes;
    }
    else {
      # no; just print the paths
      $_->print_paths for @$lanes;
    }
  }
}

#-------------------------------------------------------------------------------
#- private methods -------------------------------------------------------------
#-------------------------------------------------------------------------------

# override the default method from Bio::Path::Find::App::Role::Archivist. If we
# don't return a stats data structure, the Archivist methods for creating
# archives won't try to write a stats file and include it in the zip or tar
# files.

sub _collect_filenames {
  my ( $self, $lanes ) = @_;

  my $pb = $self->_create_pb('collecting files', scalar @$lanes);

  my @filenames;
  foreach my $lane ( @$lanes ) {
    foreach my $from ( $lane->all_files ) {
      my $to;
      if ( $lane->can('_edit_filenames') ) {
        # the "_edit_filenames" method returns an array containing the original
        # "from" path and an edited version of "to", the second parameter
        ( $from, $to ) = $lane->_edit_filenames($from, $from);
      }
      else {
        $to = $from;
      }
      push @filenames, { $from => $to };
    }
    $pb++;
  }

  return \@filenames;
}

#-------------------------------------------------------------------------------

# generate pseudo genomes for the given lanes

sub _create_pseudogenomes {
  my ( $self, $lanes ) = @_;

  # get a list of the "pseudo_genome.fasta" files for the specified lanes
  my $pg_sequences = $self->_collect_sequences($lanes);

  # combine the pseudogenomes with their references and write them out
  $self->_write_pseudogenomes($pg_sequences);
}

#-------------------------------------------------------------------------------

# generate a list of the "pseudo_genome.fasta" files for the provided lanes

sub _collect_sequences {
  my ( $self, $lanes ) = @_;

  my %pseudogenomes;
  LANE: foreach my $lane ( @$lanes ) {

    # for each lane, collect the most recent sequence file for each
    # pseudogenome
    my %latest_sequence_files;

    # walk over the list of files for this lane. There may be multiple mappings
    # and therefore multiple sequence files. Work out which one to return
    FILE: foreach my $pg_fasta ( $lane->all_files ) {

      # if a file should exist but doesn't, the user will get a warning from
      # the finder. Here we'll just skip it.
      next unless -f $pg_fasta;

      # collect together the details of the current file
      my $file_info = $lane->get_file_info($pg_fasta);
      my $file_hash = {
        file      => $pg_fasta,        # this file...
        lane      => $lane,            # from this lane...
        ref       => $file_info->[0],  # was mapped against this reference...
        mapper    => $file_info->[1],  # using this mapper...
        timestamp => $file_info->[2],  # at this time
      };

      # if we haven't got a file for this reference yet, or if the current file
      # is newer than the previous file, keep this file
      my $ref = $file_hash->{ref};
      if ( not defined $latest_sequence_files{$ref} or
           DateTime->compare($file_hash->{timestamp}, $latest_sequence_files{$ref}->{timestamp} ) > 0 ) {
        $latest_sequence_files{$ref} = $file_hash;
      }
    }

    # store the files for this lane. The result is a hash, keyed on the name of
    # the reference, with a file info hash as the value.
    foreach my $ref ( keys %latest_sequence_files ) {
      push @{ $pseudogenomes{$ref} }, $latest_sequence_files{$ref};
    }
  }

  return \%pseudogenomes;
}

#-------------------------------------------------------------------------------

# generate sequence files for the pseudogenomes

sub _write_pseudogenomes {
  my ( $self, $pseudogenomes ) = @_;

  say STDERR "omitting reference sequences from pseudogenomes"
    if $self->exclude_reference;

  my $pb = $self->_create_pb( 'building pseudogenomes', scalar keys %$pseudogenomes );

  # keep track of the files that we actually write
  my @written_files;

  REFERENCE: while ( my ( $pseudogenome, $files ) = each %$pseudogenomes ) {

    # get the path to the fasta file containing the reference genome sequence
    my $ref_path = $self->_get_reference_path($pseudogenome);

    # generate the filename for the pseudogenome sequence alignment file
    my $pg_filename = $self->_renamed_id . "_${pseudogenome}_concatenated.aln";

    # make sure we're not overwriting anything without permission
    if ( -e $pg_filename and not $self->force ) {
      Bio::Path::Find::Exception->throw(
        msg => qq(ERROR: output file "$pg_filename" already exists; not overwriting. Use "-F" to force overwriting)
      );
    }

    # open the output file
    open PSEUDOGENOME, '>', $pg_filename
      or Bio::Path::Find::Exception->throw(
        msg => qq(ERROR: couldn't write the pseudogenome to file "$pg_filename": $!)
      );

    # should we add the reference sequence ?
    if ( not $self->exclude_reference ) {
      open REFERENCE, '<', $ref_path
        or Bio::Path::Find::Exception->throw(
          msg => qq(ERROR: couldn't read the reference genome sequence from "$ref_path": $!)
        );
      say PSEUDOGENOME ">$pseudogenome";
      for ( grep { ! m/^\>/ } <REFERENCE> ) {
        print PSEUDOGENOME $_;
      }
      close REFERENCE;
    }

    # add the sequences
    FILE: foreach my $file ( @$files ) {
      unless ( open PG_FILE, '<', $file->{file} ) {
        carp q(WARNING: couldn't read the pseudogenome sequence file for lane ")
               . $file->{lane}->row->name . q|" (file "| . $file->{file}
               . qq|"): $!|;
        next FILE;
      }
      while ( <PG_FILE> ) { print PSEUDOGENOME $_ }
      close PG_FILE;
    }
    push @written_files, $pg_filename;

    close PSEUDOGENOME;

    $pb++;
  }

  say STDERR qq(wrote "$_") for @written_files;
}

#-------------------------------------------------------------------------------

# given the name of a reference genome, find the path to its sequence file

sub _get_reference_path {
  my ( $self, $ref ) = @_;

  # find the path to the reference
  my $refs = $self->_ref_finder->lookup_paths( [ $ref ], 'fa' );

  # make sure we have one, and only one, file path
  if ( not scalar @$refs ) {
    Bio::Path::Find::Exception->throw(
      msg => qq(ERROR: can't find reference genome "$ref"; try looking it up using "pf ref"),
    );
  }
  if ( scalar @$refs > 1 ) {
    # we shouldn't ever get here. The reference name is used to filter lanes,
    # so if the supplied name isn't unique, it won't match the reference used
    # when mapping the lanes, so we won't *have* any lanes. In theory.
    Bio::Path::Find::Exception->throw(
      msg => q(ERROR: reference genome name is ambiguous; try looking it up using "pf ref"),
    );
  }

  return $refs->[0];
}

#-------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

1;
