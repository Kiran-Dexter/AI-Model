mkdir -p /llm/{bin,models,config,certs,logs,cache}
useradd --system --home-dir /llm --shell /sbin/nologin llm 2>/dev/null || true

mv /Tools/llama.cpp-b10867 /llm/bin/
ln -sfn /llm/bin/llama.cpp-b10867 /llm/bin/current
mv /Tools/*.gguf /llm/models/
( cd /llm/models && sha256sum *.gguf > SHA256SUMS )

chown -R root:llm /llm
chmod 0750 /llm /llm/bin /llm/models /llm/config /llm/certs
chown llm:llm /llm/logs /llm/cache
