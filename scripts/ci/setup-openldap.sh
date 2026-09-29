#!/usr/bin/env bash
# CI only: an LDAPS directory that behaves like Google Secure LDAP for the parts AskDrive
# uses (spec 6.13) — TLS on 636 that *demands* a client certificate signed by its CA, users
# under ou=Users with mail / displayName, password bind as the user's DN.
# Prints the LDAP_IT_* variables for the integration test to $GITHUB_ENV.
set -euo pipefail

DIR="${1:-/tmp/ldap-it}"
mkdir -p "${DIR}"
cd "${DIR}"

sudo DEBIAN_FRONTEND=noninteractive debconf-set-selections <<EOF
slapd slapd/domain string example.com
slapd shared/organization string Example
slapd slapd/password1 password admin-pass
slapd slapd/password2 password admin-pass
slapd slapd/no_configuration boolean false
EOF
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y slapd ldap-utils >/dev/null

# CA, server certificate for localhost, and the client certificate AskDrive presents
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=LdapTestCA 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj /CN=localhost 2>/dev/null
printf "subjectAltName=DNS:localhost\n" > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 -extfile server.ext 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj /CN=AskDriveLdapClient 2>/dev/null
# a v3 client certificate for TLS client authentication, like Google's LDAP client certificates
printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n" > client.ext
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out client.pem -days 2 -extfile client.ext 2>/dev/null

sudo mkdir -p /etc/ldap/tls
sudo cp ca.pem server.pem server.key /etc/ldap/tls/
sudo chown -R openldap:openldap /etc/ldap/tls
sudo chmod 0600 /etc/ldap/tls/server.key

sudo ldapmodify -Y EXTERNAL -H ldapi:/// -Q <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/tls/ca.pem
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/tls/server.pem
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/tls/server.key
-
replace: olcTLSVerifyClient
olcTLSVerifyClient: demand
EOF

sudo sed -i 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"|' /etc/default/slapd
sudo systemctl restart slapd
sleep 2

ldapadd -x -H ldapi:/// -D cn=admin,dc=example,dc=com -w admin-pass <<EOF
dn: ou=Users,dc=example,dc=com
objectClass: organizationalUnit
ou: Users

dn: uid=taro,ou=Users,dc=example,dc=com
objectClass: inetOrgPerson
uid: taro
cn: Taro Yamada
sn: Yamada
displayName: Taro Yamada
mail: taro@example.com
userPassword: correct-horse
EOF

# sanity: LDAPS without a client certificate must be refused, with it accepted
if LDAPTLS_CACERT="${DIR}/ca.pem" ldapsearch -x -H ldaps://localhost:636 -b dc=example,dc=com -s base >/dev/null 2>&1; then
  echo "expected LDAPS without a client certificate to be refused" >&2
  exit 1
fi
if ! LDAPTLS_CACERT="${DIR}/ca.pem" LDAPTLS_CERT="${DIR}/client.pem" LDAPTLS_KEY="${DIR}/client.key" \
  ldapsearch -x -H ldaps://localhost:636 -b dc=example,dc=com "(mail=taro@example.com)" dn | grep -q "uid=taro"; then
  echo "--- diagnostics ---" >&2
  sudo ss -ltnp | grep -E ':(389|636)' >&2 || true
  sudo slapcat -b cn=config 2>/dev/null | grep -i '^olcTLS' >&2 || true
  echo | openssl s_client -connect localhost:636 -CAfile "${DIR}/ca.pem" -cert "${DIR}/client.pem" -key "${DIR}/client.key" 2>&1 | head -20 >&2 || true
  LDAPTLS_CACERT="${DIR}/ca.pem" LDAPTLS_CERT="${DIR}/client.pem" LDAPTLS_KEY="${DIR}/client.key" \
    ldapsearch -d 1 -x -H ldaps://localhost:636 -b dc=example,dc=com -s base 2>&1 | grep -iE "tls|error|cert" | head -20 >&2 || true
  sudo journalctl -u slapd --no-pager -n 30 >&2 || true
  sudo dmesg 2>/dev/null | grep -i apparmor | tail -5 >&2 || true
  exit 1
fi
echo "OpenLDAP (LDAPS, client certificate demanded) is ready"

{
  echo "LDAP_IT_HOST=localhost"
  echo "LDAP_IT_PORT=636"
  echo "LDAP_IT_CA=${DIR}/ca.pem"
  echo "LDAP_IT_CLIENT_CERT=${DIR}/client.pem"
  echo "LDAP_IT_CLIENT_KEY=${DIR}/client.key"
} >> "${GITHUB_ENV:-/dev/null}"
