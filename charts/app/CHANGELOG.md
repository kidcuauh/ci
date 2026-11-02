# Changelog del chart app

Formato: una sección por versión, con una subsección **Migración** cuando hay que tocar los values.

## Política de migración

- El chart sigue SemVer. Es cambio **mayor** quitar o renombrar un value, endurecer el schema de forma que un values válido deje de serlo, o cambiar la forma del release (nombres de los objetos, `spec.selector`).
- El `spec.selector` de los Deployments no cambia nunca, ni en una versión mayor: un selector es inmutable en Kubernetes y cambiarlo obliga a recrear el Deployment.
- Un cambio mayor trae su guía de migración aquí: qué value cambia, cómo se ve antes y después, y en qué orden aplicarlo.
- Sin backports: una corrección sale en la última versión de la línea vigente.
- Cada versión se consume por digest. Subir el pin es un cambio manual en cada repo que usa el chart.

## 1.0.0-rc.1

Primera versión candidata.

- Deployment web con Service (nombre del release, puerto `http` con nombre), Ingress opcional con una ruta por host y puertos extra.
- Workers (Deployment por worker) y CronJobs (`concurrencyPolicy: Forbid`).
- Job de migraciones como hook de Helm (`post-install`, `pre-upgrade`) con `backoffLimit: 0` y sin rollback.
- PodDisruptionBudget solo con 2 o más réplicas.
- Pod Security restricted: `runAsNonRoot`, filesystem de solo lectura con `writablePaths` como emptyDir, drop ALL, seccomp `RuntimeDefault`, sin automount del token.
- Secretos solo por referencia: `InfisicalStaticSecret` v1beta1 (`secrets.infisical`), variables con `secretKeyRef` a una lista de Secrets permitidos y archivos montados desde ConfigMaps o Secrets existentes. El chart no tiene plantilla de Secret.
- Montaje de un PVC existente (el chart no crea PVC).
- `values.schema.json` estricto: `additionalProperties: false` en todos los objetos.

**Migración:** no aplica (primera versión).
