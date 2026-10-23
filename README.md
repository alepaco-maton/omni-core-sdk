# omni-core-sdk

Plugin Flutter (`omni_mdm`) que consume Omni MDM.

**Producción:** `OmniMdmConfig.productionEndpoint` = `https://mdm.stamina.ia.bo` (Let's Encrypt).  
La app anfitriona (`boa_app`, `uno_app`) pasa ese endpoint en `OmniMdm.initialize`. No hay IP pública.

Dentro de Docker el API se alcanza como `omni-api:8080`, nunca por este dominio.
