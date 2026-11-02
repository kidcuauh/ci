# App web mínima para la prueba e2e: busybox httpd en el puerto 8080 con /healthz.
# Funciona con cualquier uid no root y con el sistema de archivos de solo lectura.
FROM busybox:1.37.0-musl@sha256:f6a95d611e0a8780fabdb2aec43e31275b2720dfefa3e41b16835bfc42454478
RUN mkdir /www && echo ok > /www/healthz && chmod -R a+rX /www
EXPOSE 8080
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
