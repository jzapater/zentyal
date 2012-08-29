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

# Class:
#
#   EBox::DNS::Model::DomainTable
#
#   This class inherits from <EBox::Model::DataTable> and represents
#   the object table which basically contains domains names, the IP
#   address for the domain and a reference to a member
#   <EBox::DNS::Model::HostnameTable>
#
package EBox::DNS::Model::DomainTable;

use EBox::Global;
use EBox::Gettext;
use EBox::Validate qw(:all);
use EBox::Exceptions::External;
use EBox::Exceptions::DataExists;

use EBox::Types::Boolean;
use EBox::Types::DomainName;
use EBox::Types::HasMany;
use EBox::Types::HostIP;
use EBox::Types::Text;

use EBox::Model::Manager;

# Dependencies
use Crypt::OpenSSL::Random;
use MIME::Base64;

use strict;
use warnings;

use base 'EBox::Model::DataTable';

# Group: Public methods

sub new
{
    my $class = shift;
    my %parms = @_;

    my $self = $class->SUPER::new(@_);
    bless ($self, $class);

    return $self;
}

# Method: addDomain
#
#   Add a domain to the domains table. Note this method must exist
#   because we must provide an easy way to migrate old dns module
#   to this new one.
#
# Parameters:
#
#   domain_name - String domain's name
#   ipAddresses - (optional) Array ref with ipAddresses for the domain
#   hostnames   - (optional) Array ref containing host information with the
#                            same format than addHost method
#   type        - (optional) Domain type (static, dynamic or dlz)
#   readOnly    - (optional)
#
# Example:
#
#   domain_name => 'subdom.foo.com',
#   readOnly    => 0,
#   hostnames   => [
#                   { name     => 'bar',
#                     ipAddresses => ['192.168.1.254', '192.168.2.254'],
#                     aliases  => ['bar', 'b4r'],
#                     readonly => 0
#                   }
#                  ]
#
sub addDomain
{
    my ($self, $params) = @_;

    my $domainName = $params->{domain_name};
    unless (defined ($domainName)) {
        throw EBox::Exceptions::MissingArgument('domain_name');
    }
    unless (defined $params->{type}) {
        $params->{type} = EBox::DNS::STATIC_ZONE();
    }

    EBox::debug("Adding DNS domain $domainName");
    my $id = $self->addRow(domain => $domainName,
                           type => $params->{type},
                           readOnly => $params->{readOnly});

    unless (defined ($id)) {
        throw EBox::Exceptions::Internal("Couldn't add domain's name: $domainName");
    }

    if (exists $params->{ipAddresses}) {
        my $domainRow = $self->_getDomainRow($domainName);
        my $ipModel = $domainRow->subModel('ipAddresses');
        foreach my $ip (@{$params->{ipAddresses}}) {
            $ipModel->addRow(ip => $ip);
        }
    }

    # Add the hosts to the domain
    if (exists $params->{hostnames}) {
        foreach my $host (@{$params->{hostnames}}) {
            $self->addHost($domainName, $host);
        }

    }

}

# Method: addHost
#
#   Adds a new host to the domain
#
# Parameters:
#
#   domain - The domain where the host will be added
#   host - A hash ref containing:
#               name - The name
#               ipAddresses - Array ref containing the ips
#               aliases  - (optional) Array ref containing the aliases
#               readOnly - (optional)
#
sub addHost
{
    my ($self, $domain, $host) = @_;

    unless (defined $domain) {
        throw EBox::Exceptions::MissingArgument('domain');
    }

    unless ($host->{name}) {
        throw EBox::Exceptions::MissingArgument('name');
    }

    unless (defined $host->{ipAddresses} and scalar @{$host->{ipAddresses}} > 0) {
        throw EBox::Exceptions::MissingArgument('ipAddresses');
    }

    EBox::debug('Adding host record');
    my $domainRow = $self->_getDomainRow($domain);
    my $hostModel = $domainRow->subModel('hostnames');
    my $hostRowId = $hostModel->addRow(hostname => $host->{name},
                                       readOnly => $host->{readOnly});
    my $hostRow   = $hostModel->row($hostRowId);

    my $ipModel = $hostRow->subModel('ipAddresses');
    foreach my $ip (@{$host->{ipAddresses}}) {
        EBox::debug('Adding host ip');
        $ipModel->addRow(ip => $ip);
    }
    my $aliasModel = $hostRow->subModel('alias');
    foreach my $alias (@{$host->{aliases}}) {
        EBox::debug('Adding host alias');
        $aliasModel->addRow(alias => $alias);
    }
}

# Method: delHost
#
#   Deletes a host from the domain
#
# Parameters:
#
#   domain - The domain where lookup the host
#   name   - The host name to delete
#
sub delHost
{
    my ($self, $domain, $name) = @_;

    unless (defined $domain) {
        throw EBox::Exceptions::MissingArgument('domain');
    }

    unless (defined $name) {
        throw EBox::Exceptions::MissingArgument('name');
    }

    my $domainRow = $self->_getDomainRow($domain);
    my $hostsModel = $domainRow->subModel('hostnames');
    my $hostRow = $hostsModel->find(hostname => $name);
    if (defined $hostRow) {
        my $rowId = $hostRow->id();
        EBox::debug("Deleting host '$name' from domain '$domain'");
        $hostsModel->removeRow($rowId);
    } else {
        throw EBox::Exceptions::DataNotFound(data => $name, value => $name);
    }
}

# Method: addHostAlias
#
# Parameters:
# - domain
# - hostname
# - alias : can be a string or a list of string to add more then one alias
#
# Warning:
# alias is added to the first found matching hostname
sub addHostAlias
{
    my ($self, $domain, $hostname, $alias) = @_;
    $domain or
        throw EBox::Exceptions::MissingArgument('domain');
    $hostname or
        throw EBox::Exceptions::MissingArgument('hostname');
    $alias or
        throw EBox::Exceptions::MissingArgument('alias');

    my $domainRow = $self->_getDomainRow($domain);
    my $hostsModel = $domainRow->subModel('hostnames');
    my $hostRow = $hostsModel->find(hostname => $hostname);
    if (not $hostRow) {
        throw EBox::Exceptions::DataNotFound(data => $hostname, value => $hostname);
    }

    my $aliasModel = $hostRow->subModel('alias');
    my @aliases = ref $alias eq 'ARRAY' ? @{ $alias } : ($alias);
    foreach my $alias (@aliases) {
        EBox::debug('Adding host alias $alias');
        $aliasModel->addRow(alias => $alias);
    }
}

# Method: addService
#
#   Add a new SRV record to the domain
#
# Parameters:
#
#   domain  - The domain where the record will be added
#   service - A hash ref containing:
#             service  - The name of the service, must match a name in /etc/services
#             protocol - 'tcp' or 'udp'
#             port     - (port number)
#             target_type - custom or hostDomain
#             target   - The name of a host domain or a FQDN
#             priority - (optional)
#             weight   - (optional)
#             readOnly - (optional)
#
sub addService
{
    my ($self, $domain, $service) = @_;

    unless (defined ($domain)) {
        throw EBox::Exceptions::MissingArgument('domain');
    }

    unless (defined ($service->{priority})) {
        $service->{priority} = 0;
    }

    unless (defined ($service->{weight})) {
        $service->{weight} = 0;
    }

    my $domainRow = $self->_getDomainRow($domain);
    my $model = $domainRow->subModel('srv');
    my %params = (service_name => $service->{service},
                  protocol => $service->{protocol},
                  priority => $service->{priority},
                  weight => $service->{weight},
                  port => $service->{port});

    if ($service->{target_type} eq 'domainHost' ) {
        $params{hostName_selected} = 'ownerDomain';
        my $hostsModel = $domainRow->subModel('hostnames');
        my $ids = $hostsModel->ids();
        foreach my $id (@{$ids}) {
            my $row = $hostsModel->row($id);
            my $rowHostName = $row->valueByName('hostname');
            if ($rowHostName eq $service->{target}) {
                $params{ownerDomain} = $id;
                last;
            }
        }
        unless (defined $params{ownerDomain}) {
            throw EBox::Exceptions::DataNotFound(
                    data  => 'hostname',
                    value => $service->{target});
        }
    } elsif ($service->{target_type} eq 'custom' ) {
        $params{hostName_selected} = 'custom';
        $params{custom} = $service->{target};
    } else {
        throw EBox::Exceptions::MissingArgument('target_type');
    }

    EBox::debug('Adding SRV record');
    $model->addRow(%params, readOnly => $service->{readOnly});
}

# Method: delService
#
#   Deletes a SRV record from the domain
#
# Parameters:
#
#   domain  - The domain name where lookup the record to delete
#   service - A hash ref containing the attributes to check for deletion:
#             service_name
#             protocol
#             priority
#             weitht
#             port
#
sub delService
{
    my ($self, $domain, $service) = @_;

    if (not defined ($service->{service})) {
        throw EBox::Exceptions::MissingArgument('service');
    }

    my $rowId = undef;
    my $domainRow = $self->_getDomainRow($domain);
    my $model = $domainRow->subModel('srv');
    foreach my $id (@{$model->ids()}) {
        my $row = $model->row($id);

        my $rowService  = $row->valueByName('service_name');
        my $rowProtocol = $row->valueByName('protocol');
        my $rowPriority = $row->valueByName('priority');
        my $rowWeight   = $row->valueByName('weight');
        my $rowPort     = $row->valueByName('port');

        if ((not defined ($service->{service})   or $rowService  eq $service->{service})   and
            (not defined ($service->{protocol})  or $rowProtocol eq $service->{protocol})  and
            (not defined ($service->{priority})  or $rowPriority eq $service->{priority})  and
            (not defined ($service->{weight})    or $rowWeight   eq $service->{weight})    and
            (not defined ($service->{port})      or $rowPort     eq $service->{port})) {
                $rowId = $id;
                last;
        }
    }

    if (defined ($rowId)) {
        EBox::debug('Removing SRV record');
        $model->removeRow($rowId);
    } else {
        throw EBox::Exceptions::DataNotFound(data => 'service_name', value => $service->{service});
    }
}

# Method: addText
#
#   Add a new TXT record to the domain
#
# Parameters:
#
#   domain - The domain name where the record will be added
#   txt    - A hash ref containing:
#            name -
#            data -
#            readOnly - (optional)
#
sub addText
{
    my ($self, $domain, $txt) = @_;

    unless (defined ($domain)) {
        throw EBox::Exceptions::MissingArgument('domain');
    }

    my $domainRow = $self->_getDomainRow($domain);
    my $model = $domainRow->subModel('txt');
    my $id = $model->findRow(hostName => $txt->{name},
                             txt_data => $txt->{data});
    unless ($id) {
        my %params = ( hostName_selected => 'custom',
                       custom   => $txt->{name},
                       txt_data => $txt->{data} );
        EBox::debug('Adding TXT record');
        $model->addRow( %params, readOnly => $txt->{readOnly});
    }
}

# Method: delText
#
#   Deletes a TXT record from the domain
#
# Parameters:
#
#   domain - The domain name where lookup the record to delete
#   txt    - A hash ref containing the values to check for delete
#            name - The record name
#            data - The record value
#
sub delText
{
    my ($self, $domain, $txt) = @_;

    unless (defined ($domain)) {
        throw EBox::Exceptions::MissingArgument('domain');
    }

    unless (defined $txt->{name}) {
        throw EBox::Exceptions::MissingArgument('name');
    }

    my $rowId = undef;
    my $domainRow = $self->_getDomainRow($domain);
    my $model = $domainRow->subModel('txt');
    foreach my $id (@{$model->ids()}) {
        my $row = $model->row($id);

        my $rowName = $row->valueByName('hostName');
        my $rowData = $row->valueByName('txt_data');

        if ((not defined ($txt->{name})  or $rowName  eq $txt->{name})  and
            (not defined ($txt->{data})  or $rowData  eq $txt->{data})) {
            $rowId = $id;
            last;
        }
    }

    if (defined ($rowId)) {
        EBox::debug('Removing TXT record');
        $model->removeRow($rowId);
    } else {
        throw EBox::Exceptions::DataNotFound(data => 'hostname', value => $txt->{name});
    }
}

# Method: addedRowNotify
#
#    Override to:
#    - Add the NS and A records
#    - Generate the shared key. It is always generated but
#      only used by dynamic zones
#
# Overrides:
#
#    <EBox::Model::DataTable::addedRowNotify>
#
sub addedRowNotify
{
    my ($self, $newRow) = @_;

    # Generate the TSIG key
    my $secret = $self->_generateSecret();
    $newRow->elementByName('tsigKey')->setValue($secret);
    $newRow->store();

    # Add the domain IP addresses
    my $network = EBox::Global->modInstance('network');
    my $internalIpAddresses = $network->internalIpAddresses();
    my $ipModel = $newRow->subModel('ipAddresses');
    foreach my $ip (@{$internalIpAddresses}) {
        EBox::debug('Adding domain IP');
        $ipModel->addRow(ip => $ip);
    }

    # Generate the NS record and its A record
    my $nsHost = $self->parentModule()->NameserverHost();

    my $hostModel = $newRow->subModel('hostnames');
    my $hostRowId = $hostModel->addRow(hostname => $nsHost);
    my $hostRow   = $hostModel->row($hostRowId);

    $ipModel = $hostRow->subModel('ipAddresses');
    foreach my $ip (@{$internalIpAddresses}) {
        EBox::debug('Adding host IP');
        $ipModel->addRow(ip => $ip);
    }

    EBox::debug('Adding name server');
    my $nsModel = $newRow->subModel('nameServers');
    $nsModel->add(hostName => { ownerDomain => $nsHost } );

    my $addrs = join(', ', @{$internalIpAddresses});
    $self->setMessage(__x('Domain added. The host name {nshost} has been added to this domain with '
                          . 'these IP addresses {ips}, this host name has been also set as '
                          . 'nameserver record. Moreover, the same IP addresses have been assigned '
                          . 'to this new domain. You can always rename it or create alias for it.',
                          nshost => $nsHost, ips => $addrs));

}


# Group: Protected methods

sub _table
{
    my @tableHead =
        (

            new EBox::Types::DomainName
                            (
                                'fieldName' => 'domain',
                                'printableName' => __('Domain'),
                                'size' => '20',
                                'unique' => 1,
                                'editable' => 1
                             ),
            new EBox::Types::HasMany
                            (
                                'fieldName' => 'ipAddresses',
                                'printableName' => __("Domain IP Addresses"),
                                'foreignModel' => 'DomainIpTable',
                                'view' => '/DNS/View/DomainIpTable',
                                'backView' => '/DNS/View/DomainTable',
                                'size' => '1',
                             ),
            new EBox::Types::HasMany
                            (
                                'fieldName' => 'hostnames',
                                'printableName' => __('Hostnames'),
                                'foreignModel' => 'HostnameTable',
                                'view' => '/DNS/View/HostnameTable',
                                'backView' => '/DNS/View/DomainTable',
                                'size' => '1',
                             ),
            new EBox::Types::HasMany
                            (
                                'fieldName' => 'mailExchangers',
                                'printableName' => __('Mail Exchangers'),
                                'foreignModel' => 'MailExchanger',
                                'view' => '/DNS/View/MailExchanger',
                                'backView' => '/DNS/View/DomainTable',
                             ),
            new EBox::Types::HasMany
                            (
                                'fieldName' => 'nameServers',
                                'printableName' => __('Name Servers'),
                                'foreignModel' => 'NameServer',
                                'view' => '/DNS/View/NameServer',
                                'backView' => '/DNS/View/DomainTable',
                             ),
            new EBox::Types::HasMany
                            (
                                'fieldName' => 'txt',
                                'printableName' => __x('{txt} records', txt => 'TXT'),
                                'foreignModel' => 'Text',
                                'view' => '/DNS/View/Text',
                                'backView' => '/DNS/View/Text',
                             ),
            new EBox::Types::HasMany
                            (
                                'fieldName' => 'srv',
                                'printableName' => __x('Services'),
                                'foreignModel' => 'Services',
                                'view' => '/DNS/View/Services',
                                'backView' => '/DNS/View/Services',
                             ),
            new EBox::Types::Text(
                # This field indicates if the domain is static, dynamic or dlz
                # Not editable from interface
                                'fieldName'      => 'type',
                                'printableName'  => __('Dynamic domain'),
                                'editable'       => 0,
                                #'hiddenOnViewer' => 0,
                                #'hiddenOnSetter' => 1,
                                defaultValue   => EBox::DNS::STATIC_ZONE(),
                                'HTMLViewer'     => '/dns/ajax/viewer/domainTypeViewer.mas',
                                ),
            new EBox::Types::Text(
                # This field is filled when the zone is dynamic and
                # indicates the TSIG key for the direct mapping and
                # the reversed zones for this domain hosts
                                'fieldName'    => 'tsigKey',
                                'editable'     => 0,
                                'optional'     => 1,
                                'hidden'       => 1,
                               ),
            new EBox::Types::Text(
                fieldName => 'dlzDbPath',
                printableName => __('DLZ database path'),
                editable => 0,
                optional => 1,
                hidden => 1,
            ),
          );

    my $dataTable =
        {
            'tableName' => 'DomainTable',
            'printableTableName' => __('Domains'),
            'automaticRemove' => 1,
            'defaultController' => '/Dns/Controller/DomainTable',
            'HTTPUrlView'=> 'DNS/Composite/Global',
            'defaultActions' => ['add', 'del', 'editField',  'changeView' ],
            'tableDescription' => \@tableHead,
            'class' => 'dataTable',
            'printableRowName' => __('domain'),
            'sortedBy' => 'domain',
            'help' => __('Here you can add the domains for this DNS server. '
                       . 'Each domain can have different hostnames with aliases '
                       . ' (A and CNAME) and other special records (MX, NS, TXT and SRV).'),
        };

    return $dataTable;
}

# Group: Private methods

# Generate the secret key using HMAC-MD5 algorithm
sub _generateSecret
{
    my ($self) = @_;

    Crypt::OpenSSL::Random::random_seed(time() . rand(2**512));
    Crypt::OpenSSL::Random::random_egd('/dev/urandom');

    # Generate a key of 512 bits = 64Bytes
    return MIME::Base64::encode(Crypt::OpenSSL::Random::random_bytes(64), '');
}

# Method: _getDomainRow
#
#   Return the row for the specified domain name
#
# Throws:
#
#   DataNotFoundException
#
sub _getDomainRow
{
    my ($self, $domain) = @_;

    my $domainRow = undef;
    foreach my $id (@{$self->ids()}) {
        my $row = $self->row($id);
        my $rowDomain = $row->valueByName('domain');
        if ($rowDomain eq $domain) {
            $domainRow = $row;
            last;
        }
    }

    unless (defined ($domainRow)) {
        throw EBox::Exceptions::DataNotFound(data => 'domain', value => $domain);
    }

    return $domainRow;
}

1;
