# Copyright (C) 2008-2012 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

# Class: EBox::Samba::Model::SambaShares
#
#  This model is used to configure shares different to those which are
#  given by the group share
#
package EBox::Samba::Model::SambaShares;

use base 'EBox::Model::DataTable';

use strict;
use warnings;

use Cwd 'abs_path';
use String::ShellQuote;

use EBox::Gettext;
use EBox::Global;
use EBox::Types::Text;
use EBox::Types::Union;
use EBox::Types::Boolean;
use EBox::Model::Manager;
use EBox::Exceptions::DataInUse;
use EBox::Sudo;

use Error qw(:try);

# TODO Fix
use constant DEFAULT_MASK => '0770';
use constant DEFAULT_USER => 'root';
use constant DEFAULT_GROUP => '__USERS__';
use constant GUEST_DEFAULT_MASK => '0750';
use constant GUEST_DEFAULT_USER => 'nobody';
use constant GUEST_DEFAULT_GROUP => 'nogroup';
use constant FILTER_PATH => ('/bin', '/boot', '/dev', '/etc', '/lib', '/root',
                             '/proc', '/run', '/sbin', '/sys', '/var', '/usr');

# Dependencies

# Group: Public methods

# Constructor: new
#
#     Create the new Samba shares table
#
# Overrides:
#
#     <EBox::Model::DataTable::new>
#
# Returns:
#
#     <EBox::Samba::Model::SambaShares> - the newly created object
#     instance
#
sub new
{
    my ($class, %opts) = @_;

    my $self = $class->SUPER::new(%opts);
    bless ($self, $class);

    return $self;
}

# Group: Protected methods

# Method: _table
#
# Overrides:
#
#     <EBox::Model::DataTable::_table>
#
sub _table
{
    my ($self) = @_;

    my @tableDesc = (
       new EBox::Types::Text(
                               fieldName     => 'share',
                               printableName => __('Share name'),
                               editable      => 1,
                               unique        => 1,
                              ),
       new EBox::Types::Union(
                               fieldName => 'path',
                               printableName => __('Share path'),
                               subtypes =>
                                [
                                     new EBox::Types::Text(
                                       fieldName     => 'zentyal',
                                       printableName =>
                                            __('Directory under Zentyal'),
                                       editable      => 1,
                                       unique        => 1,
                                                        ),
                                     new EBox::Types::Text(
                                       fieldName     => 'system',
                                       printableName => __('File system path'),
                                       editable      => 1,
                                       unique        => 1,
                                                          ),
                               ],
                               help => _pathHelp($self->parentModule()->SHARES_DIR())),
       new EBox::Types::Text(
                               fieldName     => 'comment',
                               printableName => __('Comment'),
                               editable      => 1,
                              ),
       new EBox::Types::Boolean(
                                   fieldName     => 'guest',
                                   printableName => __('Guest access'),
                                   editable      => 1,
                                   defaultValue  => 0,
                                   help          => __('This share will not require authentication.'),
                                   ),
       new EBox::Types::HasMany(
                               fieldName     => 'access',
                               printableName => __('Access control'),
                               foreignModel => 'SambaSharePermissions',
                               view => '/Samba/View/SambaSharePermissions'
                              ),
       # This hidden field is filled with the group name when the share is configured as
       # a group share through the group addon
       new EBox::Types::Text(
            fieldName => 'groupShare',
            hidden => 1,
            optional => 1,
            ),
      );

    my $dataTable = {
                     tableName          => 'SambaShares',
                     printableTableName => __('Shares'),
                     modelDomain        => 'Samba',
                     defaultActions     => [ 'add', 'del',
                                             'editField', 'changeView' ],
                     tableDescription   => \@tableDesc,
                     menuNamespace      => 'Samba/View/SambaShares',
                     class              => 'dataTable',
                     help               => _sharesHelp(),
                     printableRowName   => __('share'),
                     enableProperty     => 1,
                     defaultEnabledValue => 1,
                     orderedBy          => 'share',
                    };

      return $dataTable;
}

# Method: validateTypedRow
#
#       Override <EBox::Model::DataTable::validateTypedRow> method
#
#   Check if the share path is allowed or not
sub validateTypedRow
{
    my ($self, $action, $parms)  = @_;

    return unless ($action eq 'add' or $action eq 'update');

    if (exists $parms->{'path'}) {
        my $path = $parms->{'path'}->selectedType();
        if ($path eq 'system') {
            # Check if it is an allowed system path
            my $normalized = abs_path($parms->{'path'}->value());
            foreach my $filterPath (FILTER_PATH) {
                if ($normalized =~ /^$filterPath/) {
                    throw EBox::Exceptions::External(
                            __x('Path not allowed. It cannot be under {dir}',
                                dir => $normalized
                               )
                    );
                }
            }
            EBox::Validate::checkAbsoluteFilePath($parms->{'path'}->value(),
                                           __('Samba share absolute path')
                                                );
        } else {
            # Check if it is a valid directory
            my $dir = $parms->{'path'}->value();
            EBox::Validate::checkFilePath($dir,
                                         __('Samba share directory'));
        }
    }
}

# Method: removeRow
#
#   Override <EBox::Model::DataTable::removeRow> method
#
#   Overriden to warn the user if the directory is not empty
#
sub removeRow
{
    my ($self, $id, $force) = @_;

    my $row = $self->row($id);

    if ($force or $row->elementByName('path')->selectedType() eq 'system') {
        return $self->SUPER::removeRow($id, $force);
    }

    my $path =  $self->parentModule()->SHARES_DIR() . '/' .
                $row->valueByName('path');
    unless ( -d $path) {
        return $self->SUPER::removeRow($id, $force);
    }

    opendir (my $dir, $path);
    while(my $entry = readdir ($dir)) {
        next if($entry =~ /^\.\.?$/);
        closedir ($dir);
        throw EBox::Exceptions::DataInUse(
         __('The directory is not empty. Are you sure you want to remove it?'));
    }
    closedir($dir);

    return $self->SUPER::removeRow($id, $force);
}

# Method: deletedRowNotify
#
#   Override <EBox::Model::DataTable::validateRow> method
#
#   Write down shares directories to be removed when saving changes
#
sub deletedRowNotify
{
    my ($self, $row) = @_;

    my $path = $row->elementByName('path');

    # We are only interested in shares created under /home/samba/shares
    return unless ($path->selectedType() eq 'zentyal');

    my $mgr = EBox::Model::Manager->instance();
    my $deletedModel = $mgr->model('SambaDeletedShares');
    $deletedModel->addRow('path' => $path->value());
}

# Method: createDirs
#
#   This method is used to create the necessary directories for those
#   shares which must live under /home/samba/shares
#
sub createDirs
{
    my ($self) = @_;

    my $adminAccount = $self->parentModule()->model('GeneralSettings')->value('adminAccount');
    my $administratorSID = $self->parentModule()->ldb()->getSidById($adminAccount);
    my $domainUsersSID = $self->parentModule()->ldb()->getSidById('Domain Users');

    for my $id (@{$self->ids()}) {
        my $row = $self->row($id);
        my $pathType =  $row->elementByName('path');
        my $guestAccess = $row->valueByName('guest');
        next unless ( $pathType->selectedType() eq 'zentyal');
        my $path = $self->parentModule()->SHARES_DIR() . '/' . $pathType->value();
        my @cmds = ();
        push(@cmds, "mkdir -p '$path'");
        if ($guestAccess) {
           push(@cmds, 'chmod ' . GUEST_DEFAULT_MASK . " '$path'");
           push(@cmds, 'chown ' . GUEST_DEFAULT_USER . ':' . GUEST_DEFAULT_GROUP . " '$path'");
        } else {
           push(@cmds, 'chmod ' . DEFAULT_MASK . " '$path'");
           push(@cmds, 'chown ' . DEFAULT_USER . ':' . DEFAULT_GROUP . " '$path'");
        }
        EBox::debug("Creating share directory");
        EBox::debug("Executing @cmds");
        EBox::Sudo::root(@cmds);
        # Set NT ACLs
        # Build the security descriptor string
        my $sdString = '';
        $sdString .= "O:$administratorSID"; # Object's owner
        $sdString .= "G:$domainUsersSID"; # Object's primary group
        # Build the ACS strings
        # http://msdn.microsoft.com/en-us/library/windows/desktop/aa374928(v=vs.85).aspx
        my @aceStrings = ();
        push (@aceStrings, '(A;;0x001f01ff;;;SY)'); # SYSTEM account has full access
        push (@aceStrings, "(A;;0x001f01ff;;;$administratorSID)"); # Administrator has full access
        for my $subId (@{$row->subModel('access')->ids()}) {
            my $subRow = $row->subModel('access')->row($subId);
            my $permissions = $subRow->elementByName('permissions');
            my $aceString = '(';
            # ACE Type
            $aceString .= 'A;';
            # ACE Flags
            $aceString .= 'OICI;';
            # Rights
            if ($permissions->value() eq 'readOnly') {
                $aceString .= '0x001200A9;';
            } elsif ($permissions->value() eq 'readWrite') {
                $aceString .= '0x001301BF;';
            } elsif ($permissions->value() eq 'administrator') {
                $aceString .= '0x001F01FF;';
            }
            # Object Guid
            $aceString .= ';';
            # Inherit Object Guid
            $aceString .= ';';
            # Account SID
            my $userType = $subRow->elementByName('user_group');
            $aceString .= $self->parentModule()->ldb()->getSidById($userType->printableValue());
            $aceString .= ')';
            push (@aceStrings, $aceString);
        }
        if ($guestAccess) {
            push (@aceStrings, '(A;OICI;0x001301BF;;;S-1-1-0)');
        }
        my $fullAce = join ('', @aceStrings);
        $sdString .= "D:$fullAce";
        my $cmd = $self->parentModule()->SAMBATOOL() . " ntacl set '$sdString' '$path'";
        try {
            EBox::debug("Executing '$cmd'");
            EBox::Sudo::root($cmd);
        } otherwise {
            my $error = shift;
            EBox::debug("Couldn't write NT ACLs for '$path': $error");
        };
    }
}

# Private methods
sub _pathHelp
{
    my ($sharesPath) = @_;

    return __x( '{openit}Directory under Zentyal{closeit} will ' .
            'automatically create the share.' .
            "directory in {sharesPath} {br}" .
            '{openit}File system path{closeit} will allow you to share '.
            'an existing directory within your file system',
               sharesPath => $sharesPath,
               openit  => '<i>',
               closeit => '</i>',
               br      => '<br>');

}

sub _sharesHelp
{
    return __('Here you can create shares with more fine-grained permission ' .
              'control. ' .
              'You can use an existing directory or pick a name and let Zentyal ' .
              'create it for you.');
}

# Method: headTile
#
#   Overrides <EBox::Model::DataTable::headTitle>
#
#
sub headTitle
{
    return undef;
}

1;
