# Issues the broker's TLS certificate for $DOMAIN from a private CA, once: an
# existing certificate is left as it is. deploy.sh runs this in the rabbitmq
# image (it has openssl and the rabbitmq user) before the broker starts, since
# the TLS listener needs the files.
set -eu
cd /etc/rabbitmq/tls
[ -f server.crt ] && exit 0

# The CA signs this one certificate, so its key is not kept: a new certificate
# means a new CA, and ca.crt copied to the agent again.
ca_key=$(mktemp)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=AeroFlow broker CA" -keyout "$ca_key" -out ca.crt

openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj "/CN=$DOMAIN" -keyout server.key -out server.csr
chown rabbitmq:rabbitmq server.key
chmod 600 server.key

printf 'subjectAltName = DNS:%s\nextendedKeyUsage = serverAuth\n' "$DOMAIN" > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey "$ca_key" -days 3650 \
    -extfile server.ext -out server.crt
rm -f "$ca_key" server.csr server.ext
echo "Issued the broker's TLS certificate for $DOMAIN"
