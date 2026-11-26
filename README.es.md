# Allka Archivo

Prendas de moda físicas que se venden como NFT en Conflux eSpace, con un mercado de reventa incluido. Hecho por FGM Labs para [allka](https://allka.com.ar).

> **Estado:** desarrollo inicial. La Fase 1 (contratos) está en curso. Solo testnet. Sin auditar. No usar con fondos reales.

[Read in English](README.md)

## Qué es

Cada prenda única de allka es un NFT. El NFT es el derecho a reclamar la pieza física, que ya está hecha y guardada.

1. **Venta primaria.** Se compra el NFT de una prenda con USDT0.
2. **Mercado de reventa.** El dueño de un NFT sin reclamar lo publica a su precio y otro usuario lo compra en el mismo sitio.
3. **Reclamo.** Se quema el NFT, se cargan los datos de envío y se recibe la prenda.

## Cómo está hecho

| Pieza | Función |
|---|---|
| `Prenda` | El contrato del NFT. Un NFT por cada prenda física. Guarda las reglas de guarda de cada drop y hace el reclamo. |
| `Venta` | Los drops: precio en USDT0, fecha de apertura y entrada anticipada para holders de $FGM. |
| `Mercado` | La reventa entre usuarios, con una comisión fija del 2%. |
| Sitio web | Next.js y TypeScript, en inglés y español, primero celular (fase posterior). |

Las reglas que hacen cumplir los contratos:

- Todo se paga en USDT0. Ningún contrato retiene fondos: el pago va directo del comprador a quien cobra.
- Un NFT solo cambia de dueño a través del Mercado, y siempre con permiso de su dueño.
- La comisión de reventa es fija, del 2%, y no se puede subir.
- La guarda es gratis durante un período; después corre una cuota mensual hasta un máximo, que se paga al reclamar. El derecho a la prenda no vence.
- Los holders de $FGM entran antes a los drops, según una foto de saldos tomada antes de cada drop.
- Toda prenda está terminada, etiquetada con el número de su NFT y guardada antes de que su drop salga a la venta.

El diseño completo está en [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md).

## Hoja de ruta

- [x] Fase 0. Arquitectura y revisión de seguridad independiente del diseño.
- [ ] Fase 1. Contratos con sus tests y despliegue en testnet.
- [ ] Fase 2. Sitio: drops y compra con USDT0.
- [ ] Fase 3. Reventa.
- [ ] Fase 4. Reclamo y panel de administración.
- [ ] Fase 5. Revisión de seguridad interna y lista de control.
- [ ] Fase 6. Auditoría externa. Recién después, mainnet.

Después de la versión 1: pago con tarjeta a través de un proveedor de checkout para NFT, y acceso con mail.

## Cómo correrlo

Hace falta Node.js 22.13 o posterior.

```bash
npm install
npx hardhat test
```

## Tecnologías

Solidity 0.8.38, OpenZeppelin Contracts 5.6, Hardhat 3 y Conflux eSpace (testnet con chain ID 71, mainnet con chain ID 1030).

## Seguridad

Los contratos no están auditados. En [SECURITY.md](SECURITY.md) está el estado actual y cómo avisar de un problema.

## Cómo se desarrolla

El código lo escribe Claude (Anthropic) como equipo técnico, fase por fase, con la revisión del dueño del producto. Las reglas de trabajo están en [CLAUDE.md](CLAUDE.md) y la bitácora del proyecto en [ESTADO.md](ESTADO.md).

## Enlaces

- FGM Labs en X: [@FGMLabs](https://x.com/FGMLabs)
- allka: [allka.com.ar](https://allka.com.ar)

## Licencia

[MIT](LICENSE)
