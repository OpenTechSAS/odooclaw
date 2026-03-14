FROM odoo:18.0

USER root

# Crear carpeta para addons custom
RUN mkdir -p /mnt/extra-addons
RUN chown -R odoo:odoo /mnt/extra-addons

# Copiar addons del repo dentro de la imagen
COPY --chown=odoo:odoo ./addons/ /mnt/extra-addons/

USER odoo