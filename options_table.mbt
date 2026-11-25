///|
/// The options of curl, one per line: the long name, the letter or `.`, and
/// `=` if the option takes a value. From `curl --help all` of curl 8.19.0,
/// with `--no-NAME` listed as `NAME`, and `include`, the old name of
/// `show-headers`.
let option_data : String =
  #|abstract-unix-socket . =
  #|alpn .
  #|alt-svc . =
  #|anyauth .
  #|append a
  #|aws-sigv4 . =
  #|basic .
  #|buffer N
  #|ca-native .
  #|cacert . =
  #|capath . =
  #|cert E =
  #|cert-status .
  #|cert-type . =
  #|ciphers . =
  #|clobber .
  #|compressed .
  #|compressed-ssh .
  #|config K =
  #|connect-timeout . =
  #|connect-to . =
  #|continue-at C =
  #|cookie b =
  #|cookie-jar c =
  #|create-dirs .
  #|create-file-mode . =
  #|crlf .
  #|crlfile . =
  #|curves . =
  #|data d =
  #|data-ascii . =
  #|data-binary . =
  #|data-raw . =
  #|data-urlencode . =
  #|delegation . =
  #|digest .
  #|disable q
  #|disable-eprt .
  #|disable-epsv .
  #|disallow-username-in-url .
  #|dns-interface . =
  #|dns-ipv4-addr . =
  #|dns-ipv6-addr . =
  #|dns-servers . =
  #|doh-cert-status .
  #|doh-insecure .
  #|doh-url . =
  #|dump-ca-embed .
  #|dump-header D =
  #|ech . =
  #|egd-file . =
  #|engine . =
  #|etag-compare . =
  #|etag-save . =
  #|expect100-timeout . =
  #|fail f
  #|fail-early .
  #|fail-with-body .
  #|false-start .
  #|follow .
  #|form F =
  #|form-escape .
  #|form-string . =
  #|ftp-account . =
  #|ftp-alternative-to-user . =
  #|ftp-create-dirs .
  #|ftp-method . =
  #|ftp-pasv .
  #|ftp-port P =
  #|ftp-pret .
  #|ftp-skip-pasv-ip .
  #|ftp-ssl-ccc .
  #|ftp-ssl-ccc-mode . =
  #|ftp-ssl-control .
  #|get G
  #|globoff g
  #|happy-eyeballs-timeout-ms . =
  #|haproxy-clientip . =
  #|haproxy-protocol .
  #|head I
  #|header H =
  #|help h =
  #|hostpubmd5 . =
  #|hostpubsha256 . =
  #|hsts . =
  #|http0.9 .
  #|http1.0 0
  #|http1.1 .
  #|http2 .
  #|http2-prior-knowledge .
  #|http3 .
  #|http3-only .
  #|ignore-content-length .
  #|include .
  #|insecure k
  #|interface . =
  #|ip-tos . =
  #|ipfs-gateway . =
  #|ipv4 4
  #|ipv6 6
  #|json . =
  #|junk-session-cookies j
  #|keepalive .
  #|keepalive-cnt . =
  #|keepalive-time . =
  #|key . =
  #|key-type . =
  #|knownhosts . =
  #|krb . =
  #|libcurl . =
  #|limit-rate . =
  #|list-only l
  #|local-port . =
  #|location L
  #|location-trusted .
  #|login-options . =
  #|mail-auth . =
  #|mail-from . =
  #|mail-rcpt . =
  #|mail-rcpt-allowfails .
  #|manual M
  #|max-filesize . =
  #|max-redirs . =
  #|max-time m =
  #|metalink .
  #|mptcp .
  #|negotiate .
  #|netrc n
  #|netrc-file . =
  #|netrc-optional .
  #|next :
  #|noproxy . =
  #|npn .
  #|ntlm .
  #|ntlm-wb .
  #|oauth2-bearer . =
  #|out-null .
  #|output o =
  #|output-dir . =
  #|parallel Z
  #|parallel-immediate .
  #|parallel-max . =
  #|parallel-max-host . =
  #|pass . =
  #|path-as-is .
  #|pinnedpubkey . =
  #|post301 .
  #|post302 .
  #|post303 .
  #|preproxy . =
  #|progress-bar #
  #|progress-meter .
  #|proto . =
  #|proto-default . =
  #|proto-redir . =
  #|proxy x =
  #|proxy-anyauth .
  #|proxy-basic .
  #|proxy-ca-native .
  #|proxy-cacert . =
  #|proxy-capath . =
  #|proxy-cert . =
  #|proxy-cert-type . =
  #|proxy-ciphers . =
  #|proxy-crlfile . =
  #|proxy-digest .
  #|proxy-header . =
  #|proxy-http2 .
  #|proxy-http3 .
  #|proxy-insecure .
  #|proxy-key . =
  #|proxy-key-type . =
  #|proxy-negotiate .
  #|proxy-ntlm .
  #|proxy-pass . =
  #|proxy-pinnedpubkey . =
  #|proxy-service-name . =
  #|proxy-ssl-allow-beast .
  #|proxy-ssl-auto-client-cert .
  #|proxy-tls13-ciphers . =
  #|proxy-tlsauthtype . =
  #|proxy-tlspassword . =
  #|proxy-tlsuser . =
  #|proxy-tlsv1 .
  #|proxy-user U =
  #|proxy1.0 . =
  #|proxytunnel p
  #|pubkey . =
  #|quote Q =
  #|random-file . =
  #|range r =
  #|rate . =
  #|raw .
  #|referer e =
  #|remote-header-name J
  #|remote-name O
  #|remote-name-all .
  #|remote-time R
  #|remove-on-error .
  #|request X =
  #|request-target . =
  #|resolve . =
  #|retry . =
  #|retry-all-errors .
  #|retry-connrefused .
  #|retry-delay . =
  #|retry-max-time . =
  #|sasl-authzid . =
  #|sasl-ir .
  #|service-name . =
  #|sessionid .
  #|show-error S
  #|show-headers i
  #|sigalgs . =
  #|silent s
  #|skip-existing .
  #|socks4 . =
  #|socks4a . =
  #|socks5 . =
  #|socks5-basic .
  #|socks5-gssapi .
  #|socks5-gssapi-nec .
  #|socks5-gssapi-service . =
  #|socks5-hostname . =
  #|speed-limit Y =
  #|speed-time y =
  #|ssl .
  #|ssl-allow-beast .
  #|ssl-auto-client-cert .
  #|ssl-no-revoke .
  #|ssl-reqd .
  #|ssl-revoke-best-effort .
  #|ssl-sessions . =
  #|sslv2 2
  #|sslv3 3
  #|stderr . =
  #|styled-output .
  #|suppress-connect-headers .
  #|tcp-fastopen .
  #|tcp-nodelay .
  #|telnet-option t =
  #|tftp-blksize . =
  #|tftp-no-options .
  #|time-cond z =
  #|tls-earlydata .
  #|tls-max . =
  #|tls13-ciphers . =
  #|tlsauthtype . =
  #|tlspassword . =
  #|tlsuser . =
  #|tlsv1 1
  #|tlsv1.0 .
  #|tlsv1.1 .
  #|tlsv1.2 .
  #|tlsv1.3 .
  #|tr-encoding .
  #|trace . =
  #|trace-ascii . =
  #|trace-config . =
  #|trace-ids .
  #|trace-time .
  #|unix-socket . =
  #|upload-file T =
  #|upload-flags . =
  #|url . =
  #|url-query . =
  #|use-ascii B
  #|user u =
  #|user-agent A =
  #|variable . =
  #|verbose v
  #|version V
  #|vlan-priority . =
  #|write-out w =
  #|xattr .
