
package Bio::Path::Find::Lane::Status;

# ABSTRACT: a class for working with status information about lanes

use Moose;
use namespace::autoclean;
use MooseX::StrictConstructor;

use Bio::Path::Find::Lane::StatusFile;

use Types::Standard qw(
  ArrayRef
  HashRef
  Str
  Int
);
use Bio::Path::Find::Types qw(
  BioPathFindLane
  BioPathFindLaneStatusFile
  PathClassFile
  Datetime
);

use Bio::Path::Find::Exception;

#-------------------------------------------------------------------------------
#- public attributes -----------------------------------------------------------
#-------------------------------------------------------------------------------

# required attributes

has 'lane' => (
  is       => 'ro',
  isa      => BioPathFindLane,
  required => 1,
  weak_ref => 1,
  # NOTE this is a weakened reference. Since the Lane object has a reference
  # to this Status object, we end up with a circular reference, which could
  # cause a memory leak
);

#---------------------------------------

=attr status_files

Reference to a hash containing a pipeline name as the key and an arrayref as
the value. The array contains status file object(s)
(L<Bio::Path::Find::Lane::StatusFile>) for the named pipeline.

In most cases there will be only a single status file for each pipeline, but
some pipelines, e.g. mapping, may be run multiple times for a given sample,
hence there may be multiple status files present.

=cut

has 'status_files' => (
  traits  => ['Hash'],
  is      => 'ro',
  isa     => HashRef[ArrayRef[BioPathFindLaneStatusFile]],
  lazy    => 1,
  builder => '_build_status_files',
  handles => {
    all_status_files => 'values',
    has_status_files => 'count',
  },
);

sub _build_status_files {
  my $self = shift;

  my $files = {};

  return $files unless(-r $self->lane->symlink_path);

  foreach my $status_file ( grep m/_job_status$/, $self->lane->symlink_path->children ) {
    my $status_file_object = Bio::Path::Find::Lane::StatusFile->new( status_file => $status_file );
    push @{ $files->{ $status_file_object->pipeline_name } }, $status_file_object;
  }

  return $files;
}

#-------------------------------------------------------------------------------
#- methods ---------------------------------------------------------------------
#-------------------------------------------------------------------------------

=head1 METHODS

=head2 all_status_files

Returns a list of the L<Bio::Path::Find::Lane::StatusFile> objects for this lane.

=head2 has_status_files

Returns true if there are any available status file objects for this lane.
False otherwise.

=cut

#-------------------------------------------------------------------------------

=head2 pipeline_status($pipeline_name)

Returns the status of the specified pipeline. There are several possible
return values:

=over

=item NA

if the pipeline name is not recognised

=item Done

if the database shows that the specified pipeline is complete

=item -

if there is no status file for the specified pipeline for this lane

=item <status> . (<last status update date>)

if there is a status file for the specified pipeline

=back

=cut

sub pipeline_status {
  my ( $self, $pipeline_name ) = @_;

  return 'NA' if not defined $pipeline_name;

  my $bit_pattern = $self->lane->row->processed;

  # we need to convert the pipeline name into a bit value. We can do that by
  # looking up the pipeline name in a mapping that's stored in the Types
  # module.
  my $bit_value = $Bio::Path::Find::Types::pipeline_names->{$pipeline_name};

  # the next set of tests try to work out what's going on with the specified
  # pipeline, looking at the database and the job status file

  # the specified pipeline name isn't a valid flag in the "processed" bit
  # pattern. In principle, I think, this shouldn't happen.
  return 'NA' if not defined $bit_value;

  # if the specified flag is set in the "processed" bit pattern, that stage of
  # the pipeline is done
  return 'Done' if $bit_pattern & $bit_value;

  # we can't say anything about the status of the specified pipeline unless we
  # found at least one pipeline status file. This is where we get to if the the
  # specified pipeline isn't done, but there is no job status file for the lane
  return '-' unless $self->has_status_files;

  # bail if there is a job status file, but it's not giving us the status of
  # the specified pipeline
  return '-' unless $self->status_files->{$pipeline_name};

  # finally, we should have one or more readable status files for this pipeline
  my $status_file_objects = $self->status_files->{$pipeline_name};

  # sort on (descending) date of last update, so that we get status from the
  # most recently updated status file.
  # NOTE that we base this on the timestamp OF the statusfile, NOT the
  # NOTE timestamp IN the status file
  my @sorted_status_file_objects = sort { $b->last_update->epoch <=> $a->last_update->epoch }
                                        @$status_file_objects;

  my $latest_status_file_object = $sorted_status_file_objects[0];

  return ucfirst $latest_status_file_object->current_status
                 . ' (' . $latest_status_file_object->last_update->dmy . ')';
}

#-------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

1;

