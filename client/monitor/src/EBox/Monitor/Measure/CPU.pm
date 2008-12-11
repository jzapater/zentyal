# Copyright 2008 (C) eBox Technologies S.L.
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

# Class: EBox::Monitor::Measure::CPU
#
#     This measure collects the cpu usage stats
#

package EBox::Monitor::Measure::CPU;

use strict;
use warnings;

use base qw(EBox::Monitor::Measure::Base);

use EBox::Gettext;
use Sys::CPU;

# Constructor: new
#
sub new
{
    my ($class, @params) = @_;

    my $self = $class->SUPER::new(@params);
    bless($self, $class);

    return $self;
}

# Group: Protected methods

# Method: _description
#
#       Gives the description for the measure
#
# Returns:
#
#       hash ref - the description
#
sub _description
{
    my ($self) = @_;

    my $cpuNo = Sys::CPU::cpu_count();
    my @realms = map { "cpu-$_" } 0 .. $cpuNo - 1;
    my @rrds  = qw(cpu-idle.rrd cpu-user.rrd cpu-interrupt.rrd cpu-nice.rrd
                   cpu-softirq.rrd cpu-steal.rrd cpu-system.rrd
                   cpu-wait.rrd);

    return {
        printableName => __('CPU usage'),
        help          => __('Collect the amount of time spent by the CPU '
                            . 'in various states, most notably executing '
                            . 'user code, executing system code, waiting '
                            . 'for IO operations and being idle'),
        realms          => \@realms,
        rrds            => \@rrds,
        printableLabels => [ __('idle'), __('user'), __('interrupt'),
                             __('nice'), __('soft interrupt'), __('steal'),
                             __('system'), __('wait') ],
        type            => 'int',
    };
}

1;
