-record(ipv6cp_opts, {
    neg_ifaceid = false		:: boolean(),			%% Negotiate interface identifier?
    req_ifaceid = false		:: boolean(),			%% Ask peer to send interface identifier
    accept_local = false	:: boolean(),			%% accept peer's value for iface id?

    use_ip = false		:: integer(),			%% use IP as interface identifier
    neg_vj = false		:: boolean(),			%% Van Jacobson Compression?
    vj_protocol = ipv6_hc	:: atom(),			%% protocol value to use in VJ option

    ourid = <<0:64>>		:: binary(),			%% Interface identifiers
    hisid = <<0:64>>		:: binary()
}).
