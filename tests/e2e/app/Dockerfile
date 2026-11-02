# App web mínima para la prueba e2e: busybox httpd en el puerto 8080 con /healthz.
# Funciona con cualquier uid no root y con el sistema de archivos de solo lectura.
FROM busybox:1.38.0-musl@sha256:80e38f9a1b39188b8bdb28879178edb322a4402b081a9aedda1924609decd6f6
RUN mkdir /www && echo ok > /www/healthz && chmod -R a+rX /www
EXPOSE 8080
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
