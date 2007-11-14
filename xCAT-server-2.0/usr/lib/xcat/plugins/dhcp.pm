# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::dhcp;
use xCAT::Table;
use Data::Dumper;
use MIME::Base64;
use Socket;
use Sys::Syslog;
use IPC::Open2;

my @dhcpconf; #Hold DHCP config file contents to be written back.
my @nrn; # To hold output of netstat -rn to be consulted throughout process
my $domain;
my $omshell;


sub handled_commands {
  return {
    makedhcp => "dhcp",
  }
}
  
sub delnode {
  my $node = shift;
  my $inetn = inet_aton($node);

  print $omshell "new host\n";
  print $omshell "set name = \"$node\"\n"; #Find and destroy conflict name
  print $omshell "open\n";
  print $omshell "remove\n";
  print $omshell "close\n";
  if ($inetn) {
    my $ip = inet_ntoa(inet_aton($node));;
    unless ($ip) { return; }
    print $omshell "new host\n";
    print $omshell "set ip-address = $ip\n"; #find and destroy ip conflict
    print $omshell "open\n";
    print $omshell "remove\n";
    print $omshell "close\n";
  }
}


sub addnode {
#Use omshell to add the node.
#the process used is blind typing commands that should work
#it tries to delet any conflicting entries matched by name and 
#hardware address and ip address before creating a brand now one
#unfortunate side effect: dhcpd.leases can look ugly over time, when
#doing updates would keep it cleaner, good news, dhcpd restart cleans
#up the lease file the way we would want anyway.
  my $node = shift;
  my $ent;
  my $mactab = xCAT::Table->new('mac');
  unless ($mactab) { return; } #TODO: report error sanely
  $ent = $mactab->getNodeAttribs($node,[qw(mac interface)]);
  unless ($ent and $ent->{mac}) {
    return; #TODO: sane error
  }
  my $inetn = inet_aton($node);
  unless ($inetn) {
    syslog("local1|err","xCAT DHCP plugin unable to resolve IP for $node");
    return;
  }
  my $ip = inet_ntoa(inet_aton($node));;
  print "Setting $node ($ip) to ".$ent->{mac}."\n";
  print $omshell "new host\n";
  print $omshell "set name = \"$node\"\n"; #Find and destroy conflict name
  print $omshell "open\n";
  print $omshell "remove\n";
  print $omshell "close\n";
  print $omshell "new host\n";
  print $omshell "set ip-address = $ip\n"; #find and destroy ip conflict
  print $omshell "open\n";
  print $omshell "remove\n";
  print $omshell "close\n";
  print $omshell "new host\n";
  print $omshell "set hardware-address = ".$ent->{mac}."\n"; #find and destroy mac conflict
  print $omshell "open\n";
  print $omshell "remove\n";
  print $omshell "close\n";
  print $omshell "new host\n";
  print $omshell "set name = \"$node\"\n";
  print $omshell "set hardware-address = ".$ent->{mac}."\n";
  print $omshell "set hardware-type = 1\n";
  print $omshell "set ip-address = $ip\n";
  print $omshell "create\n";
  unless (grep /#definition for host $node/,@dhcpconf) {
    push @dhcpconf,"#definition for host $node can be found in the dhcpd.leases file\n";
  }
}
sub process_request {
  my $req = shift;
  my $callback = shift;
  my $sitetab = xCAT::Table->new('site');
  my %activenics;
  my $querynics=1;
  if ($sitetab) {
    my $href;
    ($href) = $sitetab->getAttribs({key=>'dhcpinterfaces'},'value');
    unless ($href and $href->{value}) { #LEGACY: singular keyname for old style site value
      ($href) = $sitetab->getAttribs({key=>'dhcpinterface'},'value');
    }
    if ($href and $href->{value}) {
      foreach (split /[,\s]+/,$href->{value}) {
        $activenics{$_} = 1;
        $querynics=0;
      }
    }
    ($href) = $sitetab->getAttribs({key=>'domain'},'value');
    unless ($href and $href->{value}) {
      $callback->({error=>["No domain defined in site tabe"],errorcode=>[1]});
      return;
    }
    $domain = $href->{value};
  }

  @dhcpconf = ();
  unless ($req->{arg} or $req->{node}) {
      $callback->({data=>["Usage: makedhcp <-n> <noderange>"]});
      return;
  }
  if (grep /-n/,@{$req->{arg}}) {
    if (-e "/etc/dhcpd.conf") {
      my $bakname = "/etc/dhcpd.conf.xcatbak";
      while (-e $bakname) { #look for unused backup name..
        $bakname .= "~";
      }
      rename("/etc/dhcpd.conf",$bakname);
    }
  } else {
    open($rconf,"/etc/dhcpd.conf"); # Read file into memory
    if ($rconf) {
      while (<$rconf>) {
        push @dhcpconf,$_;
      }
      close($rconf);
    }
    unless ($dhcpconf[0] =~ /^#xCAT/) { #Discard file if not xCAT originated, like 1.x did
      @dhcpconf = ();
    }
  }
  @nrn = split /\n/,`/bin/netstat -rn`;
  splice @nrn,0,2; #get rid of header
  if ($querynics) { #Use netstat to determine activenics only when no site ent.
    foreach (@nrn) {
      my @ent = split /\s+/;
      if ($ent[7] =~ m/(ipoib|ib|vlan|bond|eth|myri|man|wlan)/) { #Mask out many types of interfaces, like xCAT 1.x
        $activenics{$ent[7]} = 1;
      }
    }
  }
  unless ($dhcpconf[0]) { #populate an empty config with some starter data...
    newconfig();
  }
  foreach (keys %activenics) {
    addnic($_);
  }
  if ($req->{node}) {
    my $passtab = xCAT::Table->new('passwd');
    my $ent;
    ($ent) = $passtab->getAttribs({key=>"omapi"},qw(username password));
    unless ($ent->{username} and $ent->{password}) { return; } # TODO sane err
    #Have nodes to update
    #open2($omshellout,$omshell,"/usr/bin/omshell");
    open($omshell,"|/usr/bin/omshell > /dev/null");
    
    print $omshell "key ".$ent->{username}." \"".$ent->{password}."\"\n";
    print $omshell "connect\n";
    foreach(@{$req->{node}}) {
      if (grep /^-d$/,@{$req->{arg}}) {
        delnode $_;
      } else { 
        addnode $_;
      }
    }
    close($omshell);
  }
  foreach (@nrn) {
    my @line = split /\s+/;
    if ($activenics{$line[7]} and $line[3] !~ /G/) {
      addnet($line[0],$line[2]);
    }
  }
  writeout();
}

sub addnet {
  my $net = shift;
  my $mask = shift;
  my $nic;
  unless (grep /\} # $net\/$mask subnet_end/,@dhcpconf) {
    foreach (@nrn) { # search for relevant NIC
      my @ent = split /\s+/;
      if  ($ent[0] eq $net and $ent[2] eq $mask) {
        $nic=$ent[7];
      }
    }
    print "Need to add $net $mask under $nic\n";
    my $idx=0;
    while ($idx <= $#dhcpconf) {
      if ($dhcpconf[$idx] =~ /\} # $nic nic_end\n/) {
        last;
      }
      $idx++;
    }
    unless ($dhcpconf[$idx] =~ /\} # $nic nic_end\n/) {
      return 1; #TODO: this is an error condition
    }
    # if here, means we found the idx before which to insert
    my $nettab = xCAT::Table->new("networks");
    my $nameservers;
    my $gateway;
    my $tftp;
    my $range;
    if ($nettab) {
      my ($ent) = $nettab->getAttribs({net=>$net,mask=>$mask},qw(tftpserver nameservers gateway dynamicrange));
      if ($ent and $ent->{nameservers}) {
        $nameservers = $ent->{nameservers};
      }
      if ($ent and $ent->{tftpserver}) {
        $tftp = $ent->{tftpserver};
      }
      if ($ent and $ent->{gateway}) {
        $gateway = $ent->{gateway};
      }
      if ($ent and $ent->{dynamicrange}) {
        $range = $ent->{dynamicrange};
        $range =~ s/[,-]/ /g;
      }
    }
    my @netent;
    @netent = (
      "  subnet $net netmask $mask {\n",
      "    max-lease-time 43200;\n",
      "    min-lease-time 43200;\n",
      "    default-lease-time 43200;\n"
      );
    if ($gateway) {
      push @netent,"    option routers  $gateway;\n";
    }
    if ($tftp) {
      push @netent,"    next-server  $tftp;\n";
    }
    push @netent,"    option domain-name \"$domain\";\n";
    if ($nameservers) {
      push @netent,"    option domain-name-servers  $nameservers;\n";
    }
    push @netent,"    if option client-architecture = 00:00  { #x86\n";
    push @netent,"      filename \"pxelinux.0\";\n";
    push @netent,"    } else if option client-architecture = 00:02 { #ia64\n ";
    push @netent,"      filename \"elilo.efi\";\n";
    push @netent,"    } else if substring(filename,0,1) = null { #otherwise, provide yaboot if the client isn't specific\n ";
    push @netent,"      filename \"/yaboot\";\n";
    push @netent,"    }\n";
    if ($range) { push @netent,"    range dynamic-bootp $range;\n" };
    push @netent,"  } # $net\/$mask subnet_end\n";
    splice(@dhcpconf,$idx,0,@netent);
  }
}




sub addnic {
  my $nic = shift;
  my $firstindex=0;
  my $lastindex=0;
  unless (grep /} # $nic nic_end/,@dhcpconf) { #add a section if not there
    print "Adding NIC $nic\n";
    push @dhcpconf,"shared-network $nic {\n";
    push @dhcpconf,"\} # $nic nic_end\n";
  }
    #return; #Don't touch it, it should already be fine..
    #my $idx=0;
    #while ($idx <= $#dhcpconf) {
    #  if ($dhcpconf[$idx] =~ /^shared-network $nic {/) {
    #    $firstindex = $idx; # found the first place to chop...
    #  } elsif ($dhcpconf[$idx] =~ /} # $nic network_end/) {
    #    $lastindex=$idx;
    #  }
    #  $idx++;
    #}
    #print Dumper(\@dhcpconf);
    #if ($firstindex and $lastindex) {
    #  splice @dhcpconf,$firstindex,($lastindex-$firstindex+1);
    #}
    #print Dumper(\@dhcpconf);
}


sub writeout {
  my $targ;
  open($targ,'>',"/etc/dhcpd.conf");
  foreach (@dhcpconf) {
    print $targ $_;
  }
  close($targ)
}

sub newconfig {
# This function puts a standard header in and enough to make omapi work.
  my $passtab = xCAT::Table->new('passwd',-create=>1);
  push @dhcpconf,"#xCAT generated dhcp configuration\n";
  push @dhcpconf,"\n";
  push @dhcpconf,"authoritative;\n";
  push @dhcpconf,"ddns-update-style none;\n";
  push @dhcpconf,"option client-architecture code 93 = unsigned integer 16;\n";
  push @dhcpconf,"\n";
  push @dhcpconf,"omapi-port 7911;\n"; #Enable omapi...
  push @dhcpconf,"key xcat_key {\n";
  push @dhcpconf,"  algorithm hmac-md5;\n";
  my $secret = encode_base64(genpassword(32)); #Random from set of  62^32 
  chomp $secret;
  $passtab->setAttribs({key=>omapi},{username=>'xcat_key',password=>$secret});
  push @dhcpconf,"  secret \"".$secret."\";\n";
  push @dhcpconf,"};\n";
  push @dhcpconf,"omapi-key xcat_key;\n";
}

sub genpassword {
#Generate a pseudo-random password of specified length
  my $length = shift;
  my $password='';
  my $characters= 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01234567890';
  srand; #have to reseed, rand is not rand otherwise
  while (length($password) < $length) {
    $password .= substr($characters,int(rand 63),1);
  }
  return $password;
}


1;
