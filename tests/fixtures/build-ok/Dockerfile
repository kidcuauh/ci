# Fixture del self-test: debe construirse y pasar el escaneo.
FROM busybox:1.38.0@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4
ARG EJEMPLO=por-defecto
# El secreto se monta solo durante este RUN: no queda en ninguna capa.
RUN --mount=type=secret,id=prueba,required=true \
    test "$(cat /run/secrets/prueba)" = "valor-de-prueba-no-secreto"
RUN echo "ejemplo=$EJEMPLO" > /etc/ejemplo
