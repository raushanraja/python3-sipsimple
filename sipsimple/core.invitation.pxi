# Copyright (C) 2008-2009 AG Projects. See LICENSE for details.
#

# classes

cdef class Invitation:
    cdef pjsip_inv_session *_obj
    cdef pjsip_dialog *_dlg
    cdef Credentials _credentials
    cdef SIPURI _from_uri
    cdef SIPURI _to_uri
    cdef Route _route
    cdef readonly object state
    cdef SDPSession _local_sdp_proposed
    cdef int _sdp_neg_status
    cdef int _has_active_sdp
    cdef readonly object transport
    cdef SIPURI _local_contact_uri
    cdef pjsip_transaction *_reinvite_tsx
    cdef pj_timer_entry _timer
    cdef int _timer_active

    def __cinit__(self, *args, **kwargs):
        self._sdp_neg_status = -1
        pj_timer_entry_init(&self._timer, 0, <void *> self, _Request_cb_disconnect_timer)
        self.state = "INVALID"

    def __init__(self, SIPURI from_uri=None, SIPURI to_uri=None, Route route=None,
                 Credentials credentials=None, SIPURI contact_uri=None):
        cdef PJSIPUA ua = _get_ua()
        if self.state != "INVALID":
            raise SIPCoreError("Invitation.__init__() was already called")
        if all([from_uri, to_uri, route]):
            self.state = "NULL"
            self._from_uri = from_uri.copy()
            self._to_uri = to_uri.copy()
            self._route = route.copy()
            self.transport = route.transport
            if contact_uri is None:
                self._local_contact_uri = ua._create_contact_uri(route)
            else:
                self._local_contact_uri = contact_uri.copy()
            if credentials is not None:
                self._credentials = credentials.copy()
        elif any([from_uri, to_uri, route]):
            raise ValueError('The "from_uri", "to_uri" and "route" arguments need to be supplied ' +
                             "when creating an outbound Invitation")

    cdef int _init_incoming(self, PJSIPUA ua, pjsip_rx_data *rdata, unsigned int inv_options) except -1:
        cdef pjsip_tx_data *tdata
        cdef PJSTR contact_uri
        cdef object transport
        cdef pjsip_tpselector tp_sel
        cdef int status
        try:
            self.transport = rdata.tp_info.transport.type_name.lower()
            request_uri = _make_SIPURI(rdata.msg_info.msg.line.req.uri, 0)
            if _is_valid_ip(pj_AF_INET(), request_uri.host):
                self._local_contact_uri = request_uri
            else:
                self._local_contact_uri = SIPURI(host=_pj_str_to_str(rdata.tp_info.transport.local_name.host),
                                                  user=request_uri.user, port=rdata.tp_info.transport.local_name.port,
                                                  parameters= ({"transport":transport} if self.transport != "udp"
                                                                                       else {}))
            contact_uri = PJSTR(self._local_contact_uri._as_str(1))
            status = pjsip_dlg_create_uas(pjsip_ua_instance(), rdata, &contact_uri.pj_str, &self._dlg)
            if status != 0:
                raise PJSIPError("Could not create dialog for new INVITE session", status)
            status = pjsip_inv_create_uas(self._dlg, rdata, NULL, inv_options, &self._obj)
            if status != 0:
                raise PJSIPError("Could not create new INVITE session", status)
            tp_sel.type = PJSIP_TPSELECTOR_TRANSPORT
            tp_sel.u.transport = rdata.tp_info.transport
            status = pjsip_dlg_set_transport(self._dlg, &tp_sel)
            if status != 0:
                raise PJSIPError("Could not set transport for INVITE session", status)
            status = pjsip_inv_initial_answer(self._obj, rdata, 100, NULL, NULL, &tdata)
            if status != 0:
                raise PJSIPError("Could not create initial (unused) response to INVITE", status)
            pjsip_tx_data_dec_ref(tdata)
            self._obj.mod_data[ua._module.id] = <void *> self
            self._cb_state(ua, "INCOMING", rdata)
        except:
            if self._obj != NULL:
                pjsip_inv_terminate(self._obj, 500, 0)
            elif self._dlg != NULL:
                pjsip_dlg_terminate(self._dlg)
            self._obj = NULL
            self._dlg = NULL
            raise
        self._from_uri = _make_SIPURI(rdata.msg_info.from_hdr.uri, 1)
        self._to_uri = _make_SIPURI(rdata.msg_info.to_hdr.uri, 1)
        return 0

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self.state = "DISCONNECTED"
            self._obj = NULL
            self._dlg = NULL

    cdef int _do_dealloc(self) except -1:
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except SIPCoreError:
            return 0
        if self._obj != NULL:
            self._obj.mod_data[ua._module.id] = NULL
            if self.state != "DISCONNECTING":
                pjsip_inv_terminate(self._obj, 481, 0)
            self._obj = NULL
            self._dlg = NULL
        if self._timer_active:
            pjsip_endpt_cancel_timer(ua._pjsip_endpoint._obj, &self._timer)
            self._timer_active = 0
        return 0

    def __dealloc__(self):
        self._do_dealloc()

    cdef int _fail(self, PJSIPUA ua) except -1:
        ua._handle_exception(0)
        self._obj.mod_data[ua._module.id] = NULL
        if self.state != "DISCONNECTED":
            self.state = "DISCONNECTED"
            # Set prev_state to DISCONNECTED toindicate that we caused the disconnect
            _add_event("SIPInvitationChangedState", dict(obj=self, prev_state="DISCONNECTING", state="DISCONNECTED",
                                                         code=0, reason="Internal exception occured"))
        # calling do_dealloc from within a callback makes PJSIP crash
        # post_handlers will be executed after pjsip_endpt_handle_events returns
        _add_post_handler(_Invitation_cb_fail_post, self)

    property from_uri:

        def __get__(self):
            if self._from_uri is None:
                return None
            else:
                return self._from_uri.copy()

    property to_uri:

        def __get__(self):
            if self._to_uri is None:
                return None
            else:
                return self._to_uri.copy()

    property local_uri:

        def __get__(self):
            if self._from_uri is None:
                return None
            if self._credentials is None:
                return self._to_uri.copy()
            else:
                return self._from_uri.copy()

    property remote_uri:

        def __get__(self):
            if self._from_uri is None:
                return None
            if self._credentials is None:
                return self._from_uri.copy()
            else:
                return self._to_uri.copy()

    property credentials:

        def __get__(self):
            if self._credentials is None:
                return None
            else:
                return self._credentials.copy()

    property route:

        def __get__(self):
            if self._route is None:
                return None
            else:
                return self._route.copy()

    property is_outgoing:

        def __get__(self):
            return self._credentials is not None

    property call_id:

        def __get__(self):
            self._check_ua()
            if self._dlg == NULL:
                return None
            else:
                return _pj_str_to_str(self._dlg.call_id.id)

    property local_contact_uri:

        def __get__(self):
            if self._local_contact_uri is None:
                return None
            else:
                return self._local_contact_uri.copy()

    def get_active_local_sdp(self):
        cdef pjmedia_sdp_session_ptr_const sdp
        self._check_ua()
        if self._obj != NULL and self._has_active_sdp:
            pjmedia_sdp_neg_get_active_local(self._obj.neg, &sdp)
            return _make_SDPSession(sdp)
        else:
            return None

    def get_active_remote_sdp(self):
        cdef pjmedia_sdp_session_ptr_const sdp
        self._check_ua()
        if self._obj != NULL and self._has_active_sdp:
            pjmedia_sdp_neg_get_active_remote(self._obj.neg, &sdp)
            return _make_SDPSession(sdp)
        else:
            return None

    def get_offered_remote_sdp(self):
        cdef pjmedia_sdp_session_ptr_const sdp
        self._check_ua()
        if self._obj != NULL and pjmedia_sdp_neg_get_state(self._obj.neg) in [PJMEDIA_SDP_NEG_STATE_REMOTE_OFFER,
                                                                              PJMEDIA_SDP_NEG_STATE_WAIT_NEGO]:
            pjmedia_sdp_neg_get_neg_remote(self._obj.neg, &sdp)
            return _make_SDPSession(sdp)
        else:
            return None

    def get_offered_local_sdp(self):
        cdef pjmedia_sdp_session_ptr_const sdp
        self._check_ua()
        if self._obj != NULL and pjmedia_sdp_neg_get_state(self._obj.neg) in [PJMEDIA_SDP_NEG_STATE_LOCAL_OFFER,
                                                                              PJMEDIA_SDP_NEG_STATE_WAIT_NEGO]:
            pjmedia_sdp_neg_get_neg_local(self._obj.neg, &sdp)
            return _make_SDPSession(sdp)
        else:
            return self._local_sdp_proposed

    def set_offered_local_sdp(self, local_sdp):
        cdef pjmedia_sdp_neg_state neg_state = PJMEDIA_SDP_NEG_STATE_NULL
        self._check_ua()
        if self._obj != NULL:
            neg_state = pjmedia_sdp_neg_get_state(self._obj.neg)
        if neg_state in [PJMEDIA_SDP_NEG_STATE_NULL, PJMEDIA_SDP_NEG_STATE_REMOTE_OFFER, PJMEDIA_SDP_NEG_STATE_DONE]:
            self._local_sdp_proposed = local_sdp
        else:
            raise SIPCoreError("Cannot set offered local SDP in this state")

    def update_local_contact_uri(self, SIPURI contact_uri):
        cdef object uri_str
        cdef pj_str_t uri_str_pj
        cdef pjsip_uri *uri = NULL
        if contact_uri is None:
            raise ValueError("contact_uri argument may not be None")
        if self._dlg == NULL:
            raise SIPCoreError("Cannot update local Contact URI while in the NULL or TERMINATED state")
        uri_str = contact_uri._as_str(1)
        pj_strdup2_with_null(self._dlg.pool, &uri_str_pj, uri_str)
        uri = pjsip_parse_uri(self._dlg.pool, uri_str_pj.ptr, uri_str_pj.slen, PJSIP_PARSE_URI_AS_NAMEADDR)
        if uri == NULL:
            raise SIPCoreError("Not a valid SIP URI: %s" % uri_str)
        self._dlg.local.contact = pjsip_contact_hdr_create(self._dlg.pool)
        self._dlg.local.contact.uri = uri
        self._local_contact_uri = contact_uri.copy()

    cdef int _cb_state(self, PJSIPUA ua, object state, pjsip_rx_data *rdata) except -1:
        cdef pjsip_tx_data *tdata
        cdef int status
        cdef dict event_dict
        if state == "CALLING" and state == self.state:
            return 0
        if state == "CONFIRMED":
            if self.state == "CONNECTING" and self._sdp_neg_status != 0:
                self.end(488)
                return 0
        if self._obj.cancelling and state == "DISCONNECTED":
            # Hack to indicate that we caused the disconnect
            self.state = "DISCONNECTING"
        if state in ["REINVITED", "REINVITING"]:
            self._reinvite_tsx = self._obj.invite_tsx
        elif self.state in ["REINVITED", "REINVITING"]:
            self._reinvite_tsx = NULL
        event_dict = dict(obj=self, prev_state=self.state, state=state)
        self.state = state
        if rdata != NULL:
            _rdata_info_to_dict(rdata, event_dict)
        if state == "DISCONNECTED":
            if not self._obj.cancelling and rdata == NULL and self._obj.cause > 0:
                event_dict["code"] = self._obj.cause
                event_dict["reason"] = _pj_str_to_str(self._obj.cause_text)
            self._obj.mod_data[ua._module.id] = NULL
            self._obj = NULL
            self._dlg = NULL
            if self._timer_active:
                pjsip_endpt_cancel_timer(ua._pjsip_endpoint._obj, &self._timer)
                self._timer_active = 0
        elif state in ["EARLY", "CONNECTING"] and self._timer_active:
            pjsip_endpt_cancel_timer(ua._pjsip_endpoint._obj, &self._timer)
            self._timer_active = 0
        elif state == "REINVITED":
            status = pjsip_inv_initial_answer(self._obj, rdata, 100, NULL, NULL, &tdata)
            if status != 0:
                raise PJSIPError("Could not create initial (unused) response to INVITE", status)
            pjsip_tx_data_dec_ref(tdata)
        _add_event("SIPInvitationChangedState", event_dict)
        return 0

    cdef int _cb_sdp_done(self, PJSIPUA ua, int status) except -1:
        cdef dict event_dict
        cdef pjmedia_sdp_session_ptr_const local_sdp
        cdef pjmedia_sdp_session_ptr_const remote_sdp
        self._sdp_neg_status = status
        self._local_sdp_proposed = None
        if status == 0:
            self._has_active_sdp = 1
        if self.state in ["DISCONNECTING", "DISCONNECTED"]:
            return 0
        event_dict = dict(obj=self, succeeded=status == 0)
        if status == 0:
            pjmedia_sdp_neg_get_active_local(self._obj.neg, &local_sdp)
            event_dict["local_sdp"] = _make_SDPSession(local_sdp)
            pjmedia_sdp_neg_get_active_remote(self._obj.neg, &remote_sdp)
            event_dict["remote_sdp"] = _make_SDPSession(remote_sdp)
        else:
            event_dict["error"] = _pj_status_to_str(status)
        _add_event("SIPInvitationGotSDPUpdate", event_dict)
        if self.state in ["INCOMING", "EARLY"] and status != 0:
            self.end(488)
        return 0

    cdef int _send_msg(self, PJSIPUA ua, pjsip_tx_data *tdata, dict extra_headers) except -1:
        cdef int status
        _add_headers_to_tdata(tdata, extra_headers)
        status = pjsip_inv_send_msg(self._obj, tdata)
        if status != 0:
            raise PJSIPError("Could not send message in context of INVITE session", status)
        return 0

    def send_invite(self, dict extra_headers=None, timeout=None):
        cdef pjsip_tx_data *tdata
        cdef object transport
        cdef PJSTR from_uri
        cdef PJSTR to_uri
        cdef SIPURI callee_target_uri
        cdef PJSTR callee_target
        cdef PJSTR contact_uri
        cdef pjmedia_sdp_session *local_sdp = NULL
        cdef pj_time_val timeout_pj
        cdef int status
        cdef PJSIPUA ua = _get_ua()
        if self.state != "NULL":
            raise SIPCoreError('Can only transition to the "CALLING" state from the "NULL" state, ' +
                               'currently in the "%s" state' % self.state)
        if self._local_sdp_proposed is None:
            raise SIPCoreError("Local SDP has not been set")
        if timeout is not None:
            if timeout <= 0:
                raise ValueError("Timeout value cannot be negative")
            timeout_pj.sec = int(timeout)
            timeout_pj.msec = (timeout * 1000) % 1000
        from_uri = PJSTR(self._from_uri._as_str(0))
        to_uri = PJSTR(self._to_uri._as_str(0))
        callee_target_uri = self._to_uri.copy()
        if callee_target_uri.parameters.get("transport", "udp").lower() != self.transport:
            callee_target_uri.parameters["transport"] = self.transport
        callee_target = PJSTR(callee_target_uri._as_str(1))
        contact_uri = PJSTR(self._local_contact_uri._as_str(1))
        try:
            status = pjsip_dlg_create_uac(pjsip_ua_instance(), &from_uri.pj_str, &contact_uri.pj_str,
                                          &to_uri.pj_str, &callee_target.pj_str, &self._dlg)
            if status != 0:
                raise PJSIPError("Could not create dialog for outgoing INVITE session", status)
            self._local_sdp_proposed._to_c()
            local_sdp = &self._local_sdp_proposed._obj
            status = pjsip_inv_create_uac(self._dlg, local_sdp, 0, &self._obj)
            if status != 0:
                raise PJSIPError("Could not create outgoing INVITE session", status)
            self._obj.mod_data[ua._module.id] = <void *> self
            if self._credentials is not None:
                status = pjsip_auth_clt_set_credentials(&self._dlg.auth_sess, 1, &self._credentials._obj)
                if status != 0:
                    raise PJSIPError("Could not set credentials for INVITE session", status)
            status = pjsip_dlg_set_route_set(self._dlg, <pjsip_route_hdr *> &self._route._route_set)
            if status != 0:
                raise PJSIPError("Could not set route for INVITE session", status)
            status = pjsip_inv_invite(self._obj, &tdata)
            if status != 0:
                raise PJSIPError("Could not create INVITE message", status)
            self._send_msg(ua, tdata, extra_headers or {})
        except:
            if self._obj != NULL:
                pjsip_inv_terminate(self._obj, 500, 0)
            elif self._dlg != NULL:
                pjsip_dlg_terminate(self._dlg)
            self._obj = NULL
            self._dlg = NULL
            raise
        if timeout:
            status = pjsip_endpt_schedule_timer(ua._pjsip_endpoint._obj, &self._timer, &timeout_pj)
            if status == 0:
                self._timer_active = 1

    def respond_to_invite_provisionally(self, int response_code=180, dict extra_headers=None):
        cdef PJSIPUA ua = self._check_ua()
        if self.state != "INCOMING":
            raise SIPCoreError('Can only transition to the "EARLY" state from the "INCOMING" state, ' +
                               'currently in the "%s" state.' % self.state)
        if response_code / 100 != 1:
            raise SIPCoreError("Not a provisional response: %d" % response_code)
        self._send_response(ua, response_code, extra_headers)

    def accept_invite(self, dict extra_headers=None):
        cdef PJSIPUA ua = self._check_ua()
        if self.state not in ["INCOMING", "EARLY"]:
            raise SIPCoreError('Can only transition to the "EARLY" state from the "INCOMING" or "EARLY" states, ' +
                               'currently in the "%s" state' % self.state)
        try:
            self._send_response(ua, 200, extra_headers)
        except PJSIPError, e:
            if not _pj_status_to_def(e.status).startswith("PJMEDIA_SDPNEG"):
                raise

    cdef int _send_response(self, PJSIPUA ua, int response_code, dict extra_headers) except -1:
        cdef pjsip_tx_data *tdata
        cdef int status
        cdef pjmedia_sdp_session *local_sdp = NULL
        if response_code / 100 == 2:
            if self._local_sdp_proposed is None:
                raise SIPCoreError("Local SDP has not been set")
            self._local_sdp_proposed._to_c()
            local_sdp = &self._local_sdp_proposed._obj
        status = pjsip_inv_answer(self._obj, response_code, NULL, local_sdp, &tdata)
        if status != 0:
                raise PJSIPError("Could not create %d reply to INVITE" % response_code, status)
        self._send_msg(ua, tdata, extra_headers or {})
        return 0

    def end(self, int response_code=603, dict extra_headers=None, timeout=None):
        cdef pj_time_val timeout_pj
        cdef pjsip_tx_data *tdata
        cdef int status
        cdef PJSIPUA ua = self._check_ua()
        if self.state == "DISCONNECTED":
            return
        if self.state == "DISCONNECTING":
            raise SIPCoreError("INVITE session is already DISCONNECTING")
        if self._obj == NULL:
            raise SIPCoreError("INVITE session is not active")
        if response_code / 100 < 3:
            raise SIPCoreError("Not a non-2xx final response: %d" % response_code)
        if response_code == 487:
            raise SIPCoreError("487 response can only be used following a CANCEL request")
        if timeout is not None:
            if timeout <= 0:
                raise ValueError("Timeout value cannot be negative")
            timeout_pj.sec = int(timeout)
            timeout_pj.msec = (timeout * 1000) % 1000
        if self.state == "INCOMING":
            status = pjsip_inv_answer(self._obj, response_code, NULL, NULL, &tdata)
        else:
            status = pjsip_inv_end_session(self._obj, response_code, NULL, &tdata)
        if status != 0:
            raise PJSIPError("Could not create message to end INVITE session", status)
        self._cb_state(ua, "DISCONNECTING", NULL)
        if tdata != NULL:
            self._send_msg(ua, tdata, extra_headers or {})
        if self._timer_active:
            pjsip_endpt_cancel_timer(ua._pjsip_endpoint._obj, &self._timer)
            self._timer_active = 0
        if timeout:
            status = pjsip_endpt_schedule_timer(ua._pjsip_endpoint._obj, &self._timer, &timeout_pj)
            if status == 0:
                self._timer_active = 1

    def respond_to_reinvite(self, int response_code=200, dict extra_headers=None):
        cdef PJSIPUA ua = self._check_ua()
        if self.state != "REINVITED":
            raise SIPCoreError('Can only send a response to a re-INVITE in the "REINVITED" state, ' +
                               'currently in the "%s" state' % self.state)
        self._send_response(ua, response_code, extra_headers)

    def send_reinvite(self, dict extra_headers=None):
        cdef pjsip_tx_data *tdata
        cdef int status
        cdef pjmedia_sdp_session *local_sdp = NULL
        cdef PJSIPUA ua = self._check_ua()
        if self.state != "CONFIRMED":
            raise SIPCoreError('Can only send re-INVITE in "CONFIRMED" state, not "%s" state' % self.state)
        if self._local_sdp_proposed is not None:
            self._local_sdp_proposed._to_c()
            local_sdp = &self._local_sdp_proposed._obj
        status = pjsip_inv_reinvite(self._obj, NULL, local_sdp, &tdata)
        if status != 0:
            raise PJSIPError("Could not create re-INVITE message", status)
        self._send_msg(ua, tdata, extra_headers or {})
        self._cb_state(ua, "REINVITING", NULL)


# callback functions

cdef void _Invitation_cb_state(pjsip_inv_session *inv, pjsip_event *e) with gil:
    cdef Invitation invitation
    cdef object state
    cdef pjsip_rx_data *rdata = NULL
    cdef pjsip_tx_data *tdata = NULL
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        if inv.state == PJSIP_INV_STATE_INCOMING:
            return
        if inv.mod_data[ua._module.id] != NULL:
            invitation = <object> inv.mod_data[ua._module.id]
            state = pjsip_inv_state_name(inv.state)
            if state == "DISCONNCTD":
                state = "DISCONNECTED"
            if e != NULL:
                if e.type == PJSIP_EVENT_TSX_STATE and e.body.tsx_state.type == PJSIP_EVENT_TX_MSG:
                    tdata = e.body.tsx_state.src.tdata
                    if (tdata.msg.type == PJSIP_RESPONSE_MSG and tdata.msg.line.status.code == 487 and
                        state == "DISCONNECTED" and invitation.state in ["INCOMING", "EARLY"]):
                        return
                elif e.type == PJSIP_EVENT_RX_MSG:
                    rdata = e.body.rx_msg.rdata
                elif e.type == PJSIP_EVENT_TSX_STATE and e.body.tsx_state.type == PJSIP_EVENT_RX_MSG:
                    if (inv.state != PJSIP_INV_STATE_CONFIRMED or
                        e.body.tsx_state.src.rdata.msg_info.msg.type == PJSIP_REQUEST_MSG):
                        rdata = e.body.tsx_state.src.rdata
            try:
                invitation._cb_state(ua, state, rdata)
            except:
                invitation._fail(ua)
    except:
        ua._handle_exception(1)

cdef void _Invitation_cb_sdp_done(pjsip_inv_session *inv, int status) with gil:
    cdef Invitation invitation
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        if inv.mod_data[ua._module.id] != NULL:
            invitation = <object> inv.mod_data[ua._module.id]
            try:
                invitation._cb_sdp_done(ua, status)
            except:
                invitation._fail(ua)
    except:
        ua._handle_exception(1)

cdef void _Invitation_cb_rx_reinvite(pjsip_inv_session *inv,
                                     pjmedia_sdp_session_ptr_const offer, pjsip_rx_data *rdata) with gil:
    cdef Invitation invitation
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        if inv.mod_data[ua._module.id] != NULL:
            invitation = <object> inv.mod_data[ua._module.id]
            try:
                invitation._cb_state(ua, "REINVITED", rdata)
            except:
                invitation._fail(ua)
    except:
        ua._handle_exception(1)

cdef void _Invitation_cb_tsx_state_changed(pjsip_inv_session *inv, pjsip_transaction *tsx, pjsip_event *e) with gil:
    cdef Invitation invitation
    cdef pjsip_rx_data *rdata = NULL
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        if tsx == NULL or e == NULL:
            return
        if e.type == PJSIP_EVENT_TSX_STATE and e.body.tsx_state.type == PJSIP_EVENT_RX_MSG:
            rdata = e.body.tsx_state.src.rdata
        if inv.mod_data[ua._module.id] != NULL:
            invitation = <object> inv.mod_data[ua._module.id]
            if ((tsx.state == PJSIP_TSX_STATE_TERMINATED or tsx.state == PJSIP_TSX_STATE_COMPLETED) and
                invitation._reinvite_tsx != NULL and invitation._reinvite_tsx == tsx):
                try:
                    invitation._cb_state(ua, "CONFIRMED", rdata)
                except:
                    invitation._fail(ua)
            elif (invitation.state in ["INCOMING", "EARLY"] and invitation._credentials is None and
                  rdata != NULL and rdata.msg_info.msg.type == PJSIP_REQUEST_MSG and
                  rdata.msg_info.msg.line.req.method.id == PJSIP_CANCEL_METHOD):
                try:
                    invitation._cb_state(ua, "DISCONNECTED", rdata)
                except:
                    invitation._fail(ua)
    except:
        ua._handle_exception(1)

cdef void _Invitation_cb_new(pjsip_inv_session *inv, pjsip_event *e) with gil:
    # As far as I can tell this is never actually called!
    pass

cdef int _Invitation_cb_fail_post(object obj) except -1:
    cdef Invitation invitation = obj
    invitation._do_dealloc()

cdef void _Request_cb_disconnect_timer(pj_timer_heap_t *timer_heap, pj_timer_entry *entry) with gil:
    cdef PJSIPUA ua
    cdef Invitation inv
    try:
        ua = _get_ua()
    except:
        return
    try:
        if entry.user_data != NULL:
            inv = <object> entry.user_data
            inv._timer_active = 0
            pjsip_inv_terminate(inv._obj, 408, 1)
    except:
        ua._handle_exception(1)

# globals

cdef pjsip_inv_callback _inv_cb
_inv_cb.on_state_changed = _Invitation_cb_state
_inv_cb.on_media_update = _Invitation_cb_sdp_done
_inv_cb.on_rx_reinvite = _Invitation_cb_rx_reinvite
_inv_cb.on_tsx_state_changed = _Invitation_cb_tsx_state_changed
_inv_cb.on_new_session = _Invitation_cb_new
