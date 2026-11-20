# Cómo contribuir

[English](CONTRIBUTING.md) | **Español**

Gracias por ayudar a mejorar OpenClaw en NAS. Este proyecto empaqueta y
mantiene OpenClaw para despliegues con Docker accesibles solo desde la LAN, y
la compatibilidad con Synology es un requisito prioritario.

## Pasos rápidos

1. Busca en las issues existentes antes de empezar.
2. Para cambios que no sean triviales, abre una issue o comenta en una
   existente y espera a que tenga la etiqueta `status:approved`.
3. Haz un fork del repositorio y crea una rama para un único cambio.
4. Haz un cambio coherente, valídalo y abre un pull request contra `main`.
   `main` está protegida: todos los cambios entran por pull request y se
   fusionan con squash.

## Antes de abrir un pull request

- No subas tokens, certificados, archivos `.env`, copias de seguridad ni
  direcciones de tu NAS.
- Usa un mensaje de commit convencional, por ejemplo
  `fix: repair certificate path`.
- Actualiza el README (`README.md` y `README.es.md`) cuando cambie la
  instalación, las actualizaciones, la seguridad o la recuperación.
- Mantén los pull requests acotados. Cuando sea posible, separa los cambios
  solo de documentación de los que cambian el comportamiento.

### Validación de los scripts

Ejecuta estas comprobaciones desde la raíz del repositorio:

```bash
bash -n openclaw install.sh scripts/*.sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
  openclaw install.sh scripts/*.sh
docker compose config --quiet
```

Si tu cambio afecta a la instalación, la migración, Nginx, los permisos o la
imagen del contenedor, describe en el PR la validación que has hecho. Los
cambios para Synology deben probarse en una instalación limpia y, cuando
proceda, también en una actualización.

El comando `./openclaw` está guardado dos veces: en `openclaw` y dentro de
`install.sh`. Mantén las dos copias idénticas.

## Qué se espera de un pull request

- Rellena la plantilla del pull request.
- Enlaza la issue aprobada con `Closes #<número>` cuando corresponda.
- Elige exactamente una etiqueta `type:*` (`type:bug`, `type:chore` o
  `type:docs`).
- Explica qué cambia para el usuario y cómo se vuelve atrás o se recupera.
- Incluye la salida de las pruebas o unos pasos breves de validación manual.
- No añadas líneas de atribución a IA ni de coautoría salvo que una persona
  mantenedora lo pida expresamente.

## Avisos de seguridad

No informes de vulnerabilidades en issues públicas. Sigue las instrucciones de
[SECURITY.es.md](SECURITY.es.md).
