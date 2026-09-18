# Generate a Fernet key (32 url-safe base64 bytes)
mkdir -p /patch/config/pulp/certs
python3 -c "import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())" \
  > /patch/config/pulp/certs/database_fields.symmetric.key

chmod 0640 /patch/config/pulp/certs/database_fields.symmetric.key
chown -R root:0 /patch/config/pulp/certs
cat /patch/config/pulp/certs/database_fields.symmetric.key
