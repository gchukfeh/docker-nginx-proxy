#!/usr/bin/env bash

set -e

export LOG_UUID=FALSE

. /defaults.sh


cat > ${NGIX_CONF_DIR}/server_certs.conf <<-EOF_CERT_CONF
    ssl_certificate     ${SERVER_CERT};
    ssl_certificate_key ${SERVER_KEY};
    # Can add SSLv3 for IE 6 but this opens up to poodle
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    # reduction to only the best ciphers
    # And make sure we prefer them
    ssl_ciphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_stapling on;
    # Version of Java 6 do not support this but this uses weaker encryption
    ssl_dhparam ${NGIX_CONF_DIR}/dhparam.pem;
EOF_CERT_CONF


if [ "${LOCATIONS_CSV}" == "" ]; then
    LOCATIONS_CSV=/
fi

IFS=',' read -a LOCATIONS_ARRAY <<< "$LOCATIONS_CSV"
for i in "${!LOCATIONS_ARRAY[@]}"; do
    /enable_location.sh $((${i} + 1)) ${LOCATIONS_ARRAY[$i]}
done

if [ "${NAME_RESOLVER}" == "" ]; then
    if [ "${DNSMASK}" == "TRUE" ]; then
        dnsmasq
        export NAME_RESOLVER=127.0.0.1
    else
        export NAME_RESOLVER=$(grep 'nameserver' /etc/resolv.conf | head -n1 | cut -d' ' -f2)
    fi
fi

msg "Resolving proxied names using resolver:${NAME_RESOLVER}"
echo "resolver ${NAME_RESOLVER};">${NGIX_CONF_DIR}/resolver.conf

if [ "${LOAD_BALANCER_CIDR}" != "" ]; then
    msg "Using proxy_protocol from '$LOAD_BALANCER_CIDR' (real client ip is forwarded correctly by loadbalancer)..."
    cp ${NGIX_CONF_DIR}/nginx_listen_proxy_protocol.conf ${NGIX_CONF_DIR}/nginx_listen.conf
    echo -e "\nset_real_ip_from ${LOAD_BALANCER_CIDR};" >> ${NGIX_CONF_DIR}/nginx_listen.conf
else
    msg "No \$LOAD_BALANCER_CIDR set, using straight SSL (client ip will be from loadbalancer if used)..."
    cp ${NGIX_CONF_DIR}/nginx_listen_plain.conf ${NGIX_CONF_DIR}/nginx_listen.conf
fi

if [ -f ${UUID_FILE} ]; then
    export LOG_UUID=TRUE
fi
if [ "${CLIENT_MAX_BODY_SIZE}" != "" ]; then
    UPLOAD_SETTING="client_max_body_size ${CLIENT_MAX_BODY_SIZE}m;"
    echo "${UPLOAD_SETTING}">${NGIX_CONF_DIR}/upload_size.conf
    msg "Setting '${UPLOAD_SETTING};'"
fi

if [ -f /etc/keys/client-ca ]; then
    msg "Loading client certs."
	cat > ${NGIX_CONF_DIR}/client_certs.conf <<-EOF_CLIENT_CONF
		ssl_client_certificate /etc/keys/client-ca;
		ssl_verify_client optional;
	EOF_CLIENT_CONF
else
    msg "No client certs mounted - not loading..."
fi

case "${LOG_FORMAT_NAME}" in
    "json" | "text")
        msg "Logging set to ${LOG_FORMAT_NAME}"
        echo "access_log /dev/stdout extended_${LOG_FORMAT_NAME};">${NGIX_CONF_DIR}/logging.conf
        ;;
    *)
        exit_error_msg "Invalid log format specified:${LOG_FORMAT_NAME}. Expecting json or text."
    ;;
esac

eval "/usr/local/openresty/nginx/sbin/nginx -g \"daemon off;\""
