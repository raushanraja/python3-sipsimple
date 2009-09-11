from __future__ import with_statement
from zope.interface import implements
from application.notification import NotificationCenter, NotificationData
from twisted.python.failure import Failure

from eventlet import proc
from eventlet.green.thread import allocate_lock
from msrplib.connect import get_acceptor, get_connector, MSRPRelaySettings
from msrplib.protocol import URI, FailureReportHeader, parse_uri, ContentTypeHeader
from msrplib.transport import make_response
from msrplib.session import contains_mime_type

from sipsimple.core import SDPAttribute, SDPMediaStream
from sipsimple.cpim import CPIMIdentity
from sipsimple.interfaces import IMediaStream
from sipsimple.configuration.settings import SIPSimpleSettings
from sipsimple.msrp import NotificationProxyLogger, get_X509Credentials
from sipsimple.green.core import SDPNegotiationError

from sipsimple.applications.desktopsharing import vncviewer, pygamevncviewer, gvncviewer, xtightvncviewer, vncserver


class MSRPDesktop(object):
    implements(IMediaStream)

    hold_supported = False
    on_hold = False
    on_hold_by_local = False
    on_hold_by_remote = False
    setup = None

    def __init__(self, account, setup=None):
        self.account = account
        self.direction = 'sendrecv'
        self.notification_center = NotificationCenter()
        settings = SIPSimpleSettings()
        self.accept_types = ['application/x-rfb']
        self.local_media = None
        self.msrp = None ## Placeholder for the MSRPTransport that will be set when started
        self.msrp_connector = None
        if setup is not None:
            self.setup = setup
        self.worker = None
        self.local_identity = CPIMIdentity(self.account.uri, self.account.display_name)

    def make_SDPMediaStream(self, uri_path):
        attributes = []
        attributes.append(SDPAttribute("path", " ".join([str(uri) for uri in uri_path])))
        if self.direction not in [None, 'sendrecv']:
            attributes.append(SDPAttribute(self.direction, ''))
        if self.accept_types is not None:
            attributes.append(SDPAttribute("accept-types", " ".join(self.accept_types)))
        assert self.setup is not None
        attributes.append(SDPAttribute("setup", self.setup))
        if uri_path[-1].use_tls:
            transport = 'TCP/TLS/MSRP'
        else:
            transport = 'TCP/MSRP'
        return SDPMediaStream("application", uri_path[-1].port or 12345, transport, formats=["*"], attributes=attributes)

    def get_local_media(self, for_offer=True):
        return self.local_media

    def validate_incoming(self, remote_sdp, stream_index):
        media = remote_sdp.media[stream_index]
        media_attributes = dict((attr.name, attr.value) for attr in media.attributes)
        remote_setup = media_attributes.get('setup', 'active')
        if remote_setup == 'active' and self.setup in ['passive', None]:
            self.setup = 'passive'
            return True
        elif remote_setup == 'passive' and self.setup in ['active', None]:
            self.setup = 'active'
            return True
        else:
            return False

    def initialize(self, session, direction):
        try:
            settings = SIPSimpleSettings()
            outgoing = direction == 'outgoing'
            if self.setup is None:
                if outgoing:
                    self.setup = 'active'
                else:
                    self.setup = 'passive'
            if (outgoing and self.account.nat_traversal.use_msrp_relay_for_outbound) or (not outgoing and self.account.nat_traversal.use_msrp_relay_for_inbound):
                if self.account.nat_traversal.msrp_relay is None:
                    relay = MSRPRelaySettings(domain=self.account.id.domain,
                                              username=self.account.id.username,
                                              password=self.account.password)
                    self.transport = 'tls'
                else:
                    relay = MSRPRelaySettings(domain=self.account.id.domain,
                                              username=self.account.id.username,
                                              password=self.account.password,
                                              host=self.account.nat_traversal.msrp_relay.host,
                                              port=self.account.nat_traversal.msrp_relay.port,
                                              use_tls=self.account.nat_traversal.msrp_relay.transport=='tls')
                    self.transport = self.account.nat_traversal.msrp_relay.transport
            else:
                relay = None
                self.transport = settings.msrp.transport
            logger = NotificationProxyLogger()
            self.msrp_connector = get_connector(relay=relay, logger=logger) if outgoing else get_acceptor(relay=relay, logger=logger)
            settings = SIPSimpleSettings()
            local_uri = URI(host=settings.sip.local_ip.normalized,
                            port=settings.msrp.local_port,
                            use_tls=self.transport=='tls',
                            credentials=get_X509Credentials())
            full_local_path = self.msrp_connector.prepare(local_uri)
            self.local_media = self.make_SDPMediaStream(full_local_path)
            self.remote_identity = CPIMIdentity(session.remote_identity.uri, session.remote_identity.display_name)
        except Exception, ex:
            ndata = NotificationData(context='initialize', failure=Failure(), reason=str(ex))
            self.notification_center.post_notification('MediaStreamDidFail', self, ndata)
            raise
        else:
            self.notification_center.post_notification('MediaStreamDidInitialize', self)

    def start(self, local_sdp, remote_sdp, stream_index):
        context = 'sdp_negotiation'
        try:
            remote_media = remote_sdp.media[stream_index]
            media_attributes = dict((attr.name, attr.value) for attr in remote_media.attributes)
            remote_accept_types = media_attributes.get('accept-types')
            # TODO: update accept_types and accept_wrapped_types from remote_media
            # TODO: chatroom, recvonly/sendonly?
            self.cpim_enabled = contains_mime_type(self.accept_types, 'message/cpim')
            self.private_messages_allowed = self.cpim_enabled # and isfocus and 'private-messages' in chatroom
            remote_uri_path = media_attributes.get('path')
            if remote_uri_path is None:
                raise SDPNegotiationError(reason="remote SDP media does not have 'path' attribute")
            full_remote_path = [parse_uri(uri) for uri in remote_uri_path.split()]
            context = 'start'
            self.msrp = self.msrp_connector.complete(full_remote_path)
            self.msrp_connector = None
            self._on_start()
        except Exception, ex:
            ndata = NotificationData(context=context, failure=Failure(), reason=str(ex) or type(ex).__name__)
            self.notification_center.post_notification('MediaStreamDidFail', self, ndata)
            raise
        else:
            self.notification_center.post_notification('MediaStreamDidStart', self)

    def _on_start(self):
        if self.setup == 'passive':
            self.worker = proc.spawn(vncserver, SocketOverMSRPTransport(self.msrp), x11opts=" -speeds modem")
        else:
            depth = SIPSimpleSettings().desktop_sharing.color_depth
            viewer = SIPSimpleSettings().desktop_sharing.client_command
            if viewer == 'pygame':
                v = pygamevncviewer
            elif viewer == 'gvncviewer':
                v = gvncviewer
            elif viewer == 'xtightvncviewer':
                v = xtightvncviewer
            else:
                v = vncviewer
            self.worker = proc.spawn(vncviewer, SocketOverMSRPTransport(self.msrp), str(self.remote_uri), depth=depth)
        self.worker.link_value(lambda p: proc.spawn(self.end))
        self.worker.link_exception(lambda p: self._report_failure(p))

    def _report_failure(self, p):
        ex = p.exc_info()[1]
        ndata = NotificationData(reason=str(ex) or type(ex).__name__)
        self.notification_center.post_notification('MediaStreamDidFail', self, ndata)

    def hold(self):
        return # MSRPDesktop stream does not support hold

    def unhold(self):
        return # MSRPDesktop stream does not support hold

    def validate_update(self, remote_sdp, stream_index):
        # TODO
        return True

    def update(self, local_sdp, remote_sdp, stream_index):
        # TODO
        return

    def end(self):
        if self.msrp is None and self.msrp_connector is None:
            return
        msrp, self.msrp = self.msrp, None
        msrp_connector, self.msrp_connector = self.msrp_connector, None
        worker, self.worker = self.worker, None
        self.notification_center.post_notification('MediaStreamWillEnd', self)
        try:
            if worker is not None:
                worker.kill()
            if msrp is not None:
                msrp.loseConnection()
            if msrp_connector is not None:
                msrp_connector.cleanup()
        finally:
            self.notification_center.post_notification('MediaStreamDidEnd', self)


class SocketOverMSRPTransport(object):
    def __init__(self, msrp):
        self.msrp = msrp
        # something inside sipsimple.clients.desktopsharing using calling send() on this object from more than one greenlet
        # this is not cool, msrplib does not support it.
        # probably need a lock around recv as well. or something inside sipsimple.clients.desktopsharing needs to be fixed
        self.lock = allocate_lock()

    def recv(self, amount = 1):
        chunk = self.msrp.read_chunk(amount)
        # the old sip_desktop_sharing.py script sends chunks with no Failure-Report header and
        # therefore needs failure reports.
        # we should probably also generate Success-Report to be a compliant endpoint, but who will use
        # reports for for desktop sharing?
        response = make_response(chunk, 200, 'OK')
        if response is not None:
            self.msrp.write(response.encode())
        return chunk.data

    # the better way (less overhead) to do it is to open a chunk with Byte-Range: 1-*/* and then send all the data
    # within that chunk
    def send(self, data):
        with self.lock:
            chunk = self.msrp.make_chunk(data=data)
            chunk.add_header(FailureReportHeader('no'))
            chunk.add_header(ContentTypeHeader('application/x-rfb'))
            self.msrp.write(chunk.encode())
            return len(data)

    def close(self):
        return self.msrp.loseConnection(wait=False)

