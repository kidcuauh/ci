# Fixture del self-test: debe construirse y pasar el escaneo.
FROM busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
ARG EJEMPLO=por-defecto
# El secreto se monta solo durante este RUN: no queda en ninguna capa.
RUN --mount=type=secret,id=prueba,required=true \
    test "$(cat /run/secrets/prueba)" = "valor-de-prueba-no-secreto"
RUN echo "ejemplo=$EJEMPLO" > /etc/ejemplo
