# Fixture del self-test: deja en una capa un token falso con forma de PAT clásico.
# Se arma al construir para que el texto del repo nunca contenga el patrón completo.
FROM busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4
RUN mkdir -p /app \
    && printf 'GITHUB_TOKEN=ghp_%s\n' "$(printf '%s' a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8)" > /app/config.env
