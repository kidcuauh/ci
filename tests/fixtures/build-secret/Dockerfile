# Fixture del self-test: deja en una capa un token falso con forma de PAT clásico.
# Se arma al construir para que el texto del repo nunca contenga el patrón completo.
FROM busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
RUN mkdir -p /app \
    && printf 'GITHUB_TOKEN=ghp_%s\n' "$(printf '%s' a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8)" > /app/config.env
