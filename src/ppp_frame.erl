-module(ppp_frame).

-export([decode/1, encode/1, decode_cp_options/1, encode_cp_options/1]).

-compile(bin_opt_info).
-compile(inline).
-compile({inline,[decode_lcp/3, decode_cp_option/2]}).

-define(PPP_IP,          16#21).	%% Internet Protocol
-define(PPP_AT,          16#29).	%% AppleTalk Protocol
-define(PPP_IPX,         16#2b).	%% IPX protocol
-define(PPP_VJC_COMP,    16#2d).	%% VJ compressed TCP
-define(PPP_VJC_UNCOMP,  16#2f).	%% VJ uncompressed TCP
-define(PPP_IPV6,        16#57).	%% Internet Protocol Version 6
-define(PPP_COMP,        16#fd).	%% compressed packet
-define(PPP_IPCP,        16#8021).	%% IP Control Protocol
-define(PPP_ATCP,        16#8029).	%% AppleTalk Control Protocol
-define(PPP_IPXCP,       16#802b).	%% IPX Control Protocol
-define(PPP_IPV6CP,      16#8057).	%% IPv6 Control Protocol
-define(PPP_CCP,         16#80fd).	%% Compression Control Protocol
-define(PPP_ECP,         16#8053).	%% Encryption Control Protocol
-define(PPP_LCP,         16#c021).	%% Link Control Protocol
-define(PPP_PAP,         16#c023).	%% Password Authentication Protocol
-define(PPP_LQR,         16#c025).	%% Link Quality Report protocol
-define(PPP_CHAP,        16#c223).	%% Cryptographic Handshake Auth. Protocol
-define(PPP_CBCP,        16#c029).	%% Callback Control Protocol
-define(PPP_EAP,         16#c227).	%% Extensible Authentication Protocol

-define('CP-VendorSpecific',    0).
-define('CP-Configure-Request', 1).							%% [RFC1661]
-define('CP-Configure-Ack',     2).							%% [RFC1661]
-define('CP-Configure-Nak',     3).							%% [RFC1661]
-define('CP-Configure-Reject',  4).							%% [RFC1661]
-define('CP-Terminate-Request', 5).							%% [RFC1661]
-define('CP-Terminate-Ack',     6).							%% [RFC1661]
-define('CP-Code-Reject',       7).							%% [RFC1661]
-define('CP-Protocol-Reject',   8).							%% [RFC1661]
-define('CP-Echo-Request',      9).							%% [RFC1661]
-define('CP-Echo-Reply',       10).							%% [RFC1661]
-define('CP-Discard-Request',  11).							%% [RFC1661]
-define('CP-Identification',   12).							%% [RFC1570]
-define('CP-Time-Remaining',   13).							%% [RFC1570]
-define('CP-Reset-Request',    14).							%% [RFC1962]
-define('CP-Reset-Reply',      15).							%% [RFC1962]

cp_code(?'CP-VendorSpecific')		-> 'CP-VendorSpecific';
cp_code(?'CP-Configure-Request')	-> 'CP-Configure-Request';
cp_code(?'CP-Configure-Ack')		-> 'CP-Configure-Ack';
cp_code(?'CP-Configure-Nak')		-> 'CP-Configure-Nak';
cp_code(?'CP-Configure-Reject')		-> 'CP-Configure-Reject';
cp_code(?'CP-Terminate-Request')	-> 'CP-Terminate-Request';
cp_code(?'CP-Terminate-Ack')		-> 'CP-Terminate-Ack';
cp_code(?'CP-Code-Reject')		-> 'CP-Code-Reject';
cp_code(?'CP-Protocol-Reject')		-> 'CP-Protocol-Reject';
cp_code(?'CP-Echo-Request')		-> 'CP-Echo-Request';
cp_code(?'CP-Echo-Reply')		-> 'CP-Echo-Reply';
cp_code(?'CP-Discard-Request')		-> 'CP-Discard-Request';
cp_code(?'CP-Identification')		-> 'CP-Identification';
cp_code(?'CP-Time-Remaining')		-> 'CP-Time-Remaining';
cp_code(?'CP-Reset-Request')		-> 'CP-Reset-Request';
cp_code(?'CP-Reset-Reply')		-> 'CP-Reset-Reply';

cp_code('CP-VendorSpecific')		-> ?'CP-VendorSpecific';
cp_code('CP-Configure-Request')		-> ?'CP-Configure-Request';
cp_code('CP-Configure-Ack')		-> ?'CP-Configure-Ack';
cp_code('CP-Configure-Nak')		-> ?'CP-Configure-Nak';
cp_code('CP-Configure-Reject')		-> ?'CP-Configure-Reject';
cp_code('CP-Terminate-Request')		-> ?'CP-Terminate-Request';
cp_code('CP-Terminate-Ack')		-> ?'CP-Terminate-Ack';
cp_code('CP-Code-Reject')		-> ?'CP-Code-Reject';
cp_code('CP-Protocol-Reject')		-> ?'CP-Protocol-Reject';
cp_code('CP-Echo-Request')		-> ?'CP-Echo-Request';
cp_code('CP-Echo-Reply')		-> ?'CP-Echo-Reply';
cp_code('CP-Discard-Request')		-> ?'CP-Discard-Request';
cp_code('CP-Identification')		-> ?'CP-Identification';
cp_code('CP-Time-Remaining')		-> ?'CP-Time-Remaining';
cp_code('CP-Reset-Request')		-> ?'CP-Reset-Request';
cp_code('CP-Reset-Reply')		-> ?'CP-Reset-Reply'.

cp_auth_protocol(?PPP_PAP)	-> pap;
cp_auth_protocol(?PPP_CHAP)	-> chap;
cp_auth_protocol(?PPP_EAP)	-> eap;
cp_auth_protocol(pap)		-> ?PPP_PAP;
cp_auth_protocol(chap)		-> ?PPP_CHAP; 
cp_auth_protocol(eap)		-> ?PPP_EAP.

chap_md_type(md5)		-> 5;
chap_md_type(sha1)		-> 6;
chap_md_type('MS-CHAP')		-> 128;
chap_md_type('MS-CHAP-v2')	-> 129;
chap_md_type(5)			-> md5;
chap_md_type(6)			-> sha1;
chap_md_type(128)		-> 'MS-CHAP';
chap_md_type(129)		-> 'MS-CHAP-v2'.

-define(CI_VENDOR,        0).	%% Vendor Specific
-define(CI_MRU,           1).	%% Maximum Receive Unit					[RFC1661]
-define(CI_ASYNCMAP,      2).	%% Async Control Character Map
-define(CI_AUTHTYPE,      3).	%% Authentication Type					[RFC1661]
-define(CI_QUALITY,       4).	%% Quality Protocol					[RFC1661]
-define(CI_MAGICNUMBER,   5).	%% Magic Number						[RFC1661]
-define(CI_PCOMPRESSION,  7).	%% Protocol Field Compression				[RFC1661]
-define(CI_ACCOMPRESSION, 8).	%% Address/Control Field Compression			[RFC1661]
-define(CI_CALLBACK,     13).	%% callback						[RFC1570]
-define(CI_MRRU,         17).	%% max reconstructed receive unit; multilink		[RFC1990]
-define(CI_SSNHF,        18).	%% short sequence numbers for multilink			[RFC1990]
-define(CI_EPDISC,       19).	%% endpoint discriminator				[RFC1990]
-define(CI_LDISC,        23).	%% Link-Discriminator					[RFC2125]

-define('PAP-Authentication-Request', 1).
-define('PAP-Authenticate-Ack',       2).
-define('PAP-Authenticate-Nak',       3).

pap_code(?'PAP-Authentication-Request') -> 'PAP-Authentication-Request';
pap_code(?'PAP-Authenticate-Ack')       -> 'PAP-Authenticate-Ack';
pap_code(?'PAP-Authenticate-Nak')       -> 'PAP-Authenticate-Nak';
pap_code('PAP-Authentication-Request')  -> ?'PAP-Authentication-Request';
pap_code('PAP-Authenticate-Ack')        -> ?'PAP-Authenticate-Ack';
pap_code('PAP-Authenticate-Nak')        -> ?'PAP-Authenticate-Nak'.

-define('CHAP-Challenge', 1).
-define('CHAP-Response',  2).
-define('CHAP-Success',   3).
-define('CHAP-Failure',   4).

chap_code(?'CHAP-Challenge') -> 'CHAP-Challenge';
chap_code(?'CHAP-Response')  -> 'CHAP-Response';
chap_code(?'CHAP-Success')   -> 'CHAP-Success';
chap_code(?'CHAP-Failure')   -> 'CHAP-Failure';
chap_code('CHAP-Challenge')  -> ?'CHAP-Challenge';
chap_code('CHAP-Response')   -> ?'CHAP-Response';
chap_code('CHAP-Success')    -> ?'CHAP-Success';
chap_code('CHAP-Failure')    -> ?'CHAP-Failure'.

decode(<<?PPP_IP:8/integer, Info/binary>>) ->
    {ipv4, Info};

decode(<<?PPP_IPCP:16/integer, Info/binary>>) ->
    {ipcp, Info};

decode(<<?PPP_LCP:16/integer, Code:8/integer, Id:8/integer, Length:16/integer, Rest/binary>>) ->
    DataLen = Length - 4,
    <<Data:DataLen/bytes, _Pad/binary>> = Rest,
    decode_lcp(Data, Id, Code);

decode(<<?PPP_PAP:16/integer, Code:8/integer, Id:8/integer, Length:16/integer, Rest/binary>>) ->
    DataLen = Length - 4,
    <<Data:DataLen/bytes, _Pad/binary>> = Rest,
    decode_pap(Data, Id, Code);

decode(<<?PPP_CHAP:16/integer, Code:8/integer, Id:8/integer, Length:16/integer, Rest/binary>>) ->
    DataLen = Length - 4,
    <<Data:DataLen/bytes, _Pad/binary>> = Rest,
    decode_chap(Data, Id, Code).

encode(Type, Code, Id, Data) ->
    Length = 4 + size(Data),
    <<Type/binary, Code:8, Id:8, Length:16, Data/binary>>.

encode({lcp, Code, Id, Options})
  when Code == 'CP-Configure-Request';
       Code == 'CP-Configure-Ack';
       Code == 'CP-Configure-Nak';
       Code == 'CP-Configure-Reject' ->
    Data = encode_cp_options(Options),
    encode(<<?PPP_LCP:16>>, cp_code(Code), Id, Data);
encode({lcp, Code, Id, Data})
  when Code == 'CP-Terminate-Request';
       Code == 'CP-Terminate-Ack' ->
    encode(<<?PPP_LCP:16>>, cp_code(Code), Id, Data);
encode({lcp, 'CP-Code-Reject', Id, RejectedPacket}) when is_binary(RejectedPacket)->
    encode(<<?PPP_LCP:16>>, ?'CP-Code-Reject', Id, RejectedPacket);
encode({lcp, 'CP-Code-Reject', Id, RejectedPacket}) ->
    BinRejectedPacket = encode(RejectedPacket),
    encode(<<?PPP_LCP:16>>, ?'CP-Code-Reject', Id, BinRejectedPacket);
encode({lcp, 'CP-Discard-Request', Id}) ->
    encode(<<?PPP_LCP:16>>, ?'CP-Discard-Request', Id, <<>>);
encode({lcp, 'CP-Echo-Request', Id}) ->
    encode(<<?PPP_LCP:16>>, ?'CP-Echo-Request', Id, <<>>);
encode({lcp, 'CP-Echo-Reply', Id}) ->
    encode(<<?PPP_LCP:16>>, ?'CP-Echo-Reply', Id, <<>>);
encode({lcp, 'CP-Protocol-Reject', Id, RejectedProtocol, RejectedInfo}) ->
    encode(<<?PPP_LCP:16>>, ?'CP-Protocol-Reject', Id, <<RejectedProtocol:16, RejectedInfo/binary>>);
encode({lcp, 'CP-Identification', Id, Magic, Message}) ->
    encode(<<?PPP_LCP:16>>, ?'CP-Identification', Id, <<Magic:32, Message/binary>>);
encode({lcp, 'CP-Time-Remaining', Id, Magic, Remaining, Message}) ->
    encode(<<?PPP_LCP:16>>, ?'CP-Time-Remaining', Id, <<Magic:32, Remaining:32, Message/binary>>);

encode({pap, 'PAP-Authentication-Request', Id, PeerId, Passwd}) ->
    PeerLength = size(PeerId),
    PassLength = size(Passwd),
    encode(<<?PPP_PAP:16>>, ?'PAP-Authentication-Request', Id,
	   <<PeerLength:8, PeerId/binary, PassLength:8, Passwd/binary>>);
encode({pap, Code, Id, Msg})
  when Code == 'PAP-Authenticate-Ack';
       Code == 'PAP-Authenticate-Nak'->
    MsgLength = size(Msg),
    encode(<<?PPP_PAP:16>>, pap_code(Code), Id,
	   <<MsgLength:8, Msg/binary>>);

encode({chap, Code, Id, Value, Name})
  when Code == 'CHAP-Challenge';
       Code == 'CHAP-Response' ->
    ValueSize = size(Value),
    encode(<<?PPP_CHAP:16>>, chap_code(Code), Id,
	   <<ValueSize:8, Value/binary, Name/binary>>);
encode({chap, Code, Id, Msg})
  when Code == 'CHAP-Success';
       Code == 'CHAP-Failure' ->
    encode(<<?PPP_CHAP:16>>, chap_code(Code), Id, Msg).

decode_lcp(Data, Id, Code)
  when Code == ?'CP-Configure-Request';
       Code == ?'CP-Configure-Ack';
       Code == ?'CP-Configure-Nak';
       Code == ?'CP-Configure-Reject' ->
    {lcp, cp_code(Code), Id, decode_cp_options(Data)};
decode_lcp(Data, Id, Code)
  when Code == ?'CP-Terminate-Request';
       Code == ?'CP-Terminate-Ack' ->
    {lcp, cp_code(Code), Id, Data};
decode_lcp(RejectedPacket, Id, ?'CP-Code-Reject') ->
    {lcp, 'CP-Code-Reject', Id, RejectedPacket};
decode_lcp(_Data, Id, ?'CP-Discard-Request') ->
    {lcp, 'CP-Discard-Request', Id};
decode_lcp(_Data, Id, ?'CP-Echo-Request') ->
    {lcp, 'CP-Echo-Request', Id};
decode_lcp(_Data, Id, ?'CP-Echo-Reply') ->
    {lcp, 'CP-Echo-Reply', Id};
decode_lcp(<<RejectedProtocol:16/integer, RejectedInfo/binary>>, Id, ?'CP-Protocol-Reject') ->
    {lcp, 'CP-Protocol-Reject', Id, RejectedProtocol, RejectedInfo};
decode_lcp(<<Magic:32/integer, Message/binary>>, Id, ?'CP-Identification') ->
    {lcp, 'CP-Identification', Id, Magic, Message};
decode_lcp(<<Magic:32/integer, Remaining:32/integer, Message/binary>>, Id, ?'CP-Time-Remaining') ->
    {lcp, 'CP-Time-Remaining', Id, Magic, Remaining, Message}.

decode_pap(<<PeerLength:8/integer, Rest/binary>>, Id, ?'PAP-Authentication-Request') ->
    <<PeerId:PeerLength/bytes, PassLength:8/integer, More/binary>> = Rest,
    <<Passwd:PassLength/bytes, _/binary>> = More,
    {pap, 'PAP-Authentication-Request', Id, PeerId, Passwd};
decode_pap(<<MsgLength:8/integer, Rest/binary>>, Id, Code)
  when Code == ?'PAP-Authenticate-Ack';
       Code == ?'PAP-Authenticate-Nak'->
    <<Msg:MsgLength/bytes, _/binary>> = Rest,
    {pap, pap_code(Code), Id, Msg}.

decode_chap(Msg, Id, Code)
  when Code == 'CHAP-Success';
       Code == 'CHAP-Failure' ->
     {chap, chap_code(Code), Id, Msg};
decode_chap(<<ValueSize:8/integer, Rest/binary>>, Id, Code)
  when Code == 'CHAP-Challenge';
       Code == 'CHAP-Response' ->
    <<Value:ValueSize/bytes, Name/binary>> = Rest,
    {chap, chap_code(Code), Id, Value, Name}.

decode_cp_option(<<MRU:16/integer>>, ?CI_MRU) ->
    {mru, MRU};
decode_cp_option(<<ACCM:32/integer>>, ?CI_ASYNCMAP) ->
    {asyncmap, ACCM};
decode_cp_option(<<Auth:16/integer>>, ?CI_AUTHTYPE)
  when Auth == ?PPP_EAP; Auth == ?PPP_PAP ->
    {auth, cp_auth_protocol(Auth), none};
decode_cp_option(<<Auth:16/integer, MDType:8/integer>>, ?CI_AUTHTYPE)
  when Auth == ?PPP_CHAP ->
    {auth, cp_auth_protocol(Auth), chap_md_type(MDType)};
decode_cp_option(<<QP:16/integer, Period:32/integer>>, ?CI_QUALITY) ->
    {quality, QP, Period};
decode_cp_option(<<Magic:32/integer>>, ?CI_MAGICNUMBER) ->
    {magic, Magic};
decode_cp_option(<<>>, ?CI_PCOMPRESSION) ->
    pfc;
decode_cp_option(<<>>, ?CI_ACCOMPRESSION) ->
    acfc;
decode_cp_option(<<Op:8/integer, Message/binary>>, ?CI_CALLBACK) ->
    {callback, Op, Message};
decode_cp_option(<<MRRU:16/integer>>, ?CI_MRRU) ->
    {mrru, MRRU};
decode_cp_option(<<>>, ?CI_SSNHF) ->
    ssnhf;
decode_cp_option(<<Class:8/integer, Address/binary>>, ?CI_EPDISC) ->
    {epdisc, Class, Address};
decode_cp_option(<<LDisc:16/integer>>, ?CI_LDISC) ->
    {ldisc, LDisc};

decode_cp_option(Data, Type) ->
    {Type, Data}.

decode_cp_options(Options) ->
    decode_cp_options(Options, []).

decode_cp_options(<<>>, Acc) ->
    lists:reverse(Acc);

%% variable length options decoding
decode_cp_options(Data = <<Type:8/integer, Length:8/integer, Rest/binary>>, Acc) ->
    PayLoadLen = Length - 2,
    case Rest of
	<<PayLoad:PayLoadLen/binary, Next/binary>> ->
	    Opt = decode_cp_option(PayLoad, Type),
	    decode_cp_options(Next, [Opt|Acc]);
	_ ->
	    %% invalid Length value
	    {raw, Data}
    end.

%% encode options
encode_cp_option(Type, Data) ->
    Length = size(Data) + 2,
    <<Type:8, Length:8, Data/binary>>.

%% allow empty list elements to simplify contructing the option list
encode_cp_option([]) ->
    <<>>;
encode_cp_option({mru, MRU}) ->
    encode_cp_option(?CI_MRU, <<MRU:16/integer>>);
encode_cp_option({asyncmap, ACCM}) ->
    encode_cp_option(?CI_ASYNCMAP, <<ACCM:32/integer>>);
encode_cp_option({auth, Auth, _})
when Auth == eap; Auth == pap ->
    encode_cp_option(?CI_AUTHTYPE, <<(cp_auth_protocol(Auth)):16/integer>>);
encode_cp_option({auth, Auth, MDType})
  when Auth == chap ->
    encode_cp_option(?CI_AUTHTYPE, <<(cp_auth_protocol(Auth)):16/integer, (chap_md_type(MDType)):8/integer>>);
encode_cp_option({quality, QP, Period}) ->
    encode_cp_option(?CI_QUALITY, <<QP:16/integer, Period:32/integer>>);
encode_cp_option({magic, Magic}) ->
    encode_cp_option(?CI_MAGICNUMBER, <<Magic:32/integer>>);
encode_cp_option(pfc) ->
    encode_cp_option(?CI_PCOMPRESSION, <<>>);
encode_cp_option(acfc) ->
    encode_cp_option(?CI_ACCOMPRESSION, <<>>);
encode_cp_option({callback, Op, Message}) ->
    encode_cp_option(?CI_CALLBACK, <<Op:8/integer, Message/binary>>);
encode_cp_option({mrru, MRRU}) ->
    encode_cp_option(?CI_MRRU, <<MRRU:16/integer>>);
encode_cp_option(ssnhf) ->
    encode_cp_option(?CI_SSNHF, <<>>);
encode_cp_option({epdisc, Class, Address}) ->
    encode_cp_option(?CI_EPDISC, <<Class:8/integer, Address/binary>>);
encode_cp_option({ldisc, LDisc}) ->
    encode_cp_option(?CI_LDISC, <<LDisc:16/integer>>);

encode_cp_option({Type, Data}) ->
    encode_cp_option(Type, Data).

encode_cp_options(Options) ->
    << <<(encode_cp_option(O))/binary>> || O <- Options >>.
