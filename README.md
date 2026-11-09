# omni-core-sdk

Plugin Flutter (`omni_mdm`) que consume Omni MDM.

**Producción:** `OmniMdmConfig.productionEndpoint` = `https://mdm.stamina.ia.bo:19080` (certificado en el puerto de firewall; no hace falta publicar el paquete para usar ese dominio).  
La app anfitriona pasa ese endpoint en `OmniMdm.initialize`.

Dentro de Docker el API se alcanza como `omni-api:8080`, nunca por este dominio.
