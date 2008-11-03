#! /usr/bin/python
#


import sys, os, select, pg, time, traceback, datetime, socket, EpicsCA
#import Bang



class CatsOkError( Exception):
    value = None

    def __init__( self, value):
        self.value = value
        print >> sys.stderr, sys.exc_info()[0]
        print >> sys.stderr, '-'*60
        traceback.print_exc(file=sys.stderr)
        print >> sys.stderr, '-'*60

    def __str__( self):
        return repr( self.value)


class _Q:
    
    db = None   # our database connection

    def open( self):
        self.db = pg.connect( dbname="ls", host="contrabass.ls-cat.org", user="lsuser" )

    def close( self):
        self.db.close()

    def __init__( self):
        self.open()

    def reset( self):
        self.db.reset()

    def query( self, qs):
        if qs == '':
            return rtn
        if self.db.status == 0:
            self.reset()
        try:
            # ping the server
            qr = self.db.query(qs)
        except:
            if self.db.status == 1:
                print >> sys.stderr, sys.exc_info()[0]
                print >> sys.stderr, '-'*60
                traceback.print_exc(file=sys.stderr)
                print >> sys.stderr, '-'*60
                return None
            # reset the connection, should
            # put in logic here to deal with transactions
            # as transactions are rolled back
            #
            self.db.reset()
            if self.db.status != 1:
                # Bad status even after a reset, bail
                raise CatsOkError( 'Database Connection Lost')

            qr = self.db.query( qs)

        return qr

    def dictresult( self, qr):
        return qr.dictresult()

    def e( self, s):
        return pg.escape_string( s)

    def fileno( self):
        return self.db.fileno()

    def getnotify( self):
        return self.db.getnotify()

class CatsOk:
    """
    Monitors status of the cats robot, updates database, and controls CatsOk lock
    """
    needAirRights = False
    haveAirRights = False
    pathsNeedingAirRights = [
        "FromMD2", "ToMD2", "MD2CheckPointWaitingForAirRights"
        ]

    CATSOkRelayPVName = '21:F1:pmac10:acc65e:1:bo0'
    CATSOkRelayPV     = None            # the epics pv of our relay
    termstr = "\r"      # character expected to terminate cats response
    db = None           # database connection

    t1 = None           # socket object used to make connection to cats control socket
    t1Input = ""        # used to build response from t1

    t2 = None           # socket object used to make connection to cats status socket
    t2Input = ""        # used to build response from t2

    p = None            # poll object to manage active file descriptors

    fan = {}            # Dictionary used to find the appropriate service routine for each socket

    sFan = {}           # Dictionary used to parse status socket messages

    MD2 = None          # Sphere Defining MD2 location exclusion zone
    RCap = None         # Capsule defining robot tool and arm
    RR   = 0.7          # Distance from tool tip to elbow

    statusStateLast    = None
    statusIoLast       = None
    statusPositionLast = None
    statusMessageLast  = None
    waiting = False     # true when the last status reponse did not contain an entire message (more to come)
    cmdQueue = []       # queue of commands received from postgresql
    statusQueue = []    # queue of status requests to send to cats server
    statusFailedPushCount = 0


    def maybePushStatus( self, rqst):
        if self.t2 == None:
            # send requests to the bit bucket if the server is not connected
            return False
        try:
            i = self.statusQueue.index( rqst)
        except ValueError:
            self.statusQueue.append( rqst)
            self.p.register( self.t2, select.POLLIN | select.POLLPRI | select.POLLOUT)
            return True

        self.statusFailedPushCount += 1
        if self.statusFailedPushCount >=10:
            print "Exceeded failure count"
            return False
        self.statusFailedPushCount = 0
        return True

    def popStatus( self):
        rtn = None
        if len( self.statusQueue):
            rtn = self.statusQueue.pop()
        else:
            self.p.register( self.t2, select.POLLIN | select.POLLPRI)
        return rtn

    def pushCmd( self, cmd):
        print "pushing command '%s'" % (cmd)
        self.cmdQueue.append( cmd)
        self.p.register( self.t1, select.POLLIN | select.POLLPRI | select.POLLOUT)


    def nextCmd( self):
        rtn = None
        if len( self.cmdQueue) > 0:
            rtn = self.cmdQueue.pop(0)
        else:
            self.p.register( self.t1, select.POLLIN | select.POLLPRI)

        return rtn

    def dbService( self, event):

        if event & select.POLLERR:
            self.db.reset();

        if event & (select.POLLIN | select.POLLPRI):
            # Kludge to allow time for notify to actually get here.  (Why is this needed?)
            time.sleep( 0.1)

            #
            # Eat up any accumulated notifies
            #
            ntfy = self.db.getnotify()
            while  ntfy != None:
                print "Received Notify: ", ntfy
                ntfy = self.db.getnotify()

            #
            # grab a waiting command
            #
            cmdFlag = True
            while( cmdFlag):
                qr = self.db.query( "select cats._popqueue() as cmd")
                r = qr.dictresult()[0]
                if len( r["cmd"]) > 0:
                    self.pushCmd( r["cmd"])
                else:
                    cmdFlag = False

        return True

    #
    # Service reply from Command socket
    #
    def t1Service( self, event):
        if event & select.POLLOUT:
            cmd = self.nextCmd()
            if cmd != None:
                print "sending command '%s'" % (cmd)
                self.t1.send( cmd + self.termstr)

        if event & (select.POLLIN | select.POLLPRI):
            newStr = self.t1.recv( 4096)
            if len(newStr) == 0:
                self.p.unregister( self.t1.fileno())
                return False

            print "Received:", newStr
            str = self.t1Input + newStr
            pList = str.replace('\n','\r').split( self.termstr)
            if len( str) > 0 and str[-2:-1] != self.termstr:
                self.t1Input = pList.pop( -1)
        
            for s in pList:
                print s
        return True

    #
    # Service reply from status socket
    def t2Service( self, event):
        if event & (select.POLLIN | select.POLLPRI):
            try:
                newStr = self.t2.recv( 4096)
            except socket.error:
                self.p.unregister( self.t2.fileno())
                self.t2 = None
                return False

            #
            # zero length return means an error, most likely the socket has shut down
            if len(newStr) == 0:
                self.p.unregister( self.t2.fileno())
                self.t2 = None
                return False

            # Assume we have the full response
            self.waiting = False

            print "Status Received:", newStr.strip()

            #
            # add what we have from what was left over from last time
            str = self.t2Input + newStr
        
            #
            # split the string into an array of responses: each distinct reply ends with termstr
            pList = str.replace('\n','\r').split( self.termstr)
            if len( str) > 0 and str[-2:-1] != self.termstr:
                # if the last entry does not end with a termstr then there is more to come, save it for later
                #
                self.t2Input = pList.pop( -1)
        
            #
            # go through the list of completed status responses
            for s in pList:
                sFound = False
                for ss in self.sFan:
                    if s.startswith( ss):
                        # call the status response function
                        self.sFan[ss](s)
                        sFound = True
                        break
                if not sFound:
                    # if we do not recognize the response then it must be a message
                    self.statusMessageParse( s)

        if event & select.POLLOUT:
            s = self.popStatus()
            if s != None:
                self.t2.send( s + self.termstr)

        return True

    def __init__( self):
        #
        # establish connections to CATS sockets
        self.t1 = socket.socket( socket.AF_INET, socket.SOCK_STREAM)
        try:
            self.t1.connect( ("10.1.19.19", 1000))
        except socket.error:
            raise CatsOkError( "Could not connect to command port")
        self.t1.setblocking( 1)


        self.t2 = socket.socket( socket.AF_INET, socket.SOCK_STREAM)
        try:
            self.t2.connect( ("10.1.19.19", 10000))
        except socket.error:
            raise CatsOkError( "Could not connect to status port")
        self.t2.setblocking( 1)

        #
        # establish connecitons to database server
        #self.db = pg.connect(dbname='ls',user='lsuser', host='10.1.0.3')
        self.db = _Q()
        #self.db.query( "PREPARE io_noArgs AS select cats.setio()")
        #self.db.query( "PREPARE position_noArgs AS select cats.setposition()")
        #self.db.query( "PREPARE message_noArgs AS select cats.setmessage()")
        #self.db.query( "PREPARE state_noArgs AS select cats.setstate()")
        #
        # Listen to db requests
        self.db.query( "select cats.init()")


        #
        # Get the epics relay pv
        self.CATSOkRelayPV = EpicsCA.PV( self.CATSOkRelayPVName)
        # initially set this high
        self.CATSOkRelayPV.put( 1)


        #
        # Set up poll object
        self.p = select.poll()
        self.p.register( self.t1.fileno(), select.POLLIN | select.POLLPRI)
        self.p.register( self.t2.fileno(), select.POLLIN | select.POLLPRI)
        self.p.register( self.db.fileno(), select.POLLIN | select.POLLPRI)

        #
        # Set up fan to unmultiplex the poll response
        self.fan = {
            self.t1.fileno()     : self.t1Service,
            self.t2.fileno()     : self.t2Service,
            self.db.fileno()     : self.dbService,
            }

        #
        # Set up sFan to handle status socket messages
        self.sFan = {
            "state"    : self.statusStateParse,
            "io"       : self.statusIoParse,
            "position" : self.statusPositionParse,
            "config"   : self.statusConfigParse
            }

        self.srqst = {
            "state"     : { "period" : 0.5, "last" : None, "rqstCnt" : 0, "rcvdCnt" : 0},
            "io"        : { "period" : 0.5, "last" : None, "rqstCnt" : 0, "rcvdCnt" : 0},
            "position"  : { "period" : 30, "last" : None, "rqstCnt" : 0, "rcvdCnt" : 0},
            "message"   : { "period" : 30, "last" : None, "rqstCnt" : 0, "rcvdCnt" : 0}
            }

        # self.MD2 = Bang.Sphere( Bang.Point( 0.5, 0.5, 0.5), 0.5)

    def close( self):
        if self.t1 != None:
            self.t1.close()
            self.t1 = None
        if self.t2 != None:
            self.t2.close()
            self.t2 = None
        if self.db != None:
            self.db.close()
            self.db = None

    def run( self):
        runFlag = True
        while( runFlag):
            for ( fd, event) in self.p.poll( 100):
                runFlag = runFlag and self.fan[fd](event)
                if not runFlag:
                    break
            if runFlag and not self.waiting:
                #
                # queue up new requests if it is time to
                n = datetime.datetime.now()
                for k in self.srqst.keys():
                    r = self.srqst[k]
                    if r["last"] == None or (n - r["last"] > datetime.timedelta(0,r["period"])):
                        runFlag &= self.maybePushStatus( k)
                        r["last"] = datetime.datetime.now()
                        r["rqstCnt"] += 1

            if runFlag and self.needAirRights and not self.haveAirRights:
                qs = "select px.requestRobotAirRights() as rslt"
                qr = self.db.query( qs)
                rslt = qr.dictresult()[0]["rslt"]
                if rslt == "t":
                    self.haveAirRights = True
                    self.pushCmd( "vdi90on")

            if runFlag and not self.needAirRights and self.haveAirRights:
                self.db.query( "select px.dropRobotAirRights()")    # drop rights and send notify that sample is ready (if it is)

                self.haveAirRights = False

        self.close()

    def statusStateParse( self, s):
        self.srqst["state"]["rcvdCnt"] = self.srqst["state"]["rcvdCnt"] + 1
        if self.statusStateLast != None and self.statusStateLast == s:
            #self.db.query( "execute state_noArgs")
            #self.db.query( "select cats.setstate()")
            return

        # One line command to an argument list
        a = s[s.find("(")+1 : s.find(")")].split(',')

        # a = s.partition( '(')[2].partition( ')')[0].split(',')

        if len(a) != 15:
            print s
            raise CatsOkError( 'Wrong number of arguments received in status state response: got %d, exptected 15' % (len(a)))
        #                            0            1            2             3           4          5   6   7   8   9  10   11         12           13           14
        b = []
        i = 0
        #             0           1           2         3       4         5      6       7       8        9     10        11        12          13         14
        aType = ["::boolean","::boolean","::boolean","::text","::text","::int","::int","::int","::int","::int","::int","::text","::boolean","::boolean","::boolean"]
        qs = "select cats.setstate( "

        needComma = False
        for zz in a:
            if zz == None or len(zz) == 0:
                b.append("NULL")
            else:
                b.append( "'%s'%s" % (zz, aType[i]))

            if needComma:
                qs = qs+","
            qs = qs + b[i]
            i = i+1
            needComma = True

        qs = qs + ")"
        #qs = "select cats.setstate( '%s'::boolean, '%s'::boolean, '%s'::boolean, '%s'::text, '%s'::text, '%s', '%s', '%s', '%s', '%s', '%s', '%s'::text, '%s'::boolean, '%s'::boolean, '%s'::boolean)" % \
        #( a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14])
        self.db.query( qs)
        self.statusStateLast = s

        # See if we are on a path that requires air rights
        pathName = a[4];
        try:
            ndx = self.pathsNeedingAirRights.index(pathName)
        except ValueError:
            self.needAirRights = False
        else:
            self.needAirRights = True

    def statusIoParse( self, s):
        self.srqst["io"]["rcvdCnt"] = self.srqst["io"]["rcvdCnt"] + 1
        if self.statusIoLast != None and self.statusIoLast == s:
            #self.db.query( "select cats.setio()")
            #self.db.query( "execute io_noArgs")
            return

        # One line command to pull out the arguments as one string
        # hope this is in the right format to send to postresql server

        a = s[s.find("(")+1:s.find(")")]
        #a = s.partition( '(')[2].partition( ')')[0]

        b = a.replace( "1", "'t'")
        c = b.replace( "0", "'f'")

        qs = "select cats.setio( %s)" % (c)
        print s,qs
        self.db.query( qs)
        self.statusIoLast = s
        

    def statusPositionParse( self, s):
        self.srqst["position"]["rcvdCnt"] = self.srqst["position"]["rcvdCnt"] + 1
        if self.statusPositionLast != None and self.statusPositionLast == s:
            #self.db.query( "select cats.setposition()")
            #self.db.query( "execute position_noArgs")
            return

        # One line command to an argument list
        a = s[s.find("(")+1 : s.find(")")].split(',')

        #a = s.partition( '(')[2].partition( ')')[0].split(',')
        if len(a) != 6:
            raise CatsOkError( 'Wrong number of arguments received in status state response: got %d, exptected 14' % (len(a)))
        #                               0   1   2   3   4  5
        qs = "select cats.setposition( %s, %s, %s, %s, %s, %s)" %  ( a[0], a[1], a[2], a[3], a[4], a[5])
        self.db.query( qs)
        self.statusPositionLast = s

        # self.RCap( Bang.Point( float(a[0]), float(a[1]), float(a[2]), Bang.Point( float

    def statusConfigParse( self, s):
        pass
    
    def statusMessageParse( self, s):
        self.srqst["message"]["rcvdCnt"] = self.srqst["message"]["rcvdCnt"] + 1
        if self.statusMessageLast != None and self.statusMessageLast == s:
            #self.db.query( "select cats.setmessage()")
            #self.db.query( "execute message_noArgs")
            return

        qs = "select cats.setmessage( '%s')" % (s)
        self.db.query( qs)
        self.statusMessageLast = s

        

#
# Default usage
#
if __name__ == '__main__':
    iFlag = True
    rFlag = True

    while rFlag:
        while iFlag:
            try:
                z = CatsOk()
            except CatsOkError, e:
                time.sleep( 10)
            else:
                iFlag = False
        try:
            z.run()
        except CatsOkError:
            z.close()
        time.sleep( 10)
        iFlag = True

