# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::PPCcli;
require Exporter;
    @ISA = qw(Exporter);
    @EXPORT_OK = qw(SUCCESS RC_ERROR EXPECT_ERROR NR_ERROR);  
use strict;
use xCAT::PPCdb;
use Expect;


#############################################
# Removes Ctrl characters from term output
#############################################
$ENV{'TERM'} = "vt100";

##############################################
# Constants 
##############################################
use constant {
  SUCCESS      => 0,
  RC_ERROR     => 1,
  EXPECT_ERROR => 2,
  NR_ERROR     => 3
};

##############################################
# lssyscfg supported formats 
##############################################
my %lssyscfg = (
  fsp    =>"lssyscfg -r sys -m %s -F %s",
  fsps   =>"lssyscfg -r sys -F %s",
  node   =>"lssyscfg -r lpar -m %s -F %s --filter lpar_ids=%s",
  lpar   =>"lssyscfg -r lpar -m %s -F %s",
  bpa    =>"lssyscfg -r frame -e %s -F %s",
  bpas   =>"lssyscfg -r frame -F %s",
  prof   =>"lssyscfg -r prof -m %s --filter lpar_ids=%s",
  cage   =>"lssyscfg -r cage -e %s -F %s"
);

##############################################
# Power control supported formats 
##############################################
my %powercmd = (
  hmc  => {
      reset =>"hmcshutdown -t now -r" },
  ivm  => {
      reset =>"reboot" },
  lpar => { 
      on    =>"chsysstate -r %s -m %s -o on -b norm --id %s -f %s",
      of    =>"chsysstate -r %s -m %s -o on --id %s -f %s -b of",
      reset =>"chsysstate -r %s -m %s -o shutdown --id %s --immed --restart",
      off   =>"chsysstate -r %s -m %s -o shutdown --id %s --immed",
      boot  =>"undetermined" },
  sys  => { 
      reset =>"chsysstate -r %s -m %s -o off --immed --restart",
      on    =>"chsysstate -r %s -m %s -o on",
      off   =>"chsysstate -r %s -m %s -o off",
      boot  =>"undetermined" }
);



##########################################################################
# Logon to remote server
##########################################################################
sub connect {

    my $hwtype     = shift;
    my $server     = shift;
    my $verbose    = shift;
    my $pwd_prompt = 'assword: $';
    my $continue   = 'continue connecting (yes/no)?';
    my $timeout    = 10;
    my $success    = 0;
    my $pwd_sent   = 0;

    ##################################################
    # Shell prompt regexp based on HW Type 
    ##################################################
    my %prompt = (
        hmc => "~> \$",
        ivm => "\\\$ \$"
    );
    ##################################################
    # Get userid/password based on Hardware Conrol Pt 
    ##################################################
    my @cred = xCAT::PPCdb::credentials( $server, $hwtype );

    ##################################################
    # ssh to remote host
    ##################################################
    my $parameters = "$cred[0]\@$server";
    my $ssh = new Expect;

    ##################################################
    # raw_pty() disables command echoing and CRLF
    # translation and gives a more pipe-like behaviour.
    # Note that this must be set before spawning
    # the process. Unfortunately, this does not work
    # with AIX (IVM). stty(qw(-echo)) will at least
    # disable command echoing on all platforms but
    # will not suppress CRLF translation.
    ##################################################
    #$ssh->raw_pty(1);
    $ssh->slave->stty(qw(sane -echo));

    ##################################################
    # exp_internal(1) sets exp_internal debugging.
    # This is similar in nature to its Tcl counterpart
    ##################################################
    if ( $verbose ) {
        $ssh->exp_internal(1);
    }
    ##################################################
    # log_stdout(0) disables logging to STDOUT. This
    # corresponds to the Tcl log_user variable.
    ##################################################
    if ( !$verbose ) {
        $ssh->log_stdout(0);
    }
    unless ( $ssh->spawn( "ssh", $parameters )) {
        return( "Unable to spawn ssh connection to server" );
    }
    ##################################################
    # -re $continue
    #  "The authenticity of host can't be established
    #   RSA key fingerprint is ....
    #   Are you sure you want to continue connecting (yes/no)?"
    #
    # -re pwd_prompt 
    #   If the keys have already been transferred, we
    #   may already be at the command prompt without
    #   sending the password.
    #
    ##################################################
    my @result = $ssh->expect( $timeout,
        [ $continue,
           sub {
             $ssh->send( "yes\r" );
             $ssh->clear_accum();
             $ssh->exp_continue();
           } ],
        [ $pwd_prompt, 
           sub {
             if ( ++$pwd_sent == 1 ) {
               $ssh->send( "$cred[1]\r" );
               $ssh->exp_continue();
             }
           } ],
        [ $prompt{$hwtype},
           sub {
             $success = 1;
           } ]
    );
    ##########################################
    # Expect error
    ##########################################
    if ( defined( $result[1] )) {
        $ssh->hard_close();
        return( expect_error(@result) );
    }
    ##########################################
    # Successful logon....
    # Return:
    #    Expect
    #    HW Shell Prompt regexp
    #    HW Type (hmc/ivm)
    #    Server hostname
    #    UserId
    #    Password
    ##########################################
    if ( $success ) {
        return( $ssh,
                $prompt{$hwtype},
                $hwtype,
                $server,
                $cred[0],
                $cred[1] );
    }
    ##########################################
    # Failed logon - kill ssh process
    ##########################################
    $ssh->hard_close();
    return( "Invalid userid/password" );
}


##########################################################################
# Logoff to remote server
##########################################################################
sub disconnect {

    my $exp = shift;
    my $ssh = @$exp[0];

    $ssh->send( "exit\r" );
    $ssh->hard_close();

}


##########################################################################
# List attributes for resources (lpars, managed system, etc)
##########################################################################
sub lssyscfg {

    my $exp = shift;
    my $res = shift;
    my $d1  = shift;
    my $d2  = shift;
    my $d3  = shift;

    ###################################
    # Select command  
    ###################################
    my $cmd = sprintf( $lssyscfg{$res}, $d1, $d2, $d3 );

    ###################################
    # Send command
    ###################################
    my $result = send_cmd( $exp, $cmd );
    return( $result );
}


##########################################################################
# Changes a logical partition configuration data
##########################################################################
sub chsyscfg {

    my $exp     = shift;
    my $d       = shift;
    my $cfgdata = shift;
    my $timeout = 60;

    #####################################
    # Command only support on LPARs 
    #####################################
    if ( @$d[4] ne "lpar" ) {
        return( [RC_ERROR,"Command not supported"] );
    }
    #####################################
    # Format command based on CEC name
    #####################################
    my $cmd = "chsyscfg -r prof -m @$d[2] -i \"$cfgdata\""; 

    #####################################
    # Send command
    #####################################
    my $result = send_cmd( $exp, $cmd, $timeout );
    return( $result );
}


##########################################################################
# Creates a logical partition on the managed system 
##########################################################################
sub mksyscfg {

    my $exp     = shift;
    my $d       = shift;
    my $cfgdata = shift;
    my $timeout = 60;

    #####################################
    # Command only support on LPARs 
    #####################################
    if ( @$d[4] ne "lpar" ) {
        return( [RC_ERROR,"Command not supported"] );
    }
    #####################################
    # Format command based on CEC name
    #####################################
    my $cmd = "mksyscfg -r lpar -m @$d[2] -i \"$cfgdata\""; 

    #####################################
    # Send command
    #####################################
    my $result = send_cmd( $exp, $cmd, $timeout );
    return( $result );
}


##########################################################################
# Removes a logical partition on the managed system
##########################################################################
sub rmsyscfg {

    my $exp     = shift;
    my $d       = shift;
    my $timeout = 60;

    #####################################
    # Command only supported on LPARs 
    #####################################
    if ( @$d[4] ne "lpar" ) {
        return( [RC_ERROR,"Command not supported"] );
    }
    #####################################
    # Format command based on CEC name
    #####################################
    my $cmd = "rmsyscfg -r lpar -m @$d[2] --id @$d[0]";

    #####################################
    # Send command
    #####################################
    my $result = send_cmd( $exp, $cmd, $timeout );
    return( $result );
}


##########################################################################
# Lists environmental information 
##########################################################################
sub lshwinfo {

    my $exp    = shift;
    my $res    = shift;
    my $frame  = shift;
    my $filter = shift;

    #####################################
    # Format command based on CEC name
    #####################################
    my $cmd = "lshwinfo -r $res -e $frame -F $filter";

    #####################################
    # Send command
    #####################################
    my $result = send_cmd( $exp, $cmd );
    return( $result );
}


##########################################################################
# Changes the state of a partition or managed system
##########################################################################
sub chsysstate {

    my $exp = shift;
    my $op  = shift;
    my $d   = shift;

    #####################################
    # Format command based on CEC name
    #####################################
    my $cmd = power_cmd( $op, $d );
    if ( !defined( $cmd )) {
        return( [RC_ERROR,"'$op' command not supported"] );
    }
    #####################################
    # Special case - return immediately 
    #####################################
    if ( $cmd =~ /^hmcshutdown|reboot/ ) {
        my $ssh = @$exp[0];

        $ssh->send( "$cmd\r" );
        return( [SUCCESS,"Success"] );
    }
    #####################################
    # Increase timeout for power command 
    #####################################
    my $timeout = 15; 

    #####################################
    # Send command
    #####################################
    my $result = send_cmd( $exp, $cmd, $timeout );
    return( $result );
}



##########################################################################
# Opens a virtual terminal session
##########################################################################
sub mkvterm { 

    my $exp     = shift;
    my $type    = shift;
    my $lparid  = shift;
    my $mtms    = shift;
    my $ssh     = @$exp[0];
    my $hwtype  = @$exp[2];
    my $failed  = 0;
    my $timeout = 3;

    ##########################################
    # Format command based on HW Type
    ##########################################
    my %mkvt = (
        hmc =>"mkvterm --id %s -m %s",
        ivm =>"mkvt -id %s" 
    );
    ##########################################
    # HMC returns:
    #  "A terminal session is already open
    #   for this partition. Only one open
    #   session is allowed for a partition.
    #   Exiting...."
    #
    # HMCs may also return:
    #  "The open failed. 
    #  "-The session may already be open on 
    #  another management console"
    #
    # But Expect (for some reason) sees each
    # character preceeded with \000 (blank??)
    #
    ##########################################
    my $ivm_open  = "Virtual terminal is already connected";
    my $hmc_open  = "\000o\000p\000e\000n\000 \000f\000a\000i\000l\000e\000d"; 
    my $hmc_open2 =
        "\000a\000l\000r\000e\000a\000d\000y\000 \000o\000p\000e\000n";

    ##########################################
    # Set command based on HW type
    #   mkvterm -id lparid -m cecmtms 
    ##########################################
    my $cmd = sprintf( $mkvt{$hwtype}, $lparid, $mtms );
    if ( $type ne "lpar" ) {
        return( [RC_ERROR,"Command not supported"] );
    }
    ##########################################
    # For IVM, console sessions must explicitly
    # be closed after each open using rmvt
    # or they will remain open indefinitely. 
    # For example, if the session is opened  
    # using xterm and closed with the [x] in 
    # the windows upper-right corner, we will
    # not be able to catch (INT,HUP,QUIT,TERM) 
    # before the window closes in order to 
    # send an rmvt - so force any IVM sessions
    # closed before we start. 
    #
    # For HMC, apparently, once the console
    # session connection is broken, the HMC
    # closes the session. Therefore, it is not
    # necessary to explicitly close the session.
    #
    ##########################################
    if ( $hwtype eq "ivm" ) {
        rmvterm( $exp, $lparid, $mtms );
        sleep 1;
    }
    ##########################################
    # Send command
    ##########################################
    $ssh->clear_accum();
    $ssh->send( "$cmd\r" );

    ##########################################
    # Expect result 
    ##########################################
    my @result = $ssh->expect( $timeout,
        [ "$hmc_open|$hmc_open2|$ivm_open",
           sub {
               $failed = 1; 
           } ]
    );

    if ( $failed ) {
        $ssh->hard_close();
        return( [RC_ERROR,"Virtual terminal is already connected"] );
    }

    ##########################################
    # Success...
    # Give control to the user and intercept
    # the Ctrl-X (\030), and "~." sequences.
    ##########################################
    my $escape = "\030|~.";
    $ssh->send( "\r" );
    $ssh->interact( \*STDIN, $escape );
    
    ##########################################
    # Close session
    ##########################################
    rmvterm( $exp, $lparid, $mtms );
    $ssh->hard_close();

    return( [SUCCESS,"Success"] );
}


##########################################################################
# Force close a virtual terminal session
##########################################################################
sub rmvterm {

    my $exp    = shift;
    my $lparid = shift;
    my $mtms   = shift;
    my $ssh    = @$exp[0];
    my $hwtype = @$exp[2];

    #####################################
    # Format command based on HW Type
    #####################################
    my %rmvt = (
        hmc =>"rmvterm --id %s -m %s",
        ivm =>"rmvt -id %s" 
    );
    #####################################
    # Set command based on HW type
    #   rmvt(erm) -id lparid -m cecmtms 
    #####################################
    my $cmd = sprintf( $rmvt{$hwtype}, $lparid, $mtms );

    #####################################
    # Send command
    #####################################
    $ssh->clear_accum();
    $ssh->send( "$cmd\r" );
}


##########################################################################
# Lists the hardware resources of a managed system 
##########################################################################
sub lshwres {

    my $exp   = shift;
    my $d     = shift;
    my $mtms  = shift;
    my $cmd   = "lshwres -r @$d[1] -m $mtms -F @$d[2]";
    my $level = @$d[0];
 
    #####################################
    # level may be "sys" or "lpar" 
    #####################################
    if ( defined( $level )) {
        $cmd .=" --level $level";
    }
    #####################################
    # Send command
    #####################################
    my $result = send_cmd( $exp, $cmd );
    return( $result );
}


##########################################################################
# Retrieve MAC-address from network adapter or network boots an LPAR
##########################################################################
sub lpar_netboot {

    my $exp     = shift;
    my $name    = shift;
    my $d       = shift;
    my $server  = shift;
    my $gateway = shift;
    my $client  = shift;
    my $mac     = shift;
    my $timeout = 300;
    my $cmd     = "lpar_netboot -t ent";

    #####################################
    # Get MAC-address or network boot
    #####################################
    $cmd.= (defined( $mac )) ? " -m $mac" : " -M -n";
   
    #####################################
    # Command only supported on LPARs
    #####################################
    if ( @$d[4] ne "lpar" ) {
        return( [RC_ERROR,"Command not supported"] );
    }
    #####################################
    # Network specified (-D ping test)
    #####################################
    if ( defined( $server )) {
        $cmd.= (!defined( $mac )) ? " -D" : "";
        $cmd.= " -s auto -d auto -S $server -G $gateway -C $client";
    }
    #####################################
    # Add lpar name, profile, CEC name 
    #####################################
    $cmd.= " \"$name\" \"@$d[1]\" \"@$d[2]\"";

    #####################################
    # Send command
    #####################################
    my $result = send_cmd( $exp, $cmd, $timeout );
    return( $result );
}


##########################################################################
# List Hardware Management Console configuration information 
##########################################################################
sub lshmc {

    my $exp     = shift;
    my $hwtype  = @$exp[2];
    my $timeout = 10;

    #####################################
    # Format command based on HW Type
    #####################################
    my %cmd = (
        hmc =>"lshmc -v",
        ivm =>"lsivm"
    );

    #####################################
    # Send command
    #####################################
    my $result = send_cmd( $exp, $cmd{$hwtype}, $timeout );

    #####################################
    # Return error
    #####################################
    if ( @$result[0] != SUCCESS ) {
        return( $result );
    }    
    #####################################
    # IVM returns:
    #   9133-55A,10B7D1G,1
    #
    # HMC returns: 
    #   "vpd=*FC ????????
    #   *VC 20.0
    #   *N2 Mon Sep 24 13:54:00 GMT 2007
    #   *FC ????????
    #   *DS Hardware Management Console
    #   *TM 7310-CR4
    #   *SE 1017E6B
    #   *MN IBM
    #   *PN Unknown
    #   *SZ 1058721792
    #   *OS Embedded Operating Systems
    #   *NA 9.114.222.111
    #   *FC ????????
    #   *DS Platform Firmware
    #   *RM V7R3.1.0.1
    #####################################
    if ( $hwtype eq "ivm" ) {
        my ($model,$serial,$lparid) = split /,/, @$result[1];
        return( [SUCCESS,"$model,$serial"] );
    }
    my @values;
    my $vpd = join( ",", @$result );

    #####################################
    # Type-Model may be in the formats:
    #  "eserver xSeries 336 -[7310CR3]-"
    #  "7310-CR4"
    #####################################
    if ( $vpd =~ /\*TM ([^,]+)/ ) {
        my $temp  = $1;
        my $model = ($temp =~ /\[(.*)\]/) ? $1 : $temp; 
        push @values, $model;
    }
    #####################################
    # Serial number
    #####################################
    if ( $vpd =~ /\*SE ([^,]+)/ ) {
        push @values, $1;
    }
    return( [SUCCESS,join( ",",@values)] );

}



##########################################################################
# Sends command and waits for response 
##########################################################################
sub send_cmd {

    my $exp     = shift;
    my $cmd     = shift;
    my $timeout = shift;
    my $ssh     = @$exp[0];
    my $prompt  = @$exp[1];

    ##########################################
    # Set default Expect timeout 
    ##########################################
    if ( !defined( $timeout )) {
        $timeout = 10;
    }
    ##########################################
    # Send command 
    ##########################################
    $ssh->clear_accum();
    $ssh->send( "$cmd; echo Rc=\$\?\r" );

    ##########################################
    # The first element is the number of the
    # pattern or string that matched, the
    # same as its return value in scalar
    # context. The second argument is a
    # string indicating why expect returned.
    # If there were no error, the second
    # argument will be undef. Possible errors
    # are 1:TIMEOUT, 2:EOF, 3:spawn id(...)died,
    # and "4:..." (see Expect (3) manpage for
    # the precise meaning of these messages)
    # The third argument of expects return list
    # is the string matched. The fourth argument
    # is text before the match, and the fifth
    # argument is text after the match.
    ##########################################
    my @result = $ssh->expect( $timeout, "-re", "(.*$prompt)" );
    
    ##########################################
    # Expect error 
    ##########################################
    if ( defined( $result[1] )) {
        return( [EXPECT_ERROR,expect_error( @result )] );
    } 
    ##########################################
    # Extract error code
    ##########################################
    if ( $result[3] =~ s/Rc=([0-9])+\r\n// ) {
        if ( $1 != 0 ) { 
            return( [RC_ERROR,$result[3]] );
        }
    }
    ##########################################
    # No data found - return error
    ##########################################
    if ( $result[3] =~ /No results were found/ ) {
        return( [NR_ERROR,"No results were found"] );
    }
    ##########################################
    # If no command output, return "Success" 
    ##########################################
    if ( length( $result[3] ) == 0 ) {
        $result[3] = "Success";
    }
    ##########################################
    # Success 
    ##########################################
    my @values = ( SUCCESS );
    push @values, split /\r\n/, $result[3];
    return( \@values );
}


##########################################################################
# Return Expect error
##########################################################################
sub expect_error {

    my @error = @_;
    
    ##########################################
    # The first element is the number of the
    # pattern or string that matched, the
    # same as its return value in scalar
    # context. The second argument is a
    # string indicating why expect returned.
    # If there were no error, the second
    # argument will be undef. Possible errors 
    # are 1:TIMEOUT, 2:EOF, 3:spawn id(...)died, 
    # and "4:..." (see Expect (3) manpage for
    # the precise meaning of these messages)
    # The third argument of expects return list
    # is the string matched. The fourth argument
    # is text before the match, and the fifth
    # argument is text after the match.
    ##########################################
    if ( $error[1] eq "1:TIMEOUT" ) {
        return( "Timeout waiting for prompt" );
    }
    if ( $error[1] eq "2:EOF" ) {
        if ( $error[3] ) {
            return( $error[3] );
        }
        return( "ssh connection terminated unexpectedly" );
    }
    return( "Logon failed" );
}



##########################################################################
# Returns built command based on CEC/LPAR action
##########################################################################
sub power_cmd {

    my $op   = shift;  
    my $d    = shift;
    my $type = @$d[4];

    ##############################
    # Build command 
    ##############################
    my $cmd = $powercmd{$type}{$op};

    if ( defined( $cmd )) {
        return( sprintf( $cmd, $type, @$d[2],@$d[0],@$d[1] ));
    }
    ##############################
    # Command not supported
    ##############################
    return undef;
}




1;
