# ESTADO — Allka Archivo

Última actualización: 26/11/2026

Bitácora del proyecto: decisiones, avance y pendientes. Se lee al empezar cada sesión de trabajo, junto con [CLAUDE.md](CLAUDE.md) y [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md).

## Dónde estamos

- Fase 0 terminada. La arquitectura se aprobó el 26/11/2026, ya corregida tras una revisión de seguridad independiente.
- Fase 1 en curso (contratos).
  - Hecho: proyecto Hardhat 3, pruebas automáticas en cada cambio (CI), el token de prueba `TestUSDT0` y el contrato `Prenda` con sus tests.
  - Falta: contratos `Venta` y `Mercado` con sus tests, revisión independiente de los tres juntos y despliegue en la testnet de Conflux eSpace.

## Decisiones tomadas

1. Se empieza de cero en este repositorio.
2. Versión 1: se cobra solo en la stablecoin USDT0. El pago con tarjeta y el acceso con mail pasan a la Etapa 2.
3. Reventa: solo en USDT0.
4. Cada NFT es una prenda física concreta, con talle fijo. Toda prenda está terminada, etiquetada y guardada antes de que su drop salga a la venta.
5. Guarda: unos meses gratis y después una cuota en USDT0 que paga quien reclama. El derecho a la prenda no vence.
6. Transferencias: el NFT solo se mueve a través del Mercado del sitio. Interruptor de una sola vía para liberarlas más adelante.
7. Comisión de reventa: 2%, fija en este Mercado. No se puede subir.
8. Entrada anticipada a los drops para holders de $FGM (`0x630427E7241cB373F508D3b0c653d57280e5De81`): por foto de saldos tomada antes del drop, una prenda por billetera durante la ventana anticipada. El token no reparte ganancias.
9. Red Conflux eSpace. Todo en testnet hasta nuevo aviso. Sin escrow. Datos de envío y de factura solo al reclamar.
10. Sitio en inglés y español, primero celular, con Next.js sobre Vercel.
11. Repositorio público en la organización FGM Labs, con licencia MIT.

## Números por definir

Se cargan por drop. En testnet se usan valores de prueba.

- Meses de guarda gratis, valor de la cuota y máximo acumulado.
- Cuántas horas dura la ventana anticipada y cuánto $FGM hace falta para entrar en la foto.
- Precio mínimo que acepta el contrato.
- Direcciones de operador, tesorería y administración.

Para la Fase 4:

- Quién paga el envío y los impuestos de aduana, y cómo.
- A qué países se envía.
- Qué pasa si un paquete se pierde después de quemar el NFT.
- Dominio donde va a vivir el sitio.

## Diseño acordado para los contratos

- `Prenda` es el contrato permanente: guarda las reglas de guarda por drop, la lista de quién puede crear NFT (`Venta`) y la lista de Mercados autorizados, y hace el reclamo.
- El Mercado no es operador universal. Hace falta la aprobación normal del dueño (ERC-721); `Prenda` solo limita quién puede ejecutar transferencias. Un Mercado nuevo arranca sin poder sobre ningún NFT. Un Mercado apagado queda bloqueado para siempre, también si después se liberan las transferencias.
- Tres direcciones: operador (crea drops, no fija destinatarios de plata), tesorería (recibe; se puede cambiar) y administración (interruptores). Cambio de dueño en dos pasos.
- Drops: precio mínimo y guarda máxima en el contrato; apertura al menos 24 horas después de crear; cancelable antes de abrir; un número de NFT se vende una sola vez y un número quemado no se vuelve a crear.
- Entrada anticipada: la foto de saldos se publica como una raíz de Merkle por drop; cada billetera de la lista compra una prenda en la ventana anticipada.
- Compra con precio esperado; reclamo con guarda máxima aceptada; aprobaciones por el monto exacto; los contratos cobran solo de quien llama y nunca tienen saldo.
- Publicaciones: al comprar se verifica que el vendedor siga siendo el dueño; una publicación deja de valer si el NFT cambió de manos; precio mínimo; comisión constante del 2%.
- Guarda: período gratis desde la venta original; una cuota por cada 30 días cumplidos después; máximo obligatorio por drop; la administración solo puede bajarla. Si la guarda es cero, el reclamo no llama al token.
- Reclamo: el pedido se crea solo desde el evento de quema en la cadena; los datos de envío se aceptan solo firmados por la billetera que quemó y se pueden corregir hasta el despacho; el sitio valida el país antes de la quema; se despacha con el bloque finalizado.
- La pausa frena compras y reventa. Los reclamos no se pausan.
- No se usa EIP-3009 en la versión 1. Para la Etapa 2 se usaría la variante que solo puede ejecutar quien recibe (`receiveWithAuthorization`).
- No hay publicaciones reservadas para un comprador.
- Datos del NFT sellados con una huella al crear el drop.
- Datos personales: mínimos, cifrados, panel con doble factor, borrado después de la entrega, nada en la cadena.

Límites conocidos, sin agregar maquinaria: el candado de transferencias no impide vender la billetera entera ni usar una billetera-contrato como envoltorio; quien tenga la billetera comprometida no puede mover el NFT a otra; con un derecho que no vence, la prenda de quien perdió su billetera queda guardada para siempre.

## Cómo quedó `Prenda`

Decisiones tomadas al escribirlo. Las que dicen "a confirmar" son propuestas del equipo técnico que el dueño todavía no aprobó.

- Reclama solo el dueño del NFT. Ni un Mercado con permiso, ni la administración, ni el módulo de venta pueden reclamar por él.
- La guarda de cada NFT (tiempo gratis, cuota y tope) se fija al venderlo y queda guardada en `Prenda`. El tiempo gratis corre desde ese momento.
- Perdonar guarda es darle más tiempo gratis a una prenda: la fecha solo puede avanzar. También sirve de salida si USDT0 dejara de funcionar, porque con la guarda en cero el reclamo no toca el token.
- La moneda de la guarda queda fija al desplegar. La tesorería vive en `Prenda` y los módulos `Venta` y `Mercado` la leen de ahí: un solo cambio alcanza a todo.
- Cada NFT cuenta cuántas veces cambió de manos. El Mercado lo va a usar para descartar publicaciones hechas por un dueño anterior.
- El NFT se crea sin pasarle el control al comprador en medio de la compra (`_mint` y no `_safeMint`).
- Un NFT no se puede crear ni enviar a la dirección del propio contrato: ahí quedaría perdido.
- Cada módulo de venta y cada Mercado tiene que declarar que fue hecho para este contrato. Es una traba contra registrar por error otra dirección, y hace que la administración no pueda registrar (y después bloquear) billeteras o contratos ajenos.
- El aviso que deja cada NFT al crearse dice qué módulo lo creó.
- A confirmar: permisos más estrictos que en un NFT común. Solo los da el dueño, solo a quien puede mover NFT (con las transferencias cerradas, solo a un Mercado autorizado), y un Mercado apagado pierde los que tenía.
- A confirmar: la dirección web de los datos de los NFT se puede cambiar; lo que no se puede cambiar es la huella de los datos de cada NFT.
- A confirmar: la administración no se puede abandonar, para que el contrato nunca quede sin nadie que pueda pausar o cambiar la tesorería.

Cómo se probó:

- Tests de cada función, incluidos los caminos que deben fallar, con valores al azar para la guarda y el reclamo.
- Dueños que son contratos en vez de billeteras comunes, un token de pago que bloquea cuentas (como puede hacer el emisor de USDT0) y otro que intenta colarse en medio de un reclamo.
- Secuencias al azar de miles de operaciones (ventas, reventas, reclamos, pausas, perdones, cambios de tesorería) que comparan el contrato contra una contabilidad aparte después de cada paso.
- Además se rompe el contrato a propósito, una regla por vez, para comprobar que algún test lo nota.

### Revisión independiente de `Prenda` (26/11/2026)

La hizo un revisor aparte, que no vio cómo se escribió el contrato. No encontró fallas críticas ni altas. Encontró una media y varias menores. No reemplaza a la auditoría externa.

Corregido:

- Media: un Mercado con permiso podía pasarle ese permiso a otra dirección, y un Mercado apagado seguía pudiendo hacerlo. Si ese Mercado fallaba o era malicioso, alcanzaba para mover NFT ajenos. Ahora los permisos los da solo el dueño y un Mercado apagado pierde los que tenía.
- Un NFT enviado al propio contrato quedaba perdido. Ahora ese envío se rechaza.
- El aviso de creación de cada NFT no decía qué módulo lo creó. Ahora lo dice.
- Pedir solo que un módulo "sea un contrato" era una traba débil, y dejaba a la administración registrar y bloquear cualquier contrato. Ahora cada módulo declara para qué contrato fue hecho.
- Tests: el revisor mostró 14 cambios al contrato que los tests originales no notaban. Se sumaron tests para todos, más los de la lista de arriba.

Decisiones que quedan abiertas. Ninguna frena la versión 1 en testnet, pero hay que tomarlas antes de mainnet porque `Prenda` después no se puede cambiar:

1. Perdón general de guarda. Si el emisor de USDT0 bloqueara la dirección de `Prenda`, o si USDT0 dejara de funcionar, los reclamos con guarda quedan frenados y hoy la salida es perdonar prenda por prenda. Propuesta: un perdón para todas a la vez.
2. Cambio de tesorería en dos pasos: que la billetera nueva tenga que confirmar. Evita mandar la plata a una dirección mal escrita. Pide que la tesorería sea una billetera propia y no la dirección de depósito de un exchange.
3. Una llave que solo pueda pausar, para no depender de la llave guardada en una emergencia.
4. Que el reclamo lleve el número del pedido. Ata la quema a los datos de envío sin depender de una firma, que algunas billeteras-contrato no pueden dar.
5. Un tope de guarda fijo dentro de `Prenda`, además del que tenga `Venta`.
6. Qué cubre exactamente la huella de cada NFT. Se define junto con el catálogo, en la Fase 2.
7. Extras opcionales: aviso de cambio de datos (ERC-4906), datos de la colección y cantidad total de NFT.
8. Un rescate para tokens enviados por error al contrato.

Límites conocidos que se suman:

- Que un módulo declare para qué contrato fue hecho no prueba que sea seguro. Cada módulo necesita su propia revisión.
- El contador de cambios de manos también cuenta un movimiento que deja el NFT en el mismo dueño.
- Un perdón de guarda con la fecha mal escrita no se puede deshacer. El error siempre queda a favor del dueño de la prenda.
- Si compra un contrato que después no puede operar, su NFT queda trabado. Es responsabilidad de ese comprador.
- La llave de administración también es la llave del stock sin vender: quien la tenga puede sumar un módulo de venta falso, crear NFT y reclamarlos.

Para tener en cuenta en `Mercado`: tiene que ser inmutable y entregar el NFT con la transferencia simple. Las publicaciones necesitan cancelación y vencimiento, porque una publicación vieja puede revivir si el dueño le quita el permiso al Mercado y más adelante se lo vuelve a dar.

Para tener en cuenta en la Etapa 2 (tarjeta): no hay forma de quitar un NFT después de un contracargo, y pagar la guarda con tarjeta implica que FGM la perdone en la cadena.

Pendientes que salieron al escribirlo:

- Fase 4: antes de despachar, el servidor tiene que comprobar que el NFT quemado nació de una venta oficial (el aviso de creación dice qué módulo lo creó), además de que la quema esté finalizada.
- Antes de mainnet: la dirección de administración debería ser una billetera de varias firmas, y hay que vigilar los avisos de cambios de administración (tesorería, módulos de venta y Mercados nuevos).

## Tecnologías

- Contratos: Solidity 0.8.38 con OpenZeppelin Contracts 5.6.1. Compilador, objetivo de EVM (`cancun`) y optimizador fijos en `hardhat.config.ts`.
- Herramienta: Hardhat 3. Tests en Solidity (unitarios y con valores al azar) y, cuando haga falta, en TypeScript con viem. Despliegue con Ignition. Claves en el almacén cifrado de Hardhat (`hardhat-keystore`), fuera del repositorio.
- Sitio (Fase 2): Next.js con TypeScript en Vercel; billeteras con wagmi y viem.
- Datos (Fase 2): Postgres y almacenamiento de archivos; proveedor a elegir verificando antes su documentación.

## Datos técnicos verificados

Volver a verificar antes de usarlos. Fecha de la verificación entre paréntesis.

- Conflux eSpace es compatible con EVM y funciona con Hardhat, Foundry, ethers y viem (19/11/2026). https://doc.confluxnetwork.org/docs/espace/Overview
- Testnet: chain ID 71, RPC `https://evmtestnet.confluxrpc.com`, explorador https://evmtestnet.confluxscan.org. Mainnet: chain ID 1030, RPC `https://evm.confluxrpc.com` (19/11/2026). https://doc.confluxnetwork.org/docs/espace/network-endpoints
- Finalidad: la etiqueta `finalized` corresponde a bloques finalizados por la cadena PoS y tarda unas 400 confirmaciones (19/11/2026). https://doc.confluxnetwork.org/docs/espace/build/transaction
- La actualización v3.0 de Conflux incluyó CIP-645, que alinea eSpace con el EVM (MCOPY, almacenamiento transitorio), y CIP-7702 (26/11/2026). https://github.com/Conflux-Chain/conflux-rust/releases/tag/v3.0.0
- USDT0 en eSpace mainnet: `0xAf37E8B6c9ED7F6318979F56Fc287d76C30847FF`, 6 decimales, acepta pagos autorizados por firma (EIP-3009). La página no da direcciones de testnet (19/11/2026). https://doc.confluxnetwork.org/docs/espace/tutorials/x402/
- USDT0, según la auditoría de OpenZeppelin del 29/01/2025: actualizable (no dice quién controla las actualizaciones); su dueño puede bloquear cuentas y quemar los fondos de una cuenta bloqueada; una cuenta bloqueada puede recibir, pero no puede enviar ni ejecutar transferencias por cuenta de otros; el rol del puente puede quemar cualquier saldo. La auditoría cubre la versión de Arbitrum y el contrato pensado para cadenas nuevas, y no menciona a Conflux: confirmar contra el contrato real (releída el 26/11/2026). https://www.openzeppelin.com/news/usdt0-audit
- Verificación del código en ConfluxScan desde Hardhat: API de testnet `https://evmapi-testnet.confluxscan.org/api/` y de mainnet `https://evmapi.confluxscan.org/api/` (26/11/2026). https://doc.confluxnetwork.org/docs/espace/tutorials/VerifyContracts
- Solidity: se eligió la 0.8.38 (publicada el 22/10/2026) con pragma exacto; un repaso de seguridad del 06/11/2026 la da como la única versión sin errores conocidos (26/11/2026). https://guardian.security/blog/which-solidity-version-to-use/
- OpenZeppelin Contracts: la versión auditada que instala npm es la 5.6.1 (26/11/2026). https://docs.openzeppelin.com/contracts/5.x
- Hardhat 3 es estable; versión instalada 3.23.0; pide Node.js 22.13 o posterior (26/11/2026). https://hardhat.org/docs/getting-started

## Antes de mainnet

- Auditoría externa de los contratos. Punto central: que ningún Mercado pueda mover un NFT sin permiso de su dueño.
- Probar todo contra el USDT0 real en una copia de la red, incluido qué pasa si el emisor bloquea a un comprador, a la tesorería o a los contratos.
- Tomar las decisiones abiertas de la revisión independiente de `Prenda`.
- Confirmar el objetivo de EVM con un despliegue de prueba en la testnet de eSpace.
- Revisión legal y contable del modelo, términos y condiciones y política de privacidad.

## Reglas técnicas de este proyecto

- Las claves privadas y frases semilla nunca van dentro del repositorio ni se le pasan al asistente.
- Compilador, objetivo de EVM y optimizador se fijan de forma explícita. Cambiarlos es un cambio de código y pide correr todos los tests.
- En testnet se usa `TestUSDT0`, que solo copia los 6 decimales de USDT0, no su comportamiento.
- Antes de usar una librería, un servicio o una dirección de contrato se verifica su documentación oficial vigente.

## Cómo levantar el proyecto

Hace falta Node.js 22.13 o posterior.

```bash
npm install
npx hardhat test
```

`npx hardhat build` compila los contratos y `npx tsc --noEmit` revisa los tipos.

Si la máquina no puede descargar el compilador de Solidity, se puede indicar uno local con la variable `ALLKA_SOLC_PATH` (binario nativo o `soljson.js` de la versión 0.8.38).

## Próximos pasos

1. Contratos `Venta` y `Mercado` con sus tests.
2. Revisión de seguridad independiente de los tres contratos.
3. Despliegue en la testnet de Conflux eSpace y verificación en ConfluxScan.
